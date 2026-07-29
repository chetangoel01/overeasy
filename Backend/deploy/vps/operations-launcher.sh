#!/bin/sh
set -eu
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

current_release=/opt/ladle/current
releases_directory=/opt/ladle/releases
authority_lock=/var/lib/ladle/locks/authority.lock
trusted_uid=0

launcher_fail() {
    printf '%s\n' "Cannot run active Ladle operations." >&2
    exit 1
}

trusted_directory() {
    trusted_path=$1
    [ -d "$trusted_path" ] && [ ! -L "$trusted_path" ] || return 1
    [ "$(readlink -f -- "$trusted_path")" = "$trusted_path" ] || return 1
    trusted_metadata=$(stat -c '%u:%a' -- "$trusted_path") || return 1
    [ "${trusted_metadata%%:*}" = "$trusted_uid" ] || return 1
    trusted_mode=${trusted_metadata##*:}
    [ $((0$trusted_mode & 022)) -eq 0 ]
}

authority_identity_is_trusted() {
    trusted_identity=$1
    case "$trusted_identity" in
        "" | *[!0-9:]*) return 1 ;;
    esac
    trusted_identity_ifs=$IFS
    IFS=:
    set -- $trusted_identity
    IFS=$trusted_identity_ifs
    [ "$#" -eq 4 ] || return 1
    [ -n "$1" ] && [ -n "$2" ] || return 1
    [ "$3" = "$trusted_uid" ] && [ "$4" = 600 ]
}

trusted_authority_lock_identity() {
    [ -f "$authority_lock" ] && [ ! -L "$authority_lock" ] || return 1
    [ "$(readlink -f -- "$authority_lock")" = "$authority_lock" ] ||
        return 1
    trusted_lock_identity=$(
        stat -c '%d:%i:%u:%a' -- "$authority_lock"
    ) || return 1
    authority_identity_is_trusted "$trusted_lock_identity" || return 1
    printf '%s\n' "$trusted_lock_identity"
}

opened_authority_lock_identity() {
    stat -Lc '%d:%i:%u:%a' -- /proc/self/fd/7
}

acquire_operations_authority_lock() {
    expected_authority_lock_identity=$(
        trusted_authority_lock_identity
    ) || launcher_fail
    exec 7<"$authority_lock" || launcher_fail
    flock -s 7 || launcher_fail
    opened_authority_identity=$(opened_authority_lock_identity) ||
        launcher_fail
    authority_identity_is_trusted "$opened_authority_identity" ||
        launcher_fail
    current_authority_lock_identity=$(
        trusted_authority_lock_identity
    ) || launcher_fail
    [ "$expected_authority_lock_identity" = "$opened_authority_identity" ] &&
        [ "$expected_authority_lock_identity" = \
            "$current_authority_lock_identity" ] || launcher_fail
}

trusted_release_tree() {
    find "$1" -xdev -exec sh -c '
        expected_uid=$1
        shift
        for trusted_path do
            trusted_metadata=$(stat -c "%u:%a" -- "$trusted_path") ||
                exit 1
            [ "${trusted_metadata%%:*}" = "$expected_uid" ] ||
                exit 1
            trusted_mode=${trusted_metadata##*:}
            [ $((0$trusted_mode & 022)) -eq 0 ] ||
                exit 1
        done
    ' sh "$trusted_uid" {} +
}

launch_active_operations() {
    ladle_directory=${releases_directory%/*}
    [ "${current_release%/*}" = "$ladle_directory" ] || launcher_fail
    trusted_directory "$ladle_directory" || launcher_fail
    trusted_directory "$releases_directory" || launcher_fail
    acquire_operations_authority_lock
    [ -L "$current_release" ] || launcher_fail
    current_metadata=$(stat -c '%u:%a' -- "$current_release") ||
        launcher_fail
    [ "${current_metadata%%:*}" = "$trusted_uid" ] || launcher_fail

    active_release=$(readlink -f -- "$current_release") || launcher_fail
    revision=${active_release##*/}
    [ "${#revision}" -eq 40 ] || launcher_fail
    case "$revision" in
        *[!0-9a-f]*) launcher_fail ;;
    esac
    [ "$active_release" = "$releases_directory/$revision" ] ||
        launcher_fail
    trusted_release_tree "$active_release" || launcher_fail

    revision_marker=$active_release/.ladle-revision
    [ -f "$revision_marker" ] && [ ! -L "$revision_marker" ] ||
        launcher_fail
    [ "$(stat -c '%u:%a' -- "$revision_marker")" = "$trusted_uid:444" ] ||
        launcher_fail
    [ "$(wc -c <"$revision_marker" | tr -d ' ')" = 41 ] ||
        launcher_fail
    IFS= read -r marker_revision <"$revision_marker" || launcher_fail
    [ "$marker_revision" = "$revision" ] || launcher_fail

    operations_script=$active_release/Backend/deploy/vps/operations.sh
    [ -f "$operations_script" ] && [ ! -L "$operations_script" ] ||
        launcher_fail
    [ "$(stat -c '%u:%a' -- "$operations_script")" = "$trusted_uid:755" ] ||
        launcher_fail
    LADLE_OPERATIONS_EXPECTED_RELEASE=$active_release
    export LADLE_OPERATIONS_EXPECTED_RELEASE
    exec "$operations_script" "$@"
}

case ${0##*/} in
    operations-launcher.sh | ladle-operations) launch_active_operations "$@" ;;
esac
