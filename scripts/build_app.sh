#!/bin/zsh
# Builds PoEPriceCheck.app into ~/Applications and signs it with your Apple Development identity
# (a stable signature keeps the Screen Recording permission across rebuilds).
#   scripts/build_app.sh                 build + install
#   scripts/build_app.sh --refresh-data  also re-download trade stats/items and regenerate base types
set -euo pipefail
cd "$(dirname "$0")/.."

SCRATCH="$HOME/Library/Caches/PoEPriceCheck/build"   # outside iCloud Desktop: Finder xattrs break codesign
APP="$HOME/Applications/PoEPriceCheck.app"
BUNDLE_ID="io.github.poepricecheck"
# Optional machine-specific overrides (git-ignored), e.g. BUNDLE_ID=... to keep existing permission grants.
[[ -f scripts/local.env ]] && source scripts/local.env
UA="PoEPriceCheck/0.1 (macOS; personal OCR price-check overlay)"

if [[ "${1:-}" == "--refresh-data" ]]; then
  for e in stats items; do
    curl -fsS -A "$UA" -o "Data/poe2/$e.json" "https://www.pathofexile.com/api/trade2/data/$e"
    curl -fsS -A "$UA" -o "Data/poe1/$e.json" "https://www.pathofexile.com/api/trade/data/$e"
  done
  python3 -I tools/trim_stats.py Data/poe1/stats.json
  mkdir -p .cache
  curl -fsS -o .cache/repoe_base_items.json https://repoe-fork.github.io/poe2/base_items.min.json
  curl -fsS -o .cache/repoe_poe1_base_items.json https://repoe-fork.github.io/base_items.min.json
  python3 -I tools/gen_base_items.py .cache/repoe_base_items.json Data/poe2 poe2
  python3 -I tools/gen_base_items.py .cache/repoe_poe1_base_items.json Data/poe1 poe1
fi

swift build -c release --scratch-path "$SCRATCH" --product PoEPriceCheck
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/PoEPriceCheck"

# Quit a running copy so the new binary takes over.
pkill -x PoEPriceCheck 2>/dev/null || true

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/PoEPriceCheck"
for game in poe1 poe2; do
  mkdir -p "$APP/Contents/Resources/$game"
  cp Data/$game/base_items.json Data/$game/items.json Data/$game/stats.json "$APP/Contents/Resources/$game/"
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>PoEPriceCheck</string>
  <key>CFBundleDisplayName</key><string>PoE Price Check</string>
  <key>CFBundleExecutable</key><string>PoEPriceCheck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Reads the item tooltip under your cursor to price it.</string>
</dict>
</plist>
PLIST

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')"
xattr -cr "$APP"
codesign --force --sign "${IDENTITY:--}" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"
echo "Installed $APP (signed: ${IDENTITY:-ad-hoc})"
