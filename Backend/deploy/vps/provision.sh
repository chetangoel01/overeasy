#!/bin/sh
set -eu
umask 077

die() {
    printf '%s\n' "$*" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    die "Run provision.sh as root."
fi

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
host_validation_source=$script_directory/host-validation.sh
if [ ! -f "$host_validation_source" ] || [ -L "$host_validation_source" ]; then
    die "Missing regular host validation library: $host_validation_source"
fi
. "$host_validation_source"

if [ ! -r /etc/os-release ]; then
    die "Cannot verify the operating system: /etc/os-release is unavailable."
fi

# Ubuntu owns this root-controlled file; fail closed if its identity changes.
. /etc/os-release
if [ "${ID:-}" != "ubuntu" ] || [ "${VERSION_ID:-}" != "26.04" ]; then
    die "This provisioner supports only Ubuntu 26.04."
fi
if [ -z "${VERSION_CODENAME:-}" ]; then
    die "Ubuntu VERSION_CODENAME is required for the Docker repository."
fi
case "$VERSION_CODENAME" in
    *[!A-Za-z0-9_-]*) die "Unsafe Ubuntu VERSION_CODENAME." ;;
esac

deploy_user=${LADLE_DEPLOY_USER:-${SUDO_USER:-ubuntu}}
deploy_uid=$(id -u "$deploy_user" 2>/dev/null) ||
    die "Deployment user does not exist: $deploy_user"
if [ "$deploy_uid" -eq 0 ]; then
    die "The deployment user must not be root."
fi
deploy_group=$(id -gn "$deploy_user")

docker_key_asc=
docker_key_gpg=
docker_key_metadata=
docker_source_tmp=
ipv4_rules_tmp=
ipv6_rules_tmp=
docker_firewall_tmp=
docker_firewall_service_tmp=
docker_service_dropin_tmp=

cleanup() {
    for temporary_path in \
        "$docker_key_asc" \
        "$docker_key_gpg" \
        "$docker_key_metadata" \
        "$docker_source_tmp" \
        "$ipv4_rules_tmp" \
        "$ipv6_rules_tmp" \
        "$docker_firewall_tmp" \
        "$docker_firewall_service_tmp" \
        "$docker_service_dropin_tmp"; do
        if [ -n "$temporary_path" ]; then
            rm -f -- "$temporary_path"
        fi
    done
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    iproute2 \
    iptables \
    iptables-persistent

install -d -o root -g root -m 0755 /etc/apt/keyrings
docker_key_asc=$(mktemp /tmp/ladle-docker-key.XXXXXX)
docker_key_gpg=$(mktemp /etc/apt/keyrings/.docker.gpg.XXXXXX)
docker_key_metadata=$(mktemp /tmp/ladle-docker-key-metadata.XXXXXX)
curl --proto '=https' --tlsv1.2 -fsSL \
    https://download.docker.com/linux/ubuntu/gpg \
    -o "$docker_key_asc"
docker_expected_fingerprint=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
gpg --batch --with-colons --show-keys \
    "$docker_key_asc" >"$docker_key_metadata"
if ! docker_key_metadata_is_trusted \
    "$docker_key_metadata" "$docker_expected_fingerprint"; then
    die "The Docker repository signing key fingerprint is unexpected."
fi
gpg --batch --yes --dearmor --output "$docker_key_gpg" "$docker_key_asc"
chmod 0644 "$docker_key_gpg"
chown root:root "$docker_key_gpg"
gpg --batch --with-colons --show-keys \
    "$docker_key_gpg" >"$docker_key_metadata"
if ! docker_key_metadata_is_trusted \
    "$docker_key_metadata" "$docker_expected_fingerprint"; then
    die "The dearmored Docker signing key is unexpected."
fi
mv -f -- "$docker_key_gpg" /etc/apt/keyrings/docker.gpg
docker_key_gpg=

docker_architecture=$(dpkg --print-architecture)
case "$docker_architecture" in
    "" | *[!A-Za-z0-9_-]*) die "Unsafe Debian architecture." ;;
esac
docker_source_tmp=$(mktemp /etc/apt/sources.list.d/.docker.sources.XXXXXX)
cat >"$docker_source_tmp" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $VERSION_CODENAME
Components: stable
Architectures: $docker_architecture
Signed-By: /etc/apt/keyrings/docker.gpg
EOF
chmod 0644 "$docker_source_tmp"
chown root:root "$docker_source_tmp"
mv -f -- "$docker_source_tmp" /etc/apt/sources.list.d/docker.sources
docker_source_tmp=

apt-get update
apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

