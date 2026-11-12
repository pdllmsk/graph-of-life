#!/bin/zsh
# Выпускает новую версию на GitHub. У всех, кто поставил приложение, она установится сама.
#   ./release.sh 1.1 "Что изменилось"
set -euo pipefail
cd "$(dirname "$0")"
REPO=pdllmsk/graph-of-life
V=${1:?Укажи версию, например: ./release.sh 1.1 "Что изменилось"}
NOTES=${2:-}

[[ -z "$(git status --porcelain)" ]] || { echo "Сначала закоммить изменения." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/v$V" >/dev/null; then echo "Версия $V уже выпущена." >&2; exit 1; fi

echo "$V" > VERSION
./package.sh "$V" "https://github.com/$REPO/releases/download/v$V"
if ! git diff --quiet VERSION; then git commit -q -m "Версия $V" VERSION; fi
git tag "v$V"
git push -q origin HEAD "v$V"

gh release create "v$V" "dist/GraphOfLife-$V.zip" dist/appcast.xml --repo "$REPO" \
  --title "График жизни $V" --notes "${NOTES:+$NOTES

}$(cat INSTALL.md)"
echo "Выпущено: https://github.com/$REPO/releases/tag/v$V"
