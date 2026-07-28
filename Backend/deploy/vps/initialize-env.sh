#!/bin/sh
set -eu
umask 077

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "Run initialize-env.sh as root." >&2
    exit 1
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
deployment_library=$script_directory/deployment-lib.sh
if [ ! -f "$deployment_library" ] || [ -L "$deployment_library" ]; then
    printf '%s\n' "Missing deployment library." >&2
    exit 1
fi
. "$deployment_library"

secret_group="ladle-secrets"
env_file=/etc/ladle/ladle.env
staging_key_file=/etc/ladle/staging-access-key
environment_lock=/var/lock/ladle-environment.lock
env_tmp=
staging_tmp=
initialization_phase=environment

cleanup() {
    status=$?
    if [ -n "$env_tmp" ]; then
        rm -f -- "$env_tmp"
    fi
    if [ -n "$staging_tmp" ]; then
        rm -f -- "$staging_tmp"
    fi
    if [ "$status" -ne 0 ] && [ -f "$progress_log" ]; then
        progress failure "$initialization_phase failed" || true
    fi
    trap - 0
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

acquire_environment_lock "$environment_lock" 0 ||
    die "Cannot acquire the staging environment lock."
if ! getent group "$secret_group" >/dev/null 2>&1; then
    groupadd --system "$secret_group"
fi
install -d -o root -g "$secret_group" -m 0750 /etc/ladle
if [ "$(readlink -f -- /etc/ladle)" != /etc/ladle ]; then
    die "The Ladle environment directory must not contain symlinks."
fi
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    case "$SUDO_USER" in
        *[!A-Za-z0-9_.-]*) die "Unsafe sudo user name." ;;
        *) usermod -a -G "$secret_group" "$SUDO_USER" ;;
    esac
fi
progress_init "$secret_group"
progress "environment" "validating private staging environment"

read_staging_key() {
    staging_read_file=$1
    [ -f "$staging_read_file" ] && [ ! -L "$staging_read_file" ] || return 1
    validate_env_metadata "$staging_read_file" "$secret_group" || return 1
    IFS= read -r staging_read_value <"$staging_read_file" || return 1
    [ "$(wc -l <"$staging_read_file" | tr -d ' ')" = 1 ] || return 1
    validate_dotenv_value "$staging_read_value" || return 1
    STAGING_KEY_VALUE=$staging_read_value
}

random_hex() {
    random_bytes=$1
    random_value=$(openssl rand -hex "$random_bytes") || return 1
    case "$random_value" in
        "" | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#random_value}" -eq "$((random_bytes * 2))" ] || return 1
    printf '%s\n' "$random_value"
}

existing_tunnel_key=
if [ -e "$env_file" ] || [ -L "$env_file" ]; then
    validate_env_metadata "$env_file" "$secret_group" ||
        die "Existing environment metadata is unsafe."
    validate_staging_environment "$env_file" ||
        die "Existing environment is incomplete or invalid."
    existing_tunnel_key=$(dotenv_value "$env_file" LADLE_TUNNEL_ACCESS_KEY) ||
        die "Existing tunnel key is invalid."
else
    LADLE_PUBLIC_HOSTNAME=${LADLE_PUBLIC_HOSTNAME:-api.ladle.app}
    validate_hostname "$LADLE_PUBLIC_HOSTNAME" ||
        die "LADLE_PUBLIC_HOSTNAME is invalid."
    if [ -e "$staging_key_file" ] || [ -L "$staging_key_file" ]; then
        read_staging_key "$staging_key_file" ||
            die "Existing staging access key is unsafe."
        tunnel_key=$STAGING_KEY_VALUE
    else
        tunnel_key=$(random_hex 32) || die "Cannot generate staging access key."
    fi
    database_password=$(random_hex 32) ||
        die "Cannot generate database password."
    jwt_signing_secret=$(random_hex 32) || die "Cannot generate JWT secret."
    data_encryption_key=$(random_hex 32) ||
        die "Cannot generate data encryption key."
    metrics_auth_token=$(random_hex 32) ||
        die "Cannot generate metrics token."
    object_storage_access_key=$(random_hex 16) ||
        die "Cannot generate object-storage access key."
    object_storage_secret_key=$(random_hex 32) ||
        die "Cannot generate object-storage secret key."

    env_tmp=$(mktemp /etc/ladle/.ladle.env.XXXXXX)
    {
        printf 'LADLE_PUBLIC_HOSTNAME=%s\n' "$LADLE_PUBLIC_HOSTNAME"
        printf 'LADLE_DATABASE_PASSWORD=%s\n' "$database_password"
        printf 'LADLE_DATABASE_PASSWORD_URL_ENCODED=%s\n' "$database_password"
        printf 'LADLE_WORKER_PROVIDER_MODE=fake\n'
        printf 'LADLE_JWT_SIGNING_SECRET=%s\n' "$jwt_signing_secret"
        printf 'LADLE_DATA_ENCRYPTION_KEY=%s\n' "$data_encryption_key"
        printf 'LADLE_METRICS_AUTH_TOKEN=%s\n' "$metrics_auth_token"
        printf 'LADLE_OBJECT_STORAGE_ACCESS_KEY=%s\n' \
            "$object_storage_access_key"
        printf 'LADLE_OBJECT_STORAGE_SECRET_KEY=%s\n' \
            "$object_storage_secret_key"
        printf 'LADLE_TUNNEL_ACCESS_KEY=%s\n' "$tunnel_key"
    } >"$env_tmp"
    chmod 0640 "$env_tmp"
    chown root:"$secret_group" "$env_tmp"
    validate_staging_environment "$env_tmp" ||
        die "Generated environment failed validation."
    mv -f -- "$env_tmp" "$env_file"
    env_tmp=
    existing_tunnel_key=$tunnel_key
fi

if [ -e "$staging_key_file" ] || [ -L "$staging_key_file" ]; then
    read_staging_key "$staging_key_file" ||
        die "Existing staging access key is unsafe."
    [ "$STAGING_KEY_VALUE" = "$existing_tunnel_key" ] ||
        die "Staging access key does not match the environment."
else
    staging_tmp=$(mktemp /etc/ladle/.staging-access-key.XXXXXX)
    printf '%s\n' "$existing_tunnel_key" >"$staging_tmp"
    chmod 0640 "$staging_tmp"
    chown root:"$secret_group" "$staging_tmp"
    mv -f -- "$staging_tmp" "$staging_key_file"
    staging_tmp=
fi

validate_env_metadata "$env_file" "$secret_group" ||
    die "Environment metadata validation failed."
validate_staging_environment "$env_file" ||
    die "Environment validation failed."
read_staging_key "$staging_key_file" ||
    die "Staging access key validation failed."
[ "$STAGING_KEY_VALUE" = "$existing_tunnel_key" ] ||
    die "Environment initialization is inconsistent."

progress "environment-ready" "private staging environment is ready"
