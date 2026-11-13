#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="1.4.0"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/Codex Quota Strip.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
compile() {
    local build_arch="$1"
    xcrun swiftc -swift-version 5 -O -target "$build_arch-apple-macos13.0" \
        -framework AppKit "$project_dir/Sources/QuotaModel.swift" "$project_dir/Sources/main.swift" \
        -o "$dist_dir/CodexQuotaStrip-$build_arch"
}
if [[ "${1:-}" == "--universal" ]]; then
    compile arm64
    compile x86_64
    xcrun lipo -create "$dist_dir/CodexQuotaStrip-arm64" "$dist_dir/CodexQuotaStrip-x86_64" \
        -output "$app_dir/Contents/MacOS/CodexQuotaStrip"
    package_arch="universal"
else
    package_arch="$(uname -m)"
    compile "$package_arch"
    cp "$dist_dir/CodexQuotaStrip-$package_arch" "$app_dir/Contents/MacOS/CodexQuotaStrip"
fi
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexQuotaStrip</string>
<key>CFBundleIdentifier</key><string>io.github.codex-quota-strip</string>
<key>CFBundleName</key><string>Codex Quota Strip</string>
<key>CFBundleDisplayName</key><string>Codex Quota Strip</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
zip_path="$dist_dir/Codex-Quota-Strip-v$version-$package_arch.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$zip_path"
(cd "$dist_dir" && shasum -a 256 "$(basename "$zip_path")" > "$(basename "$zip_path").sha256")
echo "Built: $zip_path"
