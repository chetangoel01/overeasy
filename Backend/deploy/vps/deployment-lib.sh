#!/bin/sh
set -eu
umask 077

progress_log=/var/log/ladle/setup.log

die() {
    printf '%s\n' "$*" >&2
    return 1
}

validate_revision() {
    revision_candidate=$1
    case "$revision_candidate" in
        "" | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#revision_candidate}" -eq 40 ]
}

validate_hostname() {
    hostname_candidate=$1
    case "$hostname_candidate" in
        "" | *[!A-Za-z0-9.-]* | .* | *..* | *.)
            return 1
            ;;
    esac
    [ "${#hostname_candidate}" -le 253 ]
}

validate_dotenv_value() {
    dotenv_candidate=$1
    case "$dotenv_candidate" in
        "" | *[!A-Za-z0-9._:/@+-]*) return 1 ;;
        *) [ "${#dotenv_candidate}" -le 4096 ] ;;
    esac
}

read_dotenv_stdin_value() {
    DOTENV_STDIN_VALUE=
    if ! IFS= read -r DOTENV_STDIN_VALUE; then
        [ -n "$DOTENV_STDIN_VALUE" ] || return 1
    fi
    dotenv_extra_line=
    if IFS= read -r dotenv_extra_line || [ -n "$dotenv_extra_line" ]; then
        return 1
    fi
    validate_dotenv_value "$DOTENV_STDIN_VALUE"
}

validate_env_file() {
    dotenv_file=$1
    [ -f "$dotenv_file" ] && [ ! -L "$dotenv_file" ] || return 1
    LC_ALL=C awk '
        $0 !~ /^[A-Z][A-Z0-9_]*=[A-Za-z0-9._:\/@+-]+$/ {
            invalid = 1
            next
        }
        {
            key = $0
            sub(/=.*/, "", key)
            if (seen[key]++) {
                invalid = 1
            }
        }
        END {
            exit invalid
        }
    ' "$dotenv_file"
}

dotenv_value() {
    dotenv_file=$1
    dotenv_key=$2
    case "$dotenv_key" in
        "" | *[!A-Z0-9_]* | [0-9_]*) return 1 ;;
    esac
    validate_env_file "$dotenv_file" || return 1
    LC_ALL=C awk -F= -v target="$dotenv_key" '
        $1 == target {
            found++
            print substr($0, length($1) + 2)
        }
        END {
            exit found != 1
        }
    ' "$dotenv_file"
}

validate_required_env() {
    required_env_file=$1
    shift
    validate_env_file "$required_env_file" || return 1
    for required_env_key do
        dotenv_value "$required_env_file" "$required_env_key" >/dev/null ||
            return 1
    done
}

validate_env_metadata() {
    metadata_file=$1
    metadata_group=$2
    [ -f "$metadata_file" ] && [ ! -L "$metadata_file" ] || return 1
    expected_group_id=$(getent group "$metadata_group" | awk -F: 'NR == 1 { print $3 }')
    [ -n "$expected_group_id" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$metadata_file")" = "0:$expected_group_id:640" ]
}

revision_marker_matches() {
    marker_file=$1
    expected_revision=$2
    [ -f "$marker_file" ] && [ ! -L "$marker_file" ] || return 1
    LC_ALL=C awk -v expected="$expected_revision" '
        NR == 1 && $0 == expected {
            matched = 1
            next
        }
        {
            matched = 0
        }
        END {
            exit !(matched && NR == 1)
        }
    ' "$marker_file"
}

activate_release() {
    activation_release=$1
    activation_current=$2
    [ -d "$activation_release" ] && [ ! -L "$activation_release" ] || return 1
    activation_canonical=$(readlink -f -- "$activation_release") || return 1
    [ "$activation_canonical" = "$activation_release" ] || return 1
    if [ -e "$activation_current" ] && [ ! -L "$activation_current" ]; then
        return 1
    fi
    activation_link=$activation_current.next.$$
    [ ! -e "$activation_link" ] && [ ! -L "$activation_link" ] || return 1
    ln -s -- "$activation_release" "$activation_link" || return 1
    activation_status=0
    if mv --help 2>/dev/null | grep -q -- '--no-target-directory'; then
        mv -Tf -- "$activation_link" "$activation_current" ||
            activation_status=$?
    else
        mv -fh -- "$activation_link" "$activation_current" ||
            activation_status=$?
    fi
    if [ "$activation_status" -ne 0 ]; then
        rm -f -- "$activation_link"
        return 1
    fi
}

validate_progress_text() {
    progress_phase_candidate=$1
    progress_message_candidate=$2
    case "$progress_phase_candidate" in
        "" | *[!a-z0-9-]*) return 1 ;;
    esac
    LC_ALL=C printf '%s\n' "$progress_message_candidate" |
        LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9.,_:/() -]*$'
}

progress_init() {
    progress_group=$1
    [ "$(id -u)" -eq 0 ] || return 1
    if ! getent group "$progress_group" >/dev/null 2>&1; then
        groupadd --system "$progress_group"
    fi
    progress_group_id=$(
        getent group "$progress_group" | awk -F: 'NR == 1 { print $3 }'
    )
    [ -n "$progress_group_id" ] || return 1
    if [ -e /var/log/ladle ] || [ -L /var/log/ladle ]; then
        [ -d /var/log/ladle ] && [ ! -L /var/log/ladle ] || return 1
    else
        install -d -o root -g "$progress_group" -m 0750 /var/log/ladle
    fi
    [ "$(readlink -f -- /var/log/ladle)" = /var/log/ladle ] || return 1
    chown root:"$progress_group" /var/log/ladle
    chmod 0750 /var/log/ladle
    if [ -e "$progress_log" ] || [ -L "$progress_log" ]; then
        [ -f "$progress_log" ] && [ ! -L "$progress_log" ] || return 1
    else
        install -o root -g "$progress_group" -m 0640 /dev/null "$progress_log"
    fi
    chown root:"$progress_group" "$progress_log"
    chmod 0640 "$progress_log"
    [ "$(stat -c '%u:%g:%a' -- "$progress_log")" = "0:$progress_group_id:640" ]
}

progress() {
    progress_phase=$1
    progress_message=$2
    validate_progress_text "$progress_phase" "$progress_message" || return 1
    progress_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    progress_line="[$progress_timestamp] $progress_phase: $progress_message"
    printf "%s\n" "$progress_line"
    printf "%s\n" "$progress_line" >>"$progress_log"
}
