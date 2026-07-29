#!/bin/sh
set -eu
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

current_release=/opt/ladle/current
releases_directory=/opt/ladle/releases
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
    exec "$operations_script" "$@"
}

case ${0##*/} in
    operations-launcher.sh | ladle-operations) launch_active_operations "$@" ;;
esac
