#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_dir/.build"
xcrun swiftc "$project_dir/Sources/QuotaModel.swift" "$project_dir/Tests/QuotaModelTests.swift" \
    -o "$project_dir/.build/QuotaModelTests"
"$project_dir/.build/QuotaModelTests"
