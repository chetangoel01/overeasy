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
transaction_health_enable_state=
transaction_backup_enable_state=
transaction_health_active_state=
transaction_backup_active_state=
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

installed_operations_state() {
    installed_binary=$1
    installed_unit_directory=$2
    installed_uid=$3
    installed_count=0
    for installed_target in \
        "$installed_binary:755" \
        "$installed_unit_directory/ladle-health.service:644" \
        "$installed_unit_directory/ladle-health.timer:644" \
        "$installed_unit_directory/ladle-backup.service:644" \
        "$installed_unit_directory/ladle-backup.timer:644"; do
        installed_mode=${installed_target##*:}
        installed_path=${installed_target%:*}
        if [ -e "$installed_path" ] || [ -L "$installed_path" ]; then
            target_metadata_is_safe \
                "$installed_path" "$installed_uid" "$installed_mode" ||
                return 1
            installed_count=$((installed_count + 1))
        fi
    done
    case "$installed_count" in
        0) printf '%s\n' absent ;;
        5) printf '%s\n' complete ;;
        *) return 1 ;;
    esac
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

report_preserved_recovery_files() {
    printf '%s\n' \
        "Operations rollback incomplete; root-only recovery files remain as .ladle-backup.* beside their targets." \
        >&2
}

report_uncertain_rollback_targets() {
    printf '%s\n' \
        "Operations rollback incomplete; mixed/new targets may remain and require root inspection." \
        >&2
}

report_stale_transaction_stages() {
    printf '%s\n' \
        "Operations targets were restored; stale root-only .ladle-stage.* artifacts may remain beside their targets." \
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

restore_transaction_entry() {
    entry_existed=$1
    entry_backup=$2
    entry_target=$3
    if restore_transaction_target \
        "$entry_existed" "$entry_backup" "$entry_target"; then
        return 0
    fi
    rollback_restore_result=1
    if [ "$entry_existed" = true ] &&
        [ -n "$entry_backup" ] &&
        [ -f "$entry_backup" ]; then
        rollback_recovery_files_preserved=true
    else
        rollback_targets_uncertain=true
    fi
}

rollback_operations_install() {
    rollback_restore_result=0
    rollback_stage_cleanup_result=0
    rollback_recovery_files_preserved=false
    rollback_targets_uncertain=false
    restore_transaction_entry \
        "$transaction_binary_existed" \
        "$transaction_binary_backup" \
        "$transaction_binary_target"
    restore_transaction_entry \
        "$transaction_health_service_existed" \
        "$transaction_health_service_backup" \
        "$transaction_health_service_target"
    restore_transaction_entry \
        "$transaction_health_timer_existed" \
        "$transaction_health_timer_backup" \
        "$transaction_health_timer_target"
    restore_transaction_entry \
        "$transaction_backup_service_existed" \
        "$transaction_backup_service_backup" \
        "$transaction_backup_service_target"
    restore_transaction_entry \
        "$transaction_backup_timer_existed" \
        "$transaction_backup_timer_backup" \
        "$transaction_backup_timer_target"
    cleanup_transaction_stages || rollback_stage_cleanup_result=1
    if [ "$rollback_restore_result" -ne 0 ]; then
        if [ "$rollback_recovery_files_preserved" = true ]; then
            report_preserved_recovery_files
        fi
        if [ "$rollback_targets_uncertain" = true ]; then
            report_uncertain_rollback_targets
        fi
        if [ "$rollback_stage_cleanup_result" -ne 0 ]; then
            printf '%s\n' \
                "Stale root-only .ladle-stage.* artifacts may also remain beside operation targets." \
                >&2
        fi
        return 1
    fi
    if [ "$rollback_stage_cleanup_result" -ne 0 ]; then
        report_stale_transaction_stages
        return 1
    fi
    if ! cleanup_transaction_recovery_files; then
        printf '%s\n' \
            "Operations targets were restored; stale root-only .ladle-backup.* files may remain beside their targets." \
            >&2
        return 1
    fi
    return 0
}

timer_enable_state() {
    timer_unit=$1
    timer_query_output=
    timer_query_status=0
    if timer_query_output=$(systemctl is-enabled "$timer_unit" 2>/dev/null); then
        timer_query_status=0
    else
        timer_query_status=$?
    fi
    case "$timer_query_status:$timer_query_output" in
        0:enabled | 0:enabled-runtime | 1:disabled | 4:not-found)
            printf '%s\n' "$timer_query_output"
            ;;
        *) return 1 ;;
    esac
}

timer_active_state() {
    timer_unit=$1
    timer_query_output=
    timer_query_status=0
    if timer_query_output=$(systemctl is-active "$timer_unit" 2>/dev/null); then
        timer_query_status=0
    else
        timer_query_status=$?
    fi
    case "$timer_query_status:$timer_query_output" in
        0:active | 3:inactive) printf '%s\n' "$timer_query_output" ;;
        *) return 1 ;;
    esac
}

snapshot_timer_state() {
    transaction_health_enable_state=$(
        timer_enable_state ladle-health.timer
    ) || return 1
    transaction_backup_enable_state=$(
        timer_enable_state ladle-backup.timer
    ) || return 1
    if [ "$transaction_health_enable_state" = not-found ]; then
        transaction_health_active_state=not-found
    else
        transaction_health_active_state=$(
            timer_active_state ladle-health.timer
        ) || return 1
    fi
    if [ "$transaction_backup_enable_state" = not-found ]; then
        transaction_backup_active_state=not-found
    else
        transaction_backup_active_state=$(
            timer_active_state ladle-backup.timer
        ) || return 1
    fi
}

