#!/bin/sh
set -eu
umask 077

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

unit_names="ladle-health.service ladle-health.timer ladle-backup.service ladle-backup.timer"
timer_names="ladle-health.timer ladle-backup.timer"

transaction_binary_stage=
transaction_health_service_stage=
transaction_health_timer_stage=
transaction_backup_service_stage=
transaction_backup_timer_stage=
transaction_binary_backup=
transaction_health_service_backup=
transaction_health_timer_backup=
transaction_backup_service_backup=
transaction_backup_timer_backup=
transaction_binary_existed=false
transaction_health_service_existed=false
transaction_health_timer_existed=false
transaction_backup_service_existed=false
transaction_backup_timer_existed=false
transaction_health_enabled=false
transaction_backup_enabled=false
transaction_health_active=false
transaction_backup_active=false
transaction_live=false
transaction_activation_touched=false
transaction_committed=false

target_metadata_is_safe() {
    metadata_target=$1
    metadata_uid=$2
    metadata_mode=$3
    [ -f "$metadata_target" ] && [ ! -L "$metadata_target" ] || return 1
    [ "$(stat -c '%u:%a' -- "$metadata_target")" = \
        "$metadata_uid:$metadata_mode" ]
}

cleanup_verification_directory() {
    verification_directory=$1
    [ -n "$verification_directory" ] || return 0
    rm -f -- \
        "$verification_directory/ladle-health.service" \
        "$verification_directory/ladle-health.timer" \
        "$verification_directory/ladle-backup.service" \
        "$verification_directory/ladle-backup.timer" || return 1
    rmdir "$verification_directory"
}

cleanup_transaction_stages() {
    stage_cleanup_result=0
    for cleanup_path in \
        "$transaction_binary_stage" \
        "$transaction_health_service_stage" \
        "$transaction_health_timer_stage" \
        "$transaction_backup_service_stage" \
        "$transaction_backup_timer_stage"; do
        if [ -n "$cleanup_path" ] && [ -e "$cleanup_path" ]; then
            rm -f -- "$cleanup_path" || stage_cleanup_result=1
        fi
    done
    [ "$stage_cleanup_result" -eq 0 ]
}

cleanup_transaction_recovery_files() {
    recovery_cleanup_result=0
    for cleanup_path in \
        "$transaction_binary_backup" \
        "$transaction_health_service_backup" \
        "$transaction_health_timer_backup" \
        "$transaction_backup_service_backup" \
        "$transaction_backup_timer_backup"; do
        if [ -n "$cleanup_path" ] && [ -e "$cleanup_path" ]; then
            rm -f -- "$cleanup_path" || recovery_cleanup_result=1
        fi
    done
    [ "$recovery_cleanup_result" -eq 0 ]
}

cleanup_transaction_artifacts() {
    transaction_cleanup_result=0
    cleanup_transaction_stages || transaction_cleanup_result=1
    cleanup_transaction_recovery_files || transaction_cleanup_result=1
    [ "$transaction_cleanup_result" -eq 0 ]
}

report_incomplete_rollback() {
    printf '%s\n' \
        "Operations rollback incomplete; root-only recovery files remain as .ladle-backup.* beside their targets." \
        >&2
}

restore_transaction_target() {
    restore_existed=$1
    restore_backup=$2
    restore_target=$3
    if [ "$restore_existed" = true ]; then
        [ -f "$restore_backup" ] || return 1
        mv -f -- "$restore_backup" "$restore_target"
    else
        rm -f -- "$restore_target"
    fi
}

rollback_operations_install() {
    rollback_result=0
    restore_transaction_target \
        "$transaction_binary_existed" \
        "$transaction_binary_backup" \
        "$transaction_binary_target" || rollback_result=1
    restore_transaction_target \
        "$transaction_health_service_existed" \
        "$transaction_health_service_backup" \
        "$transaction_health_service_target" || rollback_result=1
    restore_transaction_target \
        "$transaction_health_timer_existed" \
        "$transaction_health_timer_backup" \
        "$transaction_health_timer_target" || rollback_result=1
    restore_transaction_target \
        "$transaction_backup_service_existed" \
        "$transaction_backup_service_backup" \
        "$transaction_backup_service_target" || rollback_result=1
    restore_transaction_target \
        "$transaction_backup_timer_existed" \
        "$transaction_backup_timer_backup" \
        "$transaction_backup_timer_target" || rollback_result=1
    cleanup_transaction_stages || rollback_result=1
    if [ "$rollback_result" -ne 0 ]; then
        report_incomplete_rollback
        return 1
    fi
    cleanup_transaction_recovery_files || rollback_result=1
    [ "$rollback_result" -eq 0 ]
}

