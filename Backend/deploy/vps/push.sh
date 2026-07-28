#!/bin/sh
set -eu
umask 077

progress() {
    progress_phase=$1
    progress_message=$2
    progress_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '[%s] %s: %s\n' \
        "$progress_timestamp" "$progress_phase" "$progress_message"
}

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

if [ "$#" -ne 1 ]; then
    die "Usage: push.sh SSH_USER@HOST"
fi
ssh_target=$1
case "$ssh_target" in
    "" | -* | *[!A-Za-z0-9_.@:-]* | *@*@* | @* | *@)
        die "The SSH target is unsafe."
        ;;
esac
case "$ssh_target" in
    *@*) ;;
    *) die "The SSH target must include an explicit user." ;;
esac

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repository=$(git -C "$script_directory" rev-parse --show-toplevel) ||
    die "push.sh must run from a Git checkout."
[ -d "$repository/.git" ] || [ -f "$repository/.git" ] ||
    die "Cannot identify the Git checkout."
cd "$repository"

dirty_state=$(git status --porcelain --untracked-files=all) ||
    die "Cannot inspect repository state."
if [ -n "$dirty_state" ]; then
    die "Repository is dirty; commit or remove every tracked and untracked change."
fi

revision=$(git rev-parse --verify HEAD^{commit}) ||
    die "Cannot resolve the current commit."
case "$revision" in
    "" | *[!0-9a-f]*) die "Git returned an unsafe commit identity." ;;
esac
[ "${#revision}" -eq 40 ] || die "Git commit identity is not full length."

archive=
manifest=
remote_directory=
remote_archive=
remote_prepared=false

cleanup() {
    status=$?
    if [ -n "$archive" ]; then
        rm -f -- "$archive"
    fi
    if [ -n "$manifest" ]; then
        rm -f -- "$manifest"
    fi
    if [ "$remote_prepared" = true ]; then
        ssh "$ssh_target" \
            "rm -f -- '$remote_archive'; rmdir -- '$remote_directory'" \
            >/dev/null 2>&1 || true
    fi
    if [ "$status" -ne 0 ]; then
        progress "failure" "release push failed" >&2
    fi
    trap - 0
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

manifest=$(mktemp /tmp/ladle-release-manifest.XXXXXX)
chmod 0600 "$manifest"
git ls-tree -r --name-only "$revision" >"$manifest"
if LC_ALL=C awk '
    /(^|\/)\.git($|\/)/ ||
    /(^|\/)\.private($|\/)/ ||
    ((/(^|\/)\.env($|\.)/) && !(/(^|\/)\.env\.example$/)) ||
    /(^|\/)(__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache)($|\/)/ ||
    /(^|\/)(\.DS_Store|\.coverage)$/ ||
    /\.pyc$/ ||
    /(^|\/)\.ladle-revision$/ {
        unsafe = 1
    }
    END {
        exit unsafe
    }
' "$manifest"; then
    :
else
    die "Tracked archive content includes a secret or cache control path."
fi

progress "archive" "creating exact revision $revision"
archive=$(mktemp /tmp/ladle-release.XXXXXX.tar)
chmod 0600 "$archive"
git archive --format=tar -o "$archive" "$revision"
[ -s "$archive" ] || die "Git produced an empty release archive."

if ! ssh "$ssh_target" 'sudo -n true'; then
    die "Noninteractive sudo is required before any remote release mutation."
fi
progress "upload" "transferring exact revision archive"
remote_directory=$(
    ssh "$ssh_target" \
        'umask 077; directory=$(mktemp -d /tmp/ladle-upload.XXXXXX) &&
        chmod 0700 "$directory" && printf "%s\n" "$directory"'
) || die "Cannot allocate a private remote upload directory."
case "$remote_directory" in
    /tmp/ladle-upload.*) ;;
    *) die "The remote upload directory is unsafe." ;;
esac
remote_token=${remote_directory#/tmp/ladle-upload.}
case "$remote_token" in
    "" | *[!A-Za-z0-9]*) die "The remote upload directory is unsafe." ;;
esac
remote_archive="$remote_directory/release.tar"
remote_prepared=true
scp "$archive" "$ssh_target:$remote_archive"

ssh "$ssh_target" sh -s -- \
    "$revision" "$remote_directory" "$remote_archive" <<'LADLE_REMOTE_RELEASE'
#!/bin/sh
set -eu
umask 077

revision=$1
remote_directory=$2
remote_archive=$3
case "$revision" in
    "" | *[!0-9a-f]*) exit 1 ;;
esac
[ "${#revision}" -eq 40 ] || exit 1
case "$remote_directory" in
    /tmp/ladle-upload.*) ;;
    *) exit 1 ;;
esac
remote_token=${remote_directory#/tmp/ladle-upload.}
case "$remote_token" in
    "" | *[!A-Za-z0-9]*) exit 1 ;;
esac
[ "$remote_archive" = "$remote_directory/release.tar" ] || exit 1

releases_directory=/opt/ladle/releases
release="/opt/ladle/releases/$revision"
incoming=
root_archive=
archive_listing=
archive_types=

remote_cleanup() {
    status=$?
    rm -f -- "$remote_archive"
    rmdir -- "$remote_directory" 2>/dev/null || true
    if [ -n "$root_archive" ]; then
        sudo -n rm -f -- "$root_archive"
    fi
    if [ -n "$archive_listing" ]; then
        rm -f -- "$archive_listing"
    fi
    if [ -n "$archive_types" ]; then
        rm -f -- "$archive_types"
    fi
    if [ -n "$incoming" ]; then
        sudo -n rm -rf -- "$incoming"
    fi
    trap - 0
    exit "$status"
}
trap remote_cleanup 0
trap 'exit 1' HUP INT TERM

