#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
label=com.ladle.docker-start
domain=gui/$(id -u)
agent_dir=$HOME/Library/LaunchAgents
destination=$agent_dir/$label.plist

install -d -m 700 "$agent_dir"
install -m 600 "$script_dir/$label.plist" "$destination"

launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$destination"
launchctl enable "$domain/$label"

launchctl print "$domain/$label" >/dev/null
printf 'Installed %s for Docker Desktop login startup.\n' "$destination"
