#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_source="$project_dir/dist/Codex Quota Strip.app"
app_destination="$HOME/Applications/Codex Quota Strip.app"
agent_label="io.github.codex-quota-strip"
agent_path="$HOME/Library/LaunchAgents/$agent_label.plist"
if [[ ! -x "$app_source/Contents/MacOS/CodexQuotaStrip" ]]; then
    "$project_dir/scripts/build.sh"
fi
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/$agent_label" 2>/dev/null || true
ditto "$app_source" "$app_destination"
# PlistBuddy handles paths with spaces and XML-special characters without shell interpolation into XML.
/usr/libexec/PlistBuddy -c 'Clear dict' "$agent_path" >/dev/null
/usr/libexec/PlistBuddy -c "Add :Label string $agent_label" "$agent_path"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$agent_path"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $app_destination/Contents/MacOS/CodexQuotaStrip" "$agent_path"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$agent_path"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType string Aqua' "$agent_path"
/usr/libexec/PlistBuddy -c 'Add :ProcessType string Background' "$agent_path"
/usr/libexec/PlistBuddy -c 'Add :StandardOutPath string /dev/null' "$agent_path"
/usr/libexec/PlistBuddy -c 'Add :StandardErrorPath string /dev/null' "$agent_path"
plutil -lint "$agent_path"
launchctl bootstrap "gui/$(id -u)" "$agent_path"
echo "Installed: $app_destination"
echo 'Codex 在前台时显示竖条；下次登录后后台助手会自动运行。'