restore_timer_state() {
    timer_restore_result=0
    if [ "$transaction_health_enabled" = true ]; then
        systemctl enable ladle-health.timer || timer_restore_result=1
    fi
    if [ "$transaction_backup_enabled" = true ]; then
        systemctl enable ladle-backup.timer || timer_restore_result=1
    fi
    if [ "$transaction_health_active" = true ]; then
        systemctl start ladle-health.timer || timer_restore_result=1
    fi
    if [ "$transaction_backup_active" = true ]; then
        systemctl start ladle-backup.timer || timer_restore_result=1
    fi
    [ "$timer_restore_result" -eq 0 ]
}

rollback_after_activation_failure() {
    activation_rollback_result=0
    activation_files_restored=true
    systemctl disable --now ladle-health.timer ladle-backup.timer ||
        activation_rollback_result=1
    if ! rollback_operations_install; then
        activation_files_restored=false
        activation_rollback_result=1
    fi
    systemctl daemon-reload || activation_rollback_result=1
    if [ "$activation_files_restored" = true ]; then
        restore_timer_state || activation_rollback_result=1
    fi
    [ "$activation_rollback_result" -eq 0 ]
}

clear_transaction_traps() {
    trap - HUP INT TERM
}

abort_transaction_preflight() {
    clear_transaction_traps
    cleanup_transaction_artifacts || true
    return 1
}

abort_live_transaction() {
    transaction_live=false
    clear_transaction_traps
    rollback_operations_install || true
    systemctl daemon-reload || true
    return 1
}

abort_activation_transaction() {
    transaction_live=false
    clear_transaction_traps
    rollback_after_activation_failure || true
    return 1
}

handle_transaction_signal() {
    handled_signal=$1
    signal_rollback_result=0
    trap '' HUP INT TERM
    if [ "$transaction_committed" = true ]; then
        if ! cleanup_transaction_artifacts; then
            printf '%s\n' \
                "Operations install committed; stale rollback files require cleanup." \
                >&2
        fi
        exit 0
    fi
    if [ "$transaction_live" = true ]; then
        if [ "$transaction_activation_touched" = true ]; then
            rollback_after_activation_failure || signal_rollback_result=1
        else
            rollback_operations_install || signal_rollback_result=1
            systemctl daemon-reload || signal_rollback_result=1
        fi
    else
        cleanup_transaction_artifacts || signal_rollback_result=1
    fi
    if [ "$signal_rollback_result" -ne 0 ]; then
        printf 'Operations install interrupted by %s; rollback incomplete.\n' \
            "$handled_signal" >&2
        exit 1
    fi
    printf 'Operations install interrupted by %s; prior state restored.\n' \
        "$handled_signal" >&2
    exit 1
}

stage_transaction_target() {
    stage_source=$1
    stage_target=$2
    stage_mode=$3
    stage_uid=$4
    stage_path=$(mktemp "$(dirname -- "$stage_target")/.ladle-stage.XXXXXX") ||
        return 1
    if ! install -o root -g root -m "$stage_mode" \
        "$stage_source" "$stage_path" ||
        ! target_metadata_is_safe "$stage_path" "$stage_uid" "$stage_mode"; then
        rm -f -- "$stage_path" || true
        return 1
    fi
    printf '%s\n' "$stage_path"
}

backup_transaction_target() {
    backup_target=$1
    backup_mode=$2
    backup_uid=$3
    if [ ! -e "$backup_target" ] && [ ! -L "$backup_target" ]; then
        printf '%s\n' absent
        return 0
    fi
    target_metadata_is_safe "$backup_target" "$backup_uid" "$backup_mode" ||
        return 1
    backup_path=$(mktemp "$(dirname -- "$backup_target")/.ladle-backup.XXXXXX") ||
        return 1
    if ! install -o root -g root -m "$backup_mode" \
        "$backup_target" "$backup_path" ||
        ! target_metadata_is_safe "$backup_path" "$backup_uid" "$backup_mode"; then
        rm -f -- "$backup_path" || true
        return 1
    fi
    printf '%s\n' "$backup_path"
}

