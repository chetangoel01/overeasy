#!/bin/sh
set -eu

worker_uid=${WORKER_UID:-10001}
postgres_host=${POSTGRES_HOST:-postgres}
redis_host=${REDIS_HOST:-redis}
minio_host=${MINIO_HOST:-minio}

resolve_ipv4() {
    getent hosts "$1" | awk 'NR == 1 { print $1 }'
}

postgres_ip=$(resolve_ipv4 "$postgres_host")
redis_ip=$(resolve_ipv4 "$redis_host")
minio_ip=$(resolve_ipv4 "$minio_host")
resolver_ip=$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf)

if [ -z "$postgres_ip" ] || [ -z "$redis_ip" ] || [ -z "$minio_ip" ] ||
    [ -z "$resolver_ip" ]; then
    echo "Could not resolve a required egress dependency." >&2
    exit 1
fi

iptables -N LADLE_WORKER_EGRESS
iptables -A OUTPUT -m owner --uid-owner "$worker_uid" -j LADLE_WORKER_EGRESS
iptables -A LADLE_WORKER_EGRESS \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Docker DNATs 127.0.0.11:53 to an ephemeral local resolver port before the
# filter table. Permit only that special resolver address before loopback is
# rejected; no application service listens there.
iptables -A LADLE_WORKER_EGRESS -d "$resolver_ip" -j ACCEPT
iptables -A LADLE_WORKER_EGRESS \
    -d "$postgres_ip" -p tcp --dport 5432 -j ACCEPT
iptables -A LADLE_WORKER_EGRESS \
    -d "$redis_ip" -p tcp --dport 6379 -j ACCEPT
iptables -A LADLE_WORKER_EGRESS \
    -d "$minio_ip" -p tcp --dport 9000 -j ACCEPT

for network in \
    0.0.0.0/8 \
    10.0.0.0/8 \
    100.64.0.0/10 \
    127.0.0.0/8 \
    169.254.0.0/16 \
    172.16.0.0/12 \
    192.0.0.0/24 \
    192.0.2.0/24 \
    192.168.0.0/16 \
    198.18.0.0/15 \
    198.51.100.0/24 \
    203.0.113.0/24 \
    224.0.0.0/4 \
    240.0.0.0/4
do
    iptables -A LADLE_WORKER_EGRESS -d "$network" -j REJECT
done

iptables -A LADLE_WORKER_EGRESS -p tcp --dport 443 -j ACCEPT
iptables -A LADLE_WORKER_EGRESS -j REJECT

ip6tables -N LADLE_WORKER_EGRESS_V6
ip6tables -A OUTPUT -m owner --uid-owner "$worker_uid" \
    -j LADLE_WORKER_EGRESS_V6
ip6tables -A LADLE_WORKER_EGRESS_V6 \
    -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A LADLE_WORKER_EGRESS_V6 -j REJECT

touch /tmp/egress-ready
exec tail -f /dev/null
