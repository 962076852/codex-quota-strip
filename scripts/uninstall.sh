#!/bin/bash
set -euo pipefail
agent_label="io.github.codex-quota-strip"
agent_path="$HOME/Library/LaunchAgents/$agent_label.plist"
app_path="$HOME/Applications/Codex Quota Strip.app"
launchctl bootout "gui/$(id -u)/$agent_label" 2>/dev/null || true
# Remove only this project's installed application and startup configuration. Preserve preferences.
if [[ -f "$agent_path" ]]; then
    label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$agent_path")
    [[ "$label" == "$agent_label" ]] || { echo 'Unexpected startup label; stopped.'; exit 1; }
    rm "$agent_path"
fi
if [[ -d "$app_path" ]]; then
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
    [[ "$identifier" == "$agent_label" ]] || { echo 'Unexpected application identifier; stopped.'; exit 1; }
    rm -rf "$app_path"
fi
echo '已移除应用和登录启动项，保留窗口位置偏好。'