verify_staged_units() {
    verification_binary=$1
    verification_health_service=$2
    verification_health_timer=$3
    verification_backup_service=$4
    verification_backup_timer=$5
    verification_directory=$(mktemp -d /tmp/ladle-unit-verify.XXXXXX) ||
        return 1
    if ! sed \
        "s#^ExecStart=/usr/local/sbin/ladle-operations #ExecStart=$verification_binary #" \
        "$verification_health_service" \
        >"$verification_directory/ladle-health.service" ||
        ! cp "$verification_health_timer" \
            "$verification_directory/ladle-health.timer" ||
        ! sed \
            "s#^ExecStart=/usr/local/sbin/ladle-operations #ExecStart=$verification_binary #" \
            "$verification_backup_service" \
            >"$verification_directory/ladle-backup.service" ||
        ! cp "$verification_backup_timer" \
            "$verification_directory/ladle-backup.timer"; then
        cleanup_verification_directory "$verification_directory" || true
        return 1
    fi
    verification_result=0
    systemd-analyze verify \
        "$verification_directory/ladle-health.service" \
        "$verification_directory/ladle-health.timer" \
        "$verification_directory/ladle-backup.service" \
        "$verification_directory/ladle-backup.timer" ||
        verification_result=1
    cleanup_verification_directory "$verification_directory" ||
        verification_result=1
    [ "$verification_result" -eq 0 ]
}