[ -d "$remote_directory" ] && [ ! -L "$remote_directory" ] || exit 1
[ "$(readlink -f -- "$remote_directory")" = "$remote_directory" ] || exit 1
[ "$(stat -c "%u:%a" -- "$remote_directory")" = "$(id -u):700" ] || exit 1
[ -d "$releases_directory" ] && [ ! -L "$releases_directory" ] || exit 1
[ "$(readlink -f -- "$releases_directory")" = "$releases_directory" ] || exit 1
[ -f "$remote_archive" ] && [ ! -L "$remote_archive" ] || exit 1
chmod 0600 "$remote_archive"
sudo -n chown root:root "$releases_directory"
sudo -n chmod 0755 "$releases_directory"

release_root_is_safe() {
    root_release=$1
    [ -d "$root_release" ] && [ ! -L "$root_release" ] || return 1
    [ "$(readlink -f -- "$root_release")" = "$root_release" ] || return 1
    [ "$(stat -c "%u:%a" -- "$root_release")" = 0:755 ] || return 1
    release_library="$root_release/Backend/deploy/vps/deployment-lib.sh"
    [ -f "$release_library" ] && [ ! -L "$release_library" ] || return 1
    [ "$(stat -c "%u:%a" -- "$release_library")" = 0:755 ] || return 1
    . "$release_library"
    release_directory_is_safe "$root_release" 0 || return 1
    if sudo -n find "$root_release" -xdev \
        \( ! -user root -o -perm /022 \) -print -quit |
        grep -q .; then
        return 1
    fi
    for critical_path in \
        Backend/deploy/vps/initialize-env.sh \
        Backend/deploy/vps/deploy.sh \
        Backend/deploy/vps/deployment-lib.sh \
        Backend/docker-compose.yml \
        Backend/deploy/vps/docker-compose.yml; do
        [ -f "$root_release/$critical_path" ] &&
            [ ! -L "$root_release/$critical_path" ] || return 1
    done
    [ -x "$root_release/Backend/deploy/vps/initialize-env.sh" ] &&
        [ -x "$root_release/Backend/deploy/vps/deploy.sh" ] &&
        [ -x "$root_release/Backend/deploy/vps/deployment-lib.sh" ]
}

if [ -e "$release" ] || [ -L "$release" ]; then
    release_root_is_safe "$release" || exit 1
    marker=$release/.ladle-revision
    [ -f "$marker" ] && [ ! -L "$marker" ] || exit 1
    [ "$(wc -l <"$marker" | tr -d ' ')" = 1 ] || exit 1
    IFS= read -r marker_revision <"$marker" || exit 1
    [ "$marker_revision" = "$revision" ] || exit 1
else
    root_archive=$(
        sudo -n mktemp /opt/ladle/releases/.archive-"$revision".XXXXXX
    )
    case "$root_archive" in
        /opt/ladle/releases/.archive-"$revision".*) ;;
        *) exit 1 ;;
    esac
    sudo -n install -o root -g root -m 0600 "$remote_archive" "$root_archive"
    archive_listing=$(mktemp /tmp/ladle-archive-listing.XXXXXX)
    archive_types=$(mktemp /tmp/ladle-archive-types.XXXXXX)
    chmod 0600 "$archive_listing" "$archive_types"
    sudo -n tar -tf "$root_archive" >"$archive_listing"
    LC_ALL=C awk '
        /^\/|(^|\/)\.\.($|\/)|(^|\/)\.($|\/)/ {
            unsafe = 1
        }
        END {
            exit unsafe || NR == 0
        }
    ' "$archive_listing"
    sudo -n tar -tvf "$root_archive" >"$archive_types"
    LC_ALL=C awk '
        substr($0, 1, 1) != "-" && substr($0, 1, 1) != "d" {
            unsafe = 1
        }
        END {
            exit unsafe || NR == 0
        }
    ' "$archive_types"

    incoming=$(
        sudo -n mktemp -d /opt/ladle/releases/.incoming-"$revision".XXXXXX
    )
    case "$incoming" in
        /opt/ladle/releases/.incoming-"$revision".*) ;;
        *) exit 1 ;;
    esac
    [ -d "$incoming" ] && [ ! -L "$incoming" ] || exit 1
    sudo -n tar --extract --file "$root_archive" --directory "$incoming" \
        --no-same-owner --no-same-permissions
    sudo -n chmod -R u=rwX,go=rX "$incoming"
    printf '%s\n' "$revision" |
        sudo -n tee "$incoming/.ladle-revision" >/dev/null
    sudo -n chmod 0444 "$incoming/.ladle-revision"
    sudo -n chown -R root:root "$incoming"
    sudo -n chmod -R go-w "$incoming"
    sudo -n chmod 0755 "$incoming"
    release_root_is_safe "$incoming" || exit 1
    sudo -n mv -T -- "$incoming" "$release"
    incoming=
    sudo -n rm -f -- "$root_archive"
    root_archive=
fi

sudo -n /bin/sh -s -- \
    "$release/Backend/deploy/vps/deployment-lib.sh" <<'LADLE_REMOTE_PROGRESS'
#!/bin/sh
set -eu
umask 077
. "$1"
progress_init ladle-secrets
progress "archive" "exact revision archive verified"
progress "upload" "root-owned release installed"
LADLE_REMOTE_PROGRESS

sudo -n "$release/Backend/deploy/vps/initialize-env.sh"
sudo -n "$release/Backend/deploy/vps/deploy.sh" "$revision"
LADLE_REMOTE_RELEASE

remote_prepared=false
