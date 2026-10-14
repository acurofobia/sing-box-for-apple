#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/upstream/sing-box"
TOOLS="$ROOT/build/go-tools"
mkdir -p "$TOOLS"
if [[ ! -x "$TOOLS/gomobile" || ! -x "$TOOLS/gobind" ]]; then
    GOBIN="$TOOLS" go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
    GOBIN="$TOOLS" go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
fi
export PATH="$TOOLS:$PATH"
cd "$CORE"
gomobile bind -o Libbox.xcframework -target ios,iossimulator -libname=box -iosversion=15.0 \
    -trimpath -buildvcs=false \
    -ldflags '-checklinkname=0 -s -w -X github.com/sagernet/sing-box/constant.Version=1.14.2-vkprototype -X runtime.godebugDefault=asyncpreemptoff=1,multipathtcp=0,tlssha1=1' \
    -tags with_gvisor,with_wireguard,with_utls,with_clash_api,with_low_memory,badlinkname,tfogo_checklinkname0 \
    ./experimental/libbox
cd "$ROOT"
DESTINATION="generic/platform=iOS"
if [[ -n "${DEVICE_UDID:-}" ]]; then DESTINATION="id=$DEVICE_UDID"; fi
PACKAGE_ARGUMENTS=()
if [[ -n "${SOURCE_PACKAGES_DIR:-}" ]]; then
    PACKAGE_ARGUMENTS=(-clonedSourcePackagesDirPath "$SOURCE_PACKAGES_DIR" -disableAutomaticPackageResolution)
fi
xcodebuild build -project sing-box.xcodeproj -scheme VKTurnPrototype -configuration Debug \
    -destination "$DESTINATION" -derivedDataPath build/DerivedData \
    "${PACKAGE_ARGUMENTS[@]}" -allowProvisioningUpdates DISABLE_SWIFTLINT=1
