#!/bin/sh
set -eu

umask 077
script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
domain=gui/$(id -u)
agent_dir=$HOME/Library/LaunchAgents
support_dir=$HOME/Library/Application\ Support/Ladle
config_dir=$HOME/.config/ladle
backup_dir=$HOME/Backups/ladle
log_dir=$HOME/Library/Logs/Ladle
operations_script=$support_dir/local-operations.sh
config_file=$config_dir/local-operations.env

install -d -m 700 \
    "$agent_dir" \
    "$support_dir" \
    "$config_dir" \
    "$backup_dir" \
    "$log_dir"
install -m 700 "$script_dir/local-operations.sh" "$operations_script"
if [ ! -f "$config_file" ]; then
    install -m 600 /dev/null "$config_file"
else
    chmod 600 "$config_file"
fi

for label in com.ladle.health-watch com.ladle.database-backup; do
    destination=$agent_dir/$label.plist
    install -m 600 "$script_dir/$label.plist" "$destination"
    launchctl bootout "$domain/$label" 2>/dev/null || true
    launchctl bootstrap "$domain" "$destination"
    launchctl enable "$domain/$label"
    launchctl print "$domain/$label" >/dev/null
done

launchctl kickstart -k "$domain/com.ladle.health-watch"
printf 'Installed local Ladle health monitoring and nightly database backups.\n'
printf 'Configuration: %s\n' "$config_file"
printf 'Backups: %s\n' "$backup_dir"
printf 'Log: %s/local-operations.log\n' "$log_dir"
