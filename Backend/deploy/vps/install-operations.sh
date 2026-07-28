#!/bin/sh
set -eu
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "Run install-operations.sh as root." >&2
    exit 1
fi
if [ "$#" -ne 1 ]; then
    printf '%s\n' "Usage: install-operations.sh FULL_GIT_COMMIT" >&2
    exit 1
fi

revision=$1
if [ "${#revision}" -ne 40 ]; then
    printf '%s\n' "Revision must be a full lowercase Git commit." >&2
    exit 1
fi
case "$revision" in
    *[!0-9a-f]*)
        printf '%s\n' "Revision must be a full lowercase Git commit." >&2
        exit 1
        ;;
esac

release=/opt/ladle/releases/$revision
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
expected_script_directory=$release/Backend/deploy/vps
if [ "$script_directory" != "$expected_script_directory" ]; then
    printf '%s\n' "Run the installer from the requested exact release." >&2
    exit 1
fi
if [ ! -d "$release" ] || [ -L "$release" ] ||
    [ "$(readlink -f -- "$release")" != "$release" ] ||
    [ "$(stat -c '%u:%a' -- "$release")" != "0:755" ]; then
    printf '%s\n' "The exact release metadata is unsafe." >&2
    exit 1
fi
if find "$release" -xdev \( ! -user root -o -perm /022 \) -print -quit |
    grep -q .; then
    printf '%s\n' "The exact release contains mutable content." >&2
    exit 1
fi

revision_marker=$release/.ladle-revision
if [ ! -f "$revision_marker" ] || [ -L "$revision_marker" ] ||
    [ "$(stat -c '%u:%a' -- "$revision_marker")" != "0:444" ] ||
    [ "$(cat "$revision_marker")" != "$revision" ]; then
    printf '%s\n' "The exact release revision marker is invalid." >&2
    exit 1
fi

operations_source=$script_directory/operations.sh
for executable_source in \
    "$operations_source" \
    "$script_directory/install-operations.sh"; do
    if [ ! -f "$executable_source" ] || [ -L "$executable_source" ] ||
        [ "$(stat -c '%u:%a' -- "$executable_source")" != "0:755" ]; then
        printf '%s\n' "An operations executable is unsafe." >&2
        exit 1
    fi
done

unit_names="ladle-health.service ladle-health.timer ladle-backup.service ladle-backup.timer"
for unit_name in $unit_names; do
    unit_source=$script_directory/$unit_name
    if [ ! -f "$unit_source" ] || [ -L "$unit_source" ] ||
        [ "$(stat -c '%u:%a' -- "$unit_source")" != "0:644" ]; then
        printf '%s\n' "An operations unit is unsafe." >&2
        exit 1
    fi
done

ensure_root_directory() {
    directory_path=$1
    directory_mode=$2
    if [ -e "$directory_path" ] || [ -L "$directory_path" ]; then
        [ -d "$directory_path" ] && [ ! -L "$directory_path" ] ||
            return 1
        [ "$(readlink -f -- "$directory_path")" = "$directory_path" ] ||
            return 1
        [ "$(stat -c '%u:%a' -- "$directory_path")" = "0:$directory_mode" ] ||
            return 1
    else
        install -d -o root -g root -m "$directory_mode" "$directory_path"
    fi
}

ensure_root_directory /var/backups/ladle 700
ensure_root_directory /var/lib/ladle 750
ensure_root_directory /var/lib/ladle/operations 700

secret_group=ladle-secrets
secret_group_id=$(getent group "$secret_group" | awk -F: 'NR == 1 { print $3 }')
[ -n "$secret_group_id" ] || {
    printf '%s\n' "The Ladle secrets group is missing." >&2
    exit 1
}
if [ ! -d /var/log/ladle ] || [ -L /var/log/ladle ] ||
    [ "$(readlink -f -- /var/log/ladle)" != /var/log/ladle ] ||
    [ "$(stat -c '%u:%g:%a' -- /var/log/ladle)" != \
        "0:$secret_group_id:750" ]; then
    printf '%s\n' "The Ladle log directory is unsafe." >&2
    exit 1
fi
operations_log=/var/log/ladle/operations.log
if [ -e "$operations_log" ] || [ -L "$operations_log" ]; then
    [ -f "$operations_log" ] && [ ! -L "$operations_log" ] ||
        {
            printf '%s\n' "The operations log is unsafe." >&2
            exit 1
        }
    [ "$(stat -c '%u:%g:%a' -- "$operations_log")" = \
        "0:$secret_group_id:640" ] ||
        {
            printf '%s\n' "The operations log metadata is unsafe." >&2
            exit 1
        }
else
    install -o root -g "$secret_group" -m 0640 /dev/null "$operations_log"
fi

atomic_install() {
    install_source=$1
    install_target=$2
    install_mode=$3
    if [ -e "$install_target" ] || [ -L "$install_target" ]; then
        [ -f "$install_target" ] && [ ! -L "$install_target" ] ||
            return 1
        [ "$(stat -c '%u:%a' -- "$install_target")" = "0:$install_mode" ] ||
            return 1
    fi
    install_tmp=$(mktemp "$(dirname -- "$install_target")/.ladle-install.XXXXXX")
    if ! install -o root -g root -m "$install_mode" \
        "$install_source" "$install_tmp"; then
        rm -f -- "$install_tmp"
        return 1
    fi
    mv -f -- "$install_tmp" "$install_target"
}

ensure_root_directory /usr/local/sbin 755
ensure_root_directory /etc/systemd/system 755
atomic_install "$operations_source" /usr/local/sbin/ladle-operations 755
systemd-analyze verify \
    "$script_directory/ladle-health.service" \
    "$script_directory/ladle-health.timer" \
    "$script_directory/ladle-backup.service" \
    "$script_directory/ladle-backup.timer"
for unit_name in $unit_names; do
    atomic_install \
        "$script_directory/$unit_name" \
        "/etc/systemd/system/$unit_name" \
        644
done

systemctl daemon-reload
systemctl enable --now ladle-health.timer ladle-backup.timer
printf '%s\n' "Ladle health and backup timers installed."
