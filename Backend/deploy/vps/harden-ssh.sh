#!/bin/sh
set -eu
umask 077

marker_content=LADLE_SSH_KEY_LOGIN_VERIFIED_V1
dropin=/etc/ssh/sshd_config.d/00-ladle-hardening.conf

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

print_gate_instructions() {
    cat >&2 <<EOF
SSH lockout prevention:
1. Keep session A open throughout this operation.
2. From a separate session B, prove public-key login for the target user.
3. In session B, create the marker as root with mode 0600 and exact content:
   printf '%s\\n' '$marker_content' | sudo tee ABSOLUTE_MARKER_PATH >/dev/null
   sudo chmod 0600 ABSOLUTE_MARKER_PATH
4. Back in session A, run: sudo $0 ABSOLUTE_MARKER_PATH
The marker is an operator assertion; this script cannot infer session B's
authentication method.
EOF
}

if [ "$(id -u)" -ne 0 ]; then
    die "Run harden-ssh.sh as root."
fi
if [ "$#" -ne 1 ]; then
    print_gate_instructions
    die "Usage: sudo $0 /absolute/path/to/key-login-marker"
fi

marker_path=$1
print_gate_instructions
case "$marker_path" in
    /*) ;;
    *) die "The verification marker path must be absolute." ;;
esac
if [ ! -f "$marker_path" ] || [ -L "$marker_path" ]; then
    die "The verification marker must be a regular, non-symlink file."
fi
marker_canonical=$(readlink -f -- "$marker_path") ||
    die "Cannot resolve the verification marker."
if [ "$marker_canonical" != "$marker_path" ]; then
    die "The verification marker path must be canonical and contain no symlinks."
fi
marker_metadata=$(stat -c "%u:%a" -- "$marker_path") ||
    die "Cannot inspect the verification marker."
if [ "$marker_metadata" != "0:600" ]; then
    die "The verification marker must be owned by root with mode 0600."
fi

marker_expected=$(mktemp /run/ladle-ssh-marker-expected.XXXXXX)
dropin_candidate=
dropin_previous=
configuration_pending=false

cleanup() {
    if [ "$configuration_pending" = true ]; then
        restore_previous_dropin
    fi
    rm -f -- "$marker_expected"
    if [ -n "$dropin_candidate" ]; then
        rm -f -- "$dropin_candidate"
    fi
    if [ -n "$dropin_previous" ]; then
        rm -f -- "$dropin_previous"
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

printf '%s\n' "$marker_content" >"$marker_expected"
if ! cmp -s -- "$marker_expected" "$marker_path"; then
    die "The verification marker content is invalid."
fi
marker_parent=$(dirname -- "$marker_path")
marker_parent_metadata=$(stat -c "%u:%a" -- "$marker_parent") ||
    die "Cannot inspect the verification marker directory."
case "$marker_parent_metadata" in
    "0:700" | "0:711" | "0:750" | "0:755") ;;
    *) die "The verification marker directory permissions are unsafe." ;;
esac

target_user=${LADLE_SSH_USER:-${SUDO_USER:-ubuntu}}
case "$target_user" in
    "" | *[!A-Za-z0-9_.-]*) die "The SSH target user name is unsafe." ;;
esac
target_uid=$(id -u "$target_user" 2>/dev/null) ||
    die "SSH target user does not exist: $target_user"
if [ "$target_uid" -eq 0 ]; then
    die "SSH hardening requires a non-root target user."
fi
target_home=$(getent passwd "$target_user" | awk -F: 'NR == 1 { print $6 }')
case "$target_home" in
    /*) ;;
    *) die "The SSH target user has no safe absolute home directory." ;;
esac

ssh_directory=$target_home/.ssh
authorized_keys=$ssh_directory/authorized_keys
if [ ! -d "$ssh_directory" ] || [ -L "$ssh_directory" ]; then
    die "The target user's .ssh directory must be a real directory."
fi
ssh_directory_metadata=$(stat -c "%u:%a" -- "$ssh_directory") ||
    die "Cannot inspect the target user's .ssh directory."
case "$ssh_directory_metadata" in
    "$target_uid:500" | "$target_uid:700") ;;
    *) die "The .ssh directory must be target-owned with mode 0500 or 0700." ;;
esac
if [ ! -f "$authorized_keys" ] || [ -L "$authorized_keys" ]; then
    die "Install a regular authorized_keys file before hardening SSH."
fi
authorized_metadata=$(stat -c "%u:%a" -- "$authorized_keys") ||
    die "Cannot inspect authorized_keys."
case "$authorized_metadata" in
    "$target_uid:400" | "$target_uid:600") ;;
    *) die "authorized_keys must be target-owned with mode 0400 or 0600." ;;
esac
if ! awk '
    /^[[:space:]]*#/ { next }
    {
        for (field = 1; field < NF; field++) {
            if (
                $field ~ /^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh.com)$/ &&
                $(field + 1) ~ /^[A-Za-z0-9+\/]+={0,3}$/
            ) {
                found = 1
            }
        }
    }
    END { exit !found }
' "$authorized_keys"; then
    die "authorized_keys contains no supported installed public key."
fi

install -d -o root -g root -m 0755 /etc/ssh/sshd_config.d
dropin_candidate=$(mktemp /etc/ssh/sshd_config.d/.ladle-hardening.XXXXXX)
cat >"$dropin_candidate" <<'LADLE_SSH_HARDENING'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
LADLE_SSH_HARDENING
chmod 0644 "$dropin_candidate"
chown root:root "$dropin_candidate"

had_previous=false
if [ -L "$dropin" ]; then
    die "Refusing to replace a symlink SSH hardening drop-in."
fi
if [ -e "$dropin" ]; then
    if [ ! -f "$dropin" ] || [ -L "$dropin" ]; then
        die "Refusing to replace a non-regular SSH hardening drop-in."
    fi
    dropin_previous=$(mktemp /etc/ssh/sshd_config.d/.ladle-previous.XXXXXX)
    cp -p -- "$dropin" "$dropin_previous"
    had_previous=true
fi

restore_previous_dropin() {
    if [ "$had_previous" = true ]; then
        mv -f -- "$dropin_previous" "$dropin"
        dropin_previous=
    else
        rm -f -- "$dropin"
    fi
    configuration_pending=false
}

configuration_pending=true
mv -f -- "$dropin_candidate" "$dropin"
dropin_candidate=

if ! /usr/sbin/sshd -t; then
    restore_previous_dropin
    die "SSH configuration validation failed; the previous drop-in was restored."
fi

validate_effective_configuration() {
    connection_user=$1
    connection_context="user=$connection_user,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22"
    effective_configuration=$(
        /usr/sbin/sshd -T -C "$connection_context"
    ) || return 1
    for required_setting in \
        "permitrootlogin no" \
        "passwordauthentication no" \
        "kbdinteractiveauthentication no" \
        "pubkeyauthentication yes"; do
        printf '%s\n' "$effective_configuration" |
            grep -Fx -- "$required_setting" >/dev/null || return 1
    done
}

if ! validate_effective_configuration "$target_user" ||
    ! validate_effective_configuration root; then
    restore_previous_dropin
    die "SSH hardening is not effective; the previous drop-in was restored."
fi

if ! systemctl reload ssh; then
    restore_previous_dropin
    /usr/sbin/sshd -t ||
        die "SSH reload failed and the restored configuration is invalid."
    systemctl reload ssh ||
        die "SSH reload failed after restoring the previous configuration."
    die "SSH reload failed; the previous configuration was restored."
fi

configuration_pending=false
printf '%s\n' \
    "SSH hardening is active. Keep session A open until one more key login succeeds."
