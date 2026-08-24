#!/bin/sh
set -eu

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
backend_dir=$(dirname "$script_dir")
repository_dir=$(dirname "$backend_dir")
ngrok_launcher=$backend_dir/deploy/mac-mini/ngrok.sh
build_config=$repository_dir/.private/DeviceTunnel.xcconfig

compose() {
    (cd "$backend_dir" && docker compose "$@")
}

start_edge() {
    compose --profile device-tunnel up -d --no-deps device-edge
}

wait_for_backend() {
    attempts=0
    while [ "$attempts" -lt 45 ]; do
        if curl --fail --silent --max-time 3 \
            http://127.0.0.1:4112/health/ready >/dev/null 2>&1; then
            return
        fi
        attempts=$((attempts + 1))
        sleep 1
    done
    echo "local backend did not become ready" >&2
    exit 1
}

configure_public_storage_url() {
    public_url=$1
    (
        cd "$backend_dir"
        LADLE_OBJECT_STORAGE_PUBLIC_ENDPOINT_URL=$public_url \
            docker compose up -d --force-recreate --no-deps api worker beat
    )
    wait_for_backend
    # Nginx resolves Compose service names when it starts. Refresh the edge
    # after recreating the API so it does not retain the previous container IP.
    compose --profile device-tunnel up -d --force-recreate --no-deps device-edge
}

write_build_config() {
    public_url=$1
    case $public_url in
        https://*) public_host=${public_url#https://} ;;
        *)
            echo "ngrok did not provide an HTTPS URL" >&2
            exit 1
            ;;
    esac
    key_file=$($ngrok_launcher key-file)
    IFS= read -r access_key <"$key_file"
    case $access_key in
        "" | *[!0-9a-f]*)
            echo "invalid tunnel access key" >&2
            exit 1
            ;;
    esac
    mkdir -p "$(dirname "$build_config")"
    config_tmp=$(mktemp "$build_config.XXXXXX")
    {
        printf 'LADLE_API_BASE_URL = https:/$()/%s\n' "$public_host"
        printf '%s\n' 'LADLE_APP_ATTEST_ENABLED = NO'
        printf 'LADLE_TUNNEL_ACCESS_KEY = %s\n' "$access_key"
    } >"$config_tmp"
    chmod 600 "$config_tmp"
    mv "$config_tmp" "$build_config"
}

request_status() {
    public_url=$1
    shift
    curl --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 15 "$@" "$public_url"
}

verify_guard() {
    public_url=$1
    key_file=$($ngrok_launcher key-file)
    IFS= read -r access_key <"$key_file"
    skip_header='ngrok-skip-browser-warning: 1'
    missing=$(request_status "$public_url/health/ready" -H "$skip_header")
    wrong=$(request_status "$public_url/health/ready" \
        -H "$skip_header" -H 'X-Ladle-Tunnel-Key: wrong-device-key')
    allowed=$(request_status "$public_url/health/ready" \
        -H "$skip_header" -H "X-Ladle-Tunnel-Key: $access_key")
    metrics=$(request_status "$public_url/metrics" \
        -H "$skip_header" -H "X-Ladle-Tunnel-Key: $access_key")
    if [ "$missing" != 404 ] || [ "$wrong" != 404 ] || \
        [ "$allowed" != 200 ] || [ "$metrics" != 404 ]; then
        echo "tunnel guard verification failed: missing=$missing wrong=$wrong allowed=$allowed metrics=$metrics" >&2
        exit 1
    fi
}

prepare() {
    mode=$1
    start_edge
    if [ "$mode" = rotate ]; then
        public_url=$($ngrok_launcher rotate-key)
    else
        public_url=$($ngrok_launcher start)
    fi
    configure_public_storage_url "$public_url"
    write_build_config "$public_url"
    verify_guard "$public_url"
    printf 'Tunnel: %s\n' "$public_url"
    printf 'Build config: %s\n' "$build_config"
    printf '%s\n' 'Guard: missing key 404; wrong key 404; authorized ready 200; metrics 404'
}

stop() {
    $ngrok_launcher stop
    compose stop device-edge >/dev/null 2>&1 || true
    compose up -d --force-recreate --no-deps api worker beat
    wait_for_backend
    printf '%s\n' 'Guarded device tunnel stopped; local simulator routing restored.'
}

case ${1:-status} in
    start) prepare reuse ;;
    rotate) prepare rotate ;;
    stop) stop ;;
    status) $ngrok_launcher status ;;
    xcconfig) printf '%s\n' "$build_config" ;;
    *)
        echo "usage: $0 {start|rotate|stop|status|xcconfig}" >&2
        exit 64
        ;;
esac