install -d -o root -g root -m 0755 /opt/ladle
install -d -o "$deploy_user" -g "$deploy_group" -m 0750 /opt/ladle/releases
install -d -o root -g root -m 0700 /etc/ladle
install -d -o root -g root -m 0700 /var/backups/ladle
install -d -o root -g root -m 0750 /var/lib/ladle
install -d -o root -g root -m 0700 /etc/iptables

ipv4_public_interface=$(
    /usr/sbin/ip -4 route show default | public_interface_from_routes
) || die "Cannot detect one trustworthy IPv4 public interface."
ipv6_public_interface=$(
    /usr/sbin/ip -6 route show default | public_interface_from_routes
) || die "Cannot detect one trustworthy IPv6 public interface."
public_interface_is_safe "$ipv4_public_interface" ||
    die "The IPv4 public interface name is unsafe."
public_interface_is_safe "$ipv6_public_interface" ||
    die "The IPv6 public interface name is unsafe."

ipv4_rules_tmp=$(mktemp /etc/iptables/.rules.v4.XXXXXX)
cat >"$ipv4_rules_tmp" <<LADLE_IPV4_RULES
*filter
:INPUT DROP [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:DOCKER-USER - [0:0]
:LADLE_DOCKER_PUBLIC_A - [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -p tcp -m multiport --dports 22,80,443 -m conntrack --ctstate NEW -j ACCEPT
-A INPUT -p udp --dport 443 -m conntrack --ctstate NEW -j ACCEPT
-A FORWARD -j DOCKER-USER
-A DOCKER-USER -j LADLE_DOCKER_PUBLIC_A
-A DOCKER-USER -j RETURN
-A LADLE_DOCKER_PUBLIC_A -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A LADLE_DOCKER_PUBLIC_A -i $ipv4_public_interface -p tcp -m conntrack --ctstate NEW --ctorigdstport 80 -j ACCEPT
-A LADLE_DOCKER_PUBLIC_A -i $ipv4_public_interface -p tcp -m conntrack --ctstate NEW --ctorigdstport 443 -j ACCEPT
-A LADLE_DOCKER_PUBLIC_A -i $ipv4_public_interface -p udp -m conntrack --ctstate NEW --ctorigdstport 443 -j ACCEPT
-A LADLE_DOCKER_PUBLIC_A -i $ipv4_public_interface -m conntrack --ctstate NEW -j REJECT
-A LADLE_DOCKER_PUBLIC_A -j RETURN
COMMIT
LADLE_IPV4_RULES
chmod 0600 "$ipv4_rules_tmp"
chown root:root "$ipv4_rules_tmp"
/usr/sbin/iptables-restore --test <"$ipv4_rules_tmp"
mv -f -- "$ipv4_rules_tmp" /etc/iptables/rules.v4
ipv4_rules_tmp=

ipv6_rules_tmp=$(mktemp /etc/iptables/.rules.v6.XXXXXX)
cat >"$ipv6_rules_tmp" <<LADLE_IPV6_RULES
*filter
:INPUT DROP [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:DOCKER-USER - [0:0]
:LADLE_DOCKER_PUBLIC_A - [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p ipv6-icmp -j ACCEPT
-A INPUT -p tcp -m multiport --dports 22,80,443 -m conntrack --ctstate NEW -j ACCEPT
-A INPUT -p udp --dport 443 -m conntrack --ctstate NEW -j ACCEPT
-A FORWARD -j DOCKER-USER
-A DOCKER-USER -j LADLE_DOCKER_PUBLIC_A
-A DOCKER-USER -j RETURN
-A LADLE_DOCKER_PUBLIC_A -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A LADLE_DOCKER_PUBLIC_A -i $ipv6_public_interface -p tcp -m conntrack --ctstate NEW --ctorigdstport 80 -j ACCEPT
-A LADLE_DOCKER_PUBLIC_A -i $ipv6_public_interface -p tcp -m conntrack --ctstate NEW --ctorigdstport 443 -j ACCEPT
-A LADLE_DOCKER_PUBLIC_A -i $ipv6_public_interface -p udp -m conntrack --ctstate NEW --ctorigdstport 443 -j ACCEPT
-A LADLE_DOCKER_PUBLIC_A -i $ipv6_public_interface -m conntrack --ctstate NEW -j REJECT
-A LADLE_DOCKER_PUBLIC_A -j RETURN
COMMIT
LADLE_IPV6_RULES
chmod 0600 "$ipv6_rules_tmp"
chown root:root "$ipv6_rules_tmp"
/usr/sbin/ip6tables-restore --test <"$ipv6_rules_tmp"
mv -f -- "$ipv6_rules_tmp" /etc/iptables/rules.v6
ipv6_rules_tmp=

apply_host_firewall() {
    firewall_command=$1
    icmp_protocol=$2

    if "$firewall_command" -C INPUT \
        -j LADLE_HOST_INPUT_A >/dev/null 2>&1; then
        active_chain=LADLE_HOST_INPUT_A
        next_chain=LADLE_HOST_INPUT_B
    else
        active_chain=LADLE_HOST_INPUT_B
        next_chain=LADLE_HOST_INPUT_A
    fi
    while "$firewall_command" -C INPUT \
        -j "$next_chain" >/dev/null 2>&1; do
        "$firewall_command" -D INPUT -j "$next_chain"
    done
    if ! "$firewall_command" -nL "$next_chain" >/dev/null 2>&1; then
        "$firewall_command" -N "$next_chain"
    fi
    "$firewall_command" -F "$next_chain"
    "$firewall_command" -A "$next_chain" -i lo -j ACCEPT
    "$firewall_command" -A "$next_chain" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    "$firewall_command" -A "$next_chain" -p "$icmp_protocol" -j ACCEPT
    "$firewall_command" -A "$next_chain" -p tcp \
        -m multiport --dports 22,80,443 \
        -m conntrack --ctstate NEW -j ACCEPT
    "$firewall_command" -A "$next_chain" -p udp --dport 443 \
        -m conntrack --ctstate NEW -j ACCEPT
    "$firewall_command" -A "$next_chain" -j DROP
    "$firewall_command" -I INPUT 1 -j "$next_chain"
    while "$firewall_command" -C INPUT \
        -j "$active_chain" >/dev/null 2>&1; do
        "$firewall_command" -D INPUT -j "$active_chain"
    done
    "$firewall_command" -P INPUT DROP
    "$firewall_command" -P OUTPUT ACCEPT
}

# Populate the owned live chains without restoring/flushing Docker's filter table.
apply_host_firewall /usr/sbin/iptables icmp
apply_host_firewall /usr/sbin/ip6tables ipv6-icmp

docker_firewall_source=$script_directory/ladle-docker-user.rules
if [ ! -f "$docker_firewall_source" ] || [ -L "$docker_firewall_source" ]; then
    die "Missing regular Docker firewall source: $docker_firewall_source"
fi

install -d -o root -g root -m 0755 /usr/local/sbin
docker_firewall_tmp=$(mktemp /usr/local/sbin/.ladle-docker-user-firewall.XXXXXX)
render_docker_firewall \
    "$docker_firewall_source" \
    "$ipv4_public_interface" \
    "$ipv6_public_interface" >"$docker_firewall_tmp"
sh -n "$docker_firewall_tmp"
chmod 0755 "$docker_firewall_tmp"
chown root:root "$docker_firewall_tmp"
mv -f -- "$docker_firewall_tmp" /usr/local/sbin/ladle-docker-user-firewall
docker_firewall_tmp=

docker_firewall_service_tmp=$(
    mktemp /etc/systemd/system/.ladle-docker-user-firewall.service.XXXXXX
)
cat >"$docker_firewall_service_tmp" <<'LADLE_DOCKER_FIREWALL_SERVICE'
[Unit]
Description=Ladle Docker public-ingress firewall
Requires=docker.service
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ladle-docker-user-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
LADLE_DOCKER_FIREWALL_SERVICE
chmod 0644 "$docker_firewall_service_tmp"
chown root:root "$docker_firewall_service_tmp"
mv -f -- "$docker_firewall_service_tmp" \
    /etc/systemd/system/ladle-docker-user-firewall.service
docker_firewall_service_tmp=

install -d -o root -g root -m 0755 /etc/systemd/system/docker.service.d
docker_service_dropin_tmp=$(
    mktemp /etc/systemd/system/docker.service.d/.10-ladle-firewall.conf.XXXXXX
)
cat >"$docker_service_dropin_tmp" <<'LADLE_DOCKER_SERVICE_ORDERING'
[Unit]
Requires=netfilter-persistent.service
After=netfilter-persistent.service

[Service]
ExecStartPost=/usr/local/sbin/ladle-docker-user-firewall
LADLE_DOCKER_SERVICE_ORDERING
chmod 0644 "$docker_service_dropin_tmp"
chown root:root "$docker_service_dropin_tmp"
mv -f -- "$docker_service_dropin_tmp" \
    /etc/systemd/system/docker.service.d/10-ladle-firewall.conf
docker_service_dropin_tmp=

systemctl enable netfilter-persistent.service
systemctl daemon-reload
systemctl enable --now docker.service
systemctl enable ladle-docker-user-firewall.service
systemctl restart ladle-docker-user-firewall.service

printf '%s\n' "Ubuntu host provisioning is complete for $deploy_user."