transactional_install_operations() {
    transaction_source_directory=$1
    transaction_binary_target=$2
    transaction_unit_directory=$3
    transaction_uid=$4
    transaction_health_service_target=$transaction_unit_directory/ladle-health.service
    transaction_health_timer_target=$transaction_unit_directory/ladle-health.timer
    transaction_backup_service_target=$transaction_unit_directory/ladle-backup.service
    transaction_backup_timer_target=$transaction_unit_directory/ladle-backup.timer

    transaction_binary_stage=
    transaction_health_service_stage=
    transaction_health_timer_stage=
    transaction_backup_service_stage=
    transaction_backup_timer_stage=
    transaction_binary_backup=
    transaction_health_service_backup=
    transaction_health_timer_backup=
    transaction_backup_service_backup=
    transaction_backup_timer_backup=
    transaction_binary_existed=false
    transaction_health_service_existed=false
    transaction_health_timer_existed=false
    transaction_backup_service_existed=false
    transaction_backup_timer_existed=false
    transaction_live=false
    transaction_activation_touched=false
    transaction_committed=false
    trap 'handle_transaction_signal HUP' HUP
    trap 'handle_transaction_signal INT' INT
    trap 'handle_transaction_signal TERM' TERM

    transaction_binary_stage=$(
        stage_transaction_target \
            "$transaction_source_directory/operations.sh" \
            "$transaction_binary_target" 755 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }
    transaction_health_service_stage=$(
        stage_transaction_target \
            "$transaction_source_directory/ladle-health.service" \
            "$transaction_health_service_target" 644 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }
    transaction_health_timer_stage=$(
        stage_transaction_target \
            "$transaction_source_directory/ladle-health.timer" \
            "$transaction_health_timer_target" 644 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }
    transaction_backup_service_stage=$(
        stage_transaction_target \
            "$transaction_source_directory/ladle-backup.service" \
            "$transaction_backup_service_target" 644 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }
    transaction_backup_timer_stage=$(
        stage_transaction_target \
            "$transaction_source_directory/ladle-backup.timer" \
            "$transaction_backup_timer_target" 644 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }

    binary_backup_result=$(
        backup_transaction_target \
            "$transaction_binary_target" 755 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }
    if [ "$binary_backup_result" = absent ]; then
        transaction_binary_existed=false
    else
        transaction_binary_existed=true
        transaction_binary_backup=$binary_backup_result
    fi
    health_service_backup_result=$(
        backup_transaction_target \
            "$transaction_health_service_target" 644 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }
    if [ "$health_service_backup_result" = absent ]; then
        transaction_health_service_existed=false
    else
        transaction_health_service_existed=true
        transaction_health_service_backup=$health_service_backup_result
    fi
    health_timer_backup_result=$(
        backup_transaction_target \
            "$transaction_health_timer_target" 644 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }
    if [ "$health_timer_backup_result" = absent ]; then
        transaction_health_timer_existed=false
    else
        transaction_health_timer_existed=true
        transaction_health_timer_backup=$health_timer_backup_result
    fi
    backup_service_backup_result=$(
        backup_transaction_target \
            "$transaction_backup_service_target" 644 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }
    if [ "$backup_service_backup_result" = absent ]; then
        transaction_backup_service_existed=false
    else
        transaction_backup_service_existed=true
        transaction_backup_service_backup=$backup_service_backup_result
    fi
    backup_timer_backup_result=$(
        backup_transaction_target \
            "$transaction_backup_timer_target" 644 "$transaction_uid"
    ) || {
        abort_transaction_preflight
        return 1
    }
    if [ "$backup_timer_backup_result" = absent ]; then
        transaction_backup_timer_existed=false
    else
        transaction_backup_timer_existed=true
        transaction_backup_timer_backup=$backup_timer_backup_result
    fi

    verify_staged_units \
        "$transaction_binary_stage" \
        "$transaction_health_service_stage" \
        "$transaction_health_timer_stage" \
        "$transaction_backup_service_stage" \
        "$transaction_backup_timer_stage" || {
        abort_transaction_preflight
        return 1
    }

    transaction_health_enabled=false
    transaction_backup_enabled=false
    transaction_health_active=false
    transaction_backup_active=false
    if systemctl is-enabled --quiet ladle-health.timer; then
        transaction_health_enabled=true
    fi
    if systemctl is-enabled --quiet ladle-backup.timer; then
        transaction_backup_enabled=true
    fi
    if systemctl is-active --quiet ladle-health.timer; then
        transaction_health_active=true
    fi
    if systemctl is-active --quiet ladle-backup.timer; then
        transaction_backup_active=true
    fi

    transaction_live=true
    if ! mv -f -- "$transaction_binary_stage" "$transaction_binary_target"; then
        abort_live_transaction
        return 1
    fi
    transaction_binary_stage=
    if ! mv -f -- "$transaction_health_service_stage" \
        "$transaction_health_service_target"; then
        abort_live_transaction
        return 1
    fi
    transaction_health_service_stage=
    if ! mv -f -- "$transaction_health_timer_stage" \
        "$transaction_health_timer_target"; then
        abort_live_transaction
        return 1
    fi
    transaction_health_timer_stage=
    if ! mv -f -- "$transaction_backup_service_stage" \
        "$transaction_backup_service_target"; then
        abort_live_transaction
        return 1
    fi
    transaction_backup_service_stage=
    if ! mv -f -- "$transaction_backup_timer_stage" \
        "$transaction_backup_timer_target"; then
        abort_live_transaction
        return 1
    fi
    transaction_backup_timer_stage=

    if ! systemctl daemon-reload; then
        abort_live_transaction
        return 1
    fi
    transaction_activation_touched=true
    if ! systemctl enable ladle-health.timer ladle-backup.timer; then
        abort_activation_transaction
        return 1
    fi
    if ! systemctl start ladle-health.timer ladle-backup.timer; then
        abort_activation_transaction
        return 1
    fi
    transaction_committed=true
    transaction_live=false
    if ! cleanup_transaction_artifacts; then
        printf '%s\n' \
            "Operations install committed; stale rollback files require cleanup." \
            >&2
    fi
    clear_transaction_traps
    return 0
}

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

