#!/bin/zsh
# Пересобирает картинки для README в docs/screenshots. Использует выдуманные оценки,
# свои данные и настройки не трогает: приложение запускается с отдельной домашней папкой.
set -euo pipefail
cd "$(dirname "$0")/../.."
T=$(mktemp -d); mkdir -p "$T/home/Library/Application Support/Nudge" "$T/raw"
python3 - "$T/home/Library/Application Support/Nudge/ratings.csv" <<'PY'
import sys, random, math, datetime
random.seed(7)
now = datetime.datetime.now().replace(second=0, microsecond=0)
notes = ["Выспался", "Много встреч подряд", "Хорошо поработал утром", "Устал к вечеру", "Прогулка помогла",
         "Отвлекался весь день", "Закрыл важную задачу", "Голова тяжёлая", ""]
rows = ["Дата,Оценка из 10,Комментарий"]
for d in range(20, -1, -1):
    day = now - datetime.timedelta(days=d)
    for k in range(random.randint(2, 4)):
        t = day.replace(hour=10 + 3 * k, minute=random.choice([0, 10, 20, 40]))
        if t > now: continue
        p = max(2, min(10, round(6 + 2 * math.sin(d / 3) + random.uniform(-2, 2))))
        c = random.choice(notes)
        rows.append(f"{t:%Y-%m-%d %H:%M},{p}" + (f',"{c}"' if c else ""))
open(sys.argv[1], "w").write("\n".join(rows) + "\n")
PY
./build.sh >/dev/null
ditto "График жизни.app" "$T/Shots.app"
python3 - "$T" <<'PY'
import sys
s = open("main.swift").read()
assert s.count("\napp.run()\n") == 1
open(sys.argv[1] + "/main.swift", "w").write(s.replace("\napp.run()\n", "\n" + open("tools/screenshots/hook.swift").read()))
PY
swiftc -swift-version 5 -F vendor/Sparkle-* -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$T/main.swift" -o "$T/Shots.app/Contents/MacOS/Nudge"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.nudge.screenshots" -c "Set :SUEnableAutomaticChecks false" "$T/Shots.app/Contents/Info.plist"
codesign --force --sign - "$T/Shots.app" 2>/dev/null
RAW_DIR="$T/raw" CFFIXED_USER_HOME="$T/home" HOME="$T/home" perl -e 'alarm 60; exec @ARGV' "$T/Shots.app/Contents/MacOS/Nudge" >/dev/null 2>&1 || true
defaults delete local.nudge.screenshots 2>/dev/null || true
mkdir -p docs/screenshots
swift tools/screenshots/compose.swift "$T/raw" docs/screenshots
rm -rf "$T" "График жизни.app"
ls docs/screenshots
