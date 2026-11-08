#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter SDK is required to generate the iPadOS host project." >&2
  exit 1
fi

# Generate only the missing iOS host. This leaves the shared Dart source and
# the existing macOS host untouched.
if [[ ! -d ios ]]; then
  flutter create \
    --platforms=ios \
    --org com.lastwave \
    --project-name lastwave \
    .
fi

PBXPROJ="ios/Runner.xcodeproj/project.pbxproj"
INFO_PLIST="ios/Runner/Info.plist"
if [[ ! -f "$PBXPROJ" || ! -f "$INFO_PLIST" ]]; then
  echo "Flutter did not generate the expected iOS Runner project." >&2
  exit 1
fi

python3 - "$PBXPROJ" "$INFO_PLIST" <<'PY'
import pathlib
import plistlib
import re
import sys

pbx_path = pathlib.Path(sys.argv[1])
plist_path = pathlib.Path(sys.argv[2])
bundle_id = "com.lastwave.lastwaveDesktop"

pbx = pbx_path.read_text(encoding="utf-8")

def replace_bundle(match: re.Match[str]) -> str:
    old_id = match.group(2).strip()
    suffix = ".RunnerTests" if old_id.endswith(".RunnerTests") else ""
    return f"{match.group(1)}{bundle_id}{suffix}{match.group(3)}"

pbx, bundle_count = re.subn(
    r"(PRODUCT_BUNDLE_IDENTIFIER\\s*=\\s*)([^;]+)(;)",
    replace_bundle,
    pbx,
)
if bundle_count == 0:
    raise SystemExit("No PRODUCT_BUNDLE_IDENTIFIER settings found in iOS project.")

pbx, target_count = re.subn(
    r"IPHONEOS_DEPLOYMENT_TARGET\\s*=\\s*[^;]+;",
    "IPHONEOS_DEPLOYMENT_TARGET = 15.0;",
    pbx,
)
if target_count == 0:
    raise SystemExit("No iOS deployment target settings found in Xcode project.")
pbx_path.write_text(pbx, encoding="utf-8")

with plist_path.open("rb") as handle:
    info = plistlib.load(handle)

info["CFBundleDisplayName"] = "LastWave"
info["CFBundleName"] = "LastWave"

# Permit continuous audio playback while the application is backgrounded.
# This declares the capability; the native audio session and remote-control
# bridge must still be implemented and tested before background playback can
# be considered verified.
modes = list(info.get("UIBackgroundModes", []))
if "audio" not in modes:
    modes.append("audio")
info["UIBackgroundModes"] = modes

# Use all standard iPad orientations; the Flutter UI remains responsible for
# adapting its layout to the available size and safe areas.
info["UISupportedInterfaceOrientations~ipad"] = [
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
]

plist_path.write_bytes(
    plistlib.dumps(info, fmt=plistlib.FMT_XML, sort_keys=False)
)
print("Configured LastWave bundle metadata, iOS 15 minimum, and audio background capability.")
PY

# Reuse the actual LastWave macOS app icon as the iPadOS app icon.
ICON_SOURCE="macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png"
ICON_DIR="ios/Runner/Assets.xcassets/AppIcon.appiconset"
if [[ -f "$ICON_SOURCE" && -d "$ICON_DIR" ]]; then
  cp "$ICON_SOURCE" "$ICON_DIR/AppIcon.png"
  cat > "$ICON_DIR/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "AppIcon.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
fi

echo "iPadOS host project is ready."