install_operations_main() {
    if [ "$(id -u)" -ne 0 ]; then
        printf '%s\n' "Run install-operations.sh as root." >&2
        return 1
    fi
    if [ "$#" -ne 1 ]; then
        printf '%s\n' "Usage: install-operations.sh FULL_GIT_COMMIT" >&2
        return 1
    fi

    revision=$1
    if [ "${#revision}" -ne 40 ]; then
        printf '%s\n' "Revision must be a full lowercase Git commit." >&2
        return 1
    fi
    case "$revision" in
        *[!0-9a-f]*)
            printf '%s\n' "Revision must be a full lowercase Git commit." >&2
            return 1
            ;;
    esac

    release=/opt/ladle/releases/$revision
    script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
    expected_script_directory=$release/Backend/deploy/vps
    if [ "$script_directory" != "$expected_script_directory" ]; then
        printf '%s\n' "Run the installer from the requested exact release." >&2
        return 1
    fi
    if [ ! -d "$release" ] || [ -L "$release" ] ||
        [ "$(readlink -f -- "$release")" != "$release" ] ||
        [ "$(stat -c '%u:%a' -- "$release")" != "0:755" ]; then
        printf '%s\n' "The exact release metadata is unsafe." >&2
        return 1
    fi
    if find "$release" -xdev \( ! -user root -o -perm /022 \) -print -quit |
        grep -q .; then
        printf '%s\n' "The exact release contains mutable content." >&2
        return 1
    fi

    revision_marker=$release/.ladle-revision
    if [ ! -f "$revision_marker" ] || [ -L "$revision_marker" ] ||
        [ "$(stat -c '%u:%a' -- "$revision_marker")" != "0:444" ] ||
        [ "$(cat "$revision_marker")" != "$revision" ]; then
        printf '%s\n' "The exact release revision marker is invalid." >&2
        return 1
    fi

    operations_source=$script_directory/operations.sh
    for executable_source in \
        "$operations_source" \
        "$script_directory/install-operations.sh"; do
        if [ ! -f "$executable_source" ] || [ -L "$executable_source" ] ||
            [ "$(stat -c '%u:%a' -- "$executable_source")" != "0:755" ]; then
            printf '%s\n' "An operations executable is unsafe." >&2
            return 1
        fi
    done
    for unit_name in $unit_names; do
        unit_source=$script_directory/$unit_name
        if [ ! -f "$unit_source" ] || [ -L "$unit_source" ] ||
            [ "$(stat -c '%u:%a' -- "$unit_source")" != "0:644" ]; then
            printf '%s\n' "An operations unit is unsafe." >&2
            return 1
        fi
    done

    ensure_root_directory /var/backups/ladle 700
    ensure_root_directory /var/lib/ladle 750
    ensure_root_directory /var/lib/ladle/locks 700
    ensure_root_directory /var/lib/ladle/operations 700
    ensure_root_directory /usr/local/sbin 755
    ensure_root_directory /etc/systemd/system 755
    for required_lock in \
        /var/lib/ladle/locks/deploy.lock \
        /var/lib/ladle/locks/environment.lock; do
        if ! target_metadata_is_safe "$required_lock" 0 600; then
            printf '%s\n' "A persistent Ladle lock file is unsafe." >&2
            return 1
        fi
    done

    secret_group=ladle-secrets
    secret_group_id=$(
        getent group "$secret_group" | awk -F: 'NR == 1 { print $3 }'
    )
    [ -n "$secret_group_id" ] || {
        printf '%s\n' "The Ladle secrets group is missing." >&2
        return 1
    }
    if [ ! -d /var/log/ladle ] || [ -L /var/log/ladle ] ||
        [ "$(readlink -f -- /var/log/ladle)" != /var/log/ladle ] ||
        [ "$(stat -c '%u:%g:%a' -- /var/log/ladle)" != \
            "0:$secret_group_id:750" ]; then
        printf '%s\n' "The Ladle log directory is unsafe." >&2
        return 1
    fi
    operations_log=/var/log/ladle/operations.log
    if [ -e "$operations_log" ] || [ -L "$operations_log" ]; then
        if [ ! -f "$operations_log" ] || [ -L "$operations_log" ] ||
            [ "$(stat -c '%u:%g:%a' -- "$operations_log")" != \
                "0:$secret_group_id:640" ]; then
            printf '%s\n' "The operations log metadata is unsafe." >&2
            return 1
        fi
    else
        install -o root -g "$secret_group" -m 0640 \
            /dev/null "$operations_log"
    fi

    transactional_install_operations \
        "$script_directory" \
        /usr/local/sbin/ladle-operations \
        /etc/systemd/system \
        0 ||
        return 1
    printf '%s\n' "Ladle health and backup timers installed."
}

case ${0##*/} in
    install-operations.sh) install_operations_main "$@" ;;
esac
