#!/bin/bash
# Rebuilds AppIcon and OasesIcon from OasesChat/DesignSystem/Brand/TwinPoolsGeometry.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$(mktemp -d)"
xcrun --sdk macosx swiftc -O -parse-as-library \
  OasesChat/DesignSystem/Brand/TwinPoolsGeometry.swift scripts/brand/render_icons.swift \
  -o "$out/render_icons"
"$out/render_icons" OasesChat/Resources/Assets.xcassets
