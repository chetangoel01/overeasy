#!/bin/sh
set -eu

umask 077

state_dir=${LADLE_NGROK_STATE_DIR:-"$HOME/.config/ladle/ngrok"}
if [ -n "${LADLE_NGROK_BIN:-}" ]; then
    ngrok_bin=$LADLE_NGROK_BIN
elif ngrok_path=$(command -v ngrok 2>/dev/null); then
    ngrok_bin=$ngrok_path
else
    ngrok_bin=$HOME/bin/ngrok
fi
if [ -n "${LADLE_NGROK_CONFIG:-}" ]; then
    ngrok_config=$LADLE_NGROK_CONFIG
elif [ -f "$HOME/.config/ngrok/ngrok.yml" ]; then
    ngrok_config=$HOME/.config/ngrok/ngrok.yml
else
    ngrok_config="$HOME/Library/Application Support/ngrok/ngrok.yml"
fi
access_key_file=$state_dir/access-key
policy_file=$state_dir/policy.yml
pid_file=$state_dir/agent.pid
log_file=${LADLE_NGROK_LOG:-"$HOME/Library/Logs/Ladle/ngrok.log"}
agent_api=${LADLE_NGROK_AGENT_API:-http://127.0.0.1:4040}
launchd_label=${LADLE_NGROK_LAUNCHD_LABEL:-com.ladle.device-tunnel}
launchd_service=gui/$(id -u)/$launchd_label

agent_pid() {
    if command -v launchctl >/dev/null 2>&1; then
        launchd_pid=$(launchctl print "$launchd_service" 2>/dev/null |
            sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' |
            head -n 1)
        case $launchd_pid in
            "" | *[!0-9]*) return 1 ;;
        esac
        kill -0 "$launchd_pid" 2>/dev/null || return 1
        printf '%s\n' "$launchd_pid"
        return
    fi
    [ -f "$pid_file" ] || return 1
    pid=$(sed -n '1p' "$pid_file")
    case $pid in
        "" | *[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s\n' "$pid"
}

public_url() {
    curl --fail --silent "$agent_api/api/tunnels" |
        sed -n 's/.*"public_url":"\(https:[^"]*\)".*/\1/p' |
        head -n 1
}

generate_access_key() {
    mkdir -p "$state_dir"
    key_tmp=$(mktemp "$state_dir/access-key.XXXXXX")
    openssl rand -hex 32 >"$key_tmp"
    chmod 600 "$key_tmp"
    mv "$key_tmp" "$access_key_file"
}

write_policy() {
    if [ ! -s "$access_key_file" ]; then
        generate_access_key
    fi
    chmod 600 "$access_key_file"
    access_key=$(sed -n '1p' "$access_key_file")
    {
        printf '%s\n' \
            "on_http_request:" \
            "  - name: Hide internal routes" \
            "    expressions:" \
            "      - \"req.url.path == '/openapi.json' || req.url.path == '/docs' || req.url.path == '/redoc' || req.url.path == '/metrics'\"" \
            "    actions:" \
            "      - type: custom-response" \
            "        config:" \
            "          status_code: 404" \
            "          body: '{\"detail\":\"Not Found\"}'" \
            "          headers:" \
            "            content-type: application/json" \
            "  - name: Require X-Ladle-Tunnel-Key" \
            "    expressions:" \
            "      - \"!req.url.path.startsWith('/ladle-private/')\"" \
            "      - \"!('x-ladle-tunnel-key' in req.headers)\"" \
            "    actions:" \
            "      - type: custom-response" \
            "        config:" \
            "          status_code: 404" \
            "          body: '{\"detail\":\"Not Found\"}'" \
            "          headers:" \
            "            content-type: application/json" \
            "  - name: Reject an incorrect X-Ladle-Tunnel-Key" \
            "    expressions:" \
            "      - \"!req.url.path.startsWith('/ladle-private/')\"" \
            "      - \"'x-ladle-tunnel-key' in req.headers\"" \
            "      - \"!('$access_key' in req.headers['x-ladle-tunnel-key'])\"" \
            "    actions:" \
            "      - type: custom-response" \
            "        config:" \
            "          status_code: 404" \
            "          body: '{\"detail\":\"Not Found\"}'" \
            "          headers:" \
            "            content-type: application/json"
    } >"$policy_file"
    chmod 600 "$policy_file"
}

start() {
    if agent_pid >/dev/null; then
        public_url
        return
    fi
    [ -x "$ngrok_bin" ] || {
        echo "ngrok is not installed at $ngrok_bin" >&2
        exit 1
    }
    [ -f "$ngrok_config" ] || {
        echo "ngrok is not configured at $ngrok_config" >&2
        exit 1
    }
    mkdir -p "$state_dir" "$(dirname "$log_file")"
    write_policy
    if command -v launchctl >/dev/null 2>&1; then
        launchctl remove "$launchd_label" >/dev/null 2>&1 || true
        launchctl submit -l "$launchd_label" -o "$log_file" -e "$log_file" -- \
            "$ngrok_bin" http http://127.0.0.1:4114 \
            --config "$ngrok_config" \
            --traffic-policy-file "$policy_file" \
            --log stdout
    else
        nohup "$ngrok_bin" http http://127.0.0.1:4114 \
            --config "$ngrok_config" \
            --traffic-policy-file "$policy_file" \
            --log stdout \
            >"$log_file" 2>&1 </dev/null &
        printf '%s\n' "$!" >"$pid_file"
    fi

    attempts=0
    while [ "$attempts" -lt 30 ]; do
        if url=$(public_url 2>/dev/null) && [ -n "$url" ]; then
            printf '%s\n' "$url"
            return
        fi
        agent_pid >/dev/null || break
        attempts=$((attempts + 1))
        sleep 1
    done
    echo "ngrok did not start; see $log_file" >&2
    exit 1
}

stop() {
    if command -v launchctl >/dev/null 2>&1; then
        launchctl remove "$launchd_label" >/dev/null 2>&1 || true
    elif pid=$(agent_pid); then
        kill "$pid"
    fi
    rm -f "$pid_file"
}

rotate_key() {
    stop
    generate_access_key
    start
}

case ${1:-status} in
    start) start ;;
    stop) stop ;;
    rotate-key) rotate_key ;;
    status)
        if agent_pid >/dev/null; then
            public_url
        else
            echo "stopped"
        fi
        ;;
    key-file) printf '%s\n' "$access_key_file" ;;
    *)
        echo "usage: $0 {start|stop|rotate-key|status|key-file}" >&2
        exit 64
        ;;
esac
