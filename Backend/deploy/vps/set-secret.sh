#!/bin/sh
set -eu
umask 077

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "Run set-secret.sh as root." >&2
    exit 1
fi
if [ "$#" -ne 1 ]; then
    printf '%s\n' "Usage: set-secret.sh ALLOWLISTED_KEY < value-file" >&2
    exit 1
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
deployment_library=$script_directory/deployment-lib.sh
if [ ! -f "$deployment_library" ] || [ -L "$deployment_library" ]; then
    printf '%s\n' "Missing deployment library." >&2
    exit 1
fi
. "$deployment_library"

secret_name=$1
case "$secret_name" in
    LADLE_OPENROUTER_API_KEY | LADLE_SUPADATA_API_KEY | LADLE_SOSCRIPTED_API_KEY)
        ;;
    *)
        die "That environment key is not an allowlisted provider credential."
        exit 1
        ;;
esac

read_dotenv_stdin_value || {
    die "The provider credential contains unsafe dotenv characters."
    exit 1
}
secret_value=$DOTENV_STDIN_VALUE

secret_group=ladle-secrets
env_file=/etc/ladle/ladle.env
environment_lock=/var/lock/ladle-environment.lock
env_tmp=
secret_phase=secret-update

cleanup() {
    status=$?
    if [ -n "$env_tmp" ]; then
        rm -f -- "$env_tmp"
    fi
    if [ "$status" -ne 0 ] && [ -f "$progress_log" ]; then
        progress failure "$secret_phase failed" || true
    fi
    trap - 0
    exit "$status"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

acquire_environment_lock "$environment_lock" 0 ||
    die "Cannot acquire the staging environment lock."
validate_env_metadata "$env_file" "$secret_group" ||
    die "The staging environment metadata is unsafe."
validate_staging_environment "$env_file" ||
    die "The staging environment is invalid."
progress_init "$secret_group"
progress "secret-update" "installing $secret_name"

env_tmp=$(mktemp /etc/ladle/.ladle.env.XXXXXX)
write_provider_secret_candidate \
    "$env_file" "$env_tmp" "$secret_name" "$secret_value" ||
    die "Updated staging environment failed validation."
chmod 0640 "$env_tmp"
chown root:"$secret_group" "$env_tmp"
validate_staging_environment "$env_tmp" ||
    die "Updated staging environment failed validation."
mv -f -- "$env_tmp" "$env_file"
env_tmp=
validate_env_metadata "$env_file" "$secret_group" ||
    die "Updated staging environment metadata is unsafe."
validate_staging_environment "$env_file" ||
    die "Updated staging environment failed final validation."

progress "secret-ready" "$secret_name is installed"
