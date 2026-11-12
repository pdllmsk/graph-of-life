#!/bin/zsh
# Собирает версию для раздачи: архив приложения и подписанный список обновлений (appcast) в папке dist.
#   ./package.sh <версия> <адрес папки, откуда будет скачиваться архив>
set -euo pipefail
cd "$(dirname "$0")"
V=${1:?версия}
BASE=${2:?адрес для скачивания}
KEY=${SPARKLE_KEY_FILE:-$HOME/.config/graph-of-life/sparkle-private-key}
[[ -f "$KEY" ]] || { echo "Нет ключа подписи обновлений: $KEY" >&2; exit 1; }

VERSION=$V ./build.sh
mkdir -p dist
ZIP="GraphOfLife-$V.zip"
rm -f "dist/$ZIP"
ditto -c -k --sequesterRsrc --keepParent "График жизни.app" "dist/$ZIP"
SIG=$(vendor/Sparkle-*/bin/sign_update --ed-key-file "$KEY" "dist/$ZIP")
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>График жизни</title>
    <item>
      <title>Версия $V</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$V</sparkle:version>
      <sparkle:shortVersionString>$V</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="$BASE/$ZIP" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "Готово: dist/$ZIP и dist/appcast.xml"