restore_timer_enable_state() {
    timer_prior_state=$1
    timer_unit=$2
    case "$timer_prior_state" in
        enabled) systemctl enable "$timer_unit" ;;
        enabled-runtime) systemctl enable --runtime "$timer_unit" ;;
        disabled | not-found) return 0 ;;
        *) return 1 ;;
    esac
}

restore_timer_active_state() {
    timer_prior_state=$1
    timer_unit=$2
    case "$timer_prior_state" in
        active) systemctl start "$timer_unit" ;;
        inactive | not-found) return 0 ;;
        *) return 1 ;;
    esac
}

restore_timer_state() {
    timer_restore_result=0
    restore_timer_enable_state \
        "$transaction_health_enable_state" ladle-health.timer ||
        timer_restore_result=1
    restore_timer_enable_state \
        "$transaction_backup_enable_state" ladle-backup.timer ||
        timer_restore_result=1
    restore_timer_active_state \
        "$transaction_health_active_state" ladle-health.timer ||
        timer_restore_result=1
    restore_timer_active_state \
        "$transaction_backup_active_state" ladle-backup.timer ||
        timer_restore_result=1
    [ "$timer_restore_result" -eq 0 ]
}

rollback_after_activation_failure() {
    activation_rollback_result=0
    activation_files_restored=true
    activation_units_reloaded=true
    systemctl disable --now ladle-health.timer ladle-backup.timer ||
        activation_rollback_result=1
    if ! rollback_operations_install; then
        activation_files_restored=false
        activation_rollback_result=1
    fi
    if ! systemctl daemon-reload; then
        activation_units_reloaded=false
        activation_rollback_result=1
    fi
    if [ "$activation_files_restored" = true ] &&
        [ "$activation_units_reloaded" = true ]; then
        restore_timer_state || activation_rollback_result=1
    fi
    [ "$activation_rollback_result" -eq 0 ]
}

report_timer_reconciliation_failure() {
    printf '%s\n' \
        "Operations rollback incomplete; timer state or loaded units require inspection." \
        >&2
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
    live_rollback_result=0
    transaction_live=false
    clear_transaction_traps
    rollback_operations_install || live_rollback_result=1
    systemctl daemon-reload || live_rollback_result=1
    if [ "$live_rollback_result" -ne 0 ]; then
        report_timer_reconciliation_failure
    fi
    return 1
}

abort_activation_transaction() {
    transaction_live=false
    clear_transaction_traps
    if ! rollback_after_activation_failure; then
        report_timer_reconciliation_failure
    fi
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
        report_timer_reconciliation_failure
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
    transaction_mode=${5:-install}
    case "$transaction_mode" in
        install | refresh) ;;
        *) return 1 ;;
    esac
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

    if [ "$transaction_mode" = install ]; then
        transaction_health_enable_state=
        transaction_backup_enable_state=
        transaction_health_active_state=
        transaction_backup_active_state=
        if ! snapshot_timer_state; then
            printf '%s\n' \
                "Cannot safely snapshot prior Ladle timer state." >&2
            abort_transaction_preflight
            return 1
        fi
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
    if [ "$transaction_mode" = refresh ]; then
        transaction_committed=true
        transaction_live=false
        if ! cleanup_transaction_artifacts; then
            printf '%s\n' \
                "Operations refresh committed; stale rollback files require cleanup." \
                >&2
        fi
        clear_transaction_traps
        return 0
    fi
    transaction_activation_touched=true
    if ! systemctl enable ladle-health.timer ladle-backup.timer; then
        abort_activation_transaction
        return 1
    fi
    if ! systemctl start ladle-backup.service; then
        abort_activation_transaction
        return 1
    fi
    if ! systemctl start ladle-backup.timer; then
        abort_activation_transaction
        return 1
    fi
    if ! systemctl start ladle-health.timer; then
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
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        printf '%s\n' \
            "Usage: install-operations.sh FULL_GIT_COMMIT [refresh]" >&2
        return 1
    fi

    revision=$1
    install_mode=${2:-install}
    case "$install_mode" in
        install | refresh) ;;
        *)
            printf '%s\n' \
                "Usage: install-operations.sh FULL_GIT_COMMIT [refresh]" >&2
            return 1
            ;;
    esac
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

    if [ "$install_mode" = refresh ]; then
        refresh_state=$(
            installed_operations_state \
                /usr/local/sbin/ladle-operations \
                /etc/systemd/system 0
        ) || {
            printf '%s\n' \
                "The installed operations set is partial or unsafe." >&2
            return 1
        }
        if [ "$refresh_state" = absent ]; then
            printf '%s\n' \
                "Operations refresh skipped because no installed set exists."
            return 0
        fi
    fi

    ensure_root_directory /var/backups/ladle 700
    ensure_root_directory /var/lib/ladle 750
    ensure_root_directory /var/lib/ladle/locks 700
    ensure_root_directory /var/lib/ladle/operations 700
    ensure_root_directory /usr/local/sbin 755
    ensure_root_directory /etc/systemd/system 755
    for required_lock in \
        /var/lib/ladle/locks/deploy.lock \
        /var/lib/ladle/locks/environment.lock \
        /var/lib/ladle/locks/transition.lock; do
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
        0 "$install_mode" ||
        return 1
    if [ "$install_mode" = refresh ]; then
        printf '%s\n' "Ladle operations refreshed."
    else
        printf '%s\n' "Ladle health and backup timers installed."
    fi
}

case ${0##*/} in
    install-operations.sh) install_operations_main "$@" ;;
esac
