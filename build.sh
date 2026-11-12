#!/bin/zsh
# Собирает «График жизни.app» рядом со скриптом: универсальная сборка (Apple и Intel) со встроенным Sparkle.
# Версия берётся из файла VERSION или переменной VERSION.
# FEED_URL и BUNDLE_ID меняют адрес списка обновлений и идентификатор — только для проверки обновлений на своём Mac.
set -euo pipefail
cd "$(dirname "$0")"

APP="График жизни.app"
VERSION=${VERSION:-$(cat VERSION)}
BUNDLE_ID=${BUNDLE_ID:-local.nudge}
FEED_URL=${FEED_URL:-https://github.com/pdllmsk/graph-of-life/releases/latest/download/appcast.xml}
SPARKLE_PUBLIC_KEY="t/FXjgjmQBJEkC7SyTmt+rXC/E8NgPR66EDxVUSEvSc="

# Sparkle скачивается один раз и всегда сверяется с контрольной суммой.
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
SPARKLE_DIR="vendor/Sparkle-$SPARKLE_VERSION"
if [[ ! -d "$SPARKLE_DIR/Sparkle.framework" ]]; then
  mkdir -p vendor/download "$SPARKLE_DIR"
  archive="vendor/download/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -sSfL -o "$archive" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $archive" | shasum -a 256 -c -
  tar -xJf "$archive" -C "$SPARKLE_DIR"
  rm -rf vendor/download
fi

rm -rf "$APP" build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14 \
    -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    main.swift -o build/Nudge-$arch
done
lipo -create build/Nudge-arm64 build/Nudge-x86_64 -output "$APP/Contents/MacOS/Nudge"
rm -rf build
ditto "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp AppIcon.icns MenuIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>График жизни</string>
  <key>CFBundleDisplayName</key><string>График жизни</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Nudge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleLocalizations</key><array><string>ru</string></array>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>14400</integer>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Готово: $(pwd)/$APP, версия $VERSION"
