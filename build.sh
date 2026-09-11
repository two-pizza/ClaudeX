#!/bin/bash
# Сборка ClaudeX.app. С флагом --install кладёт готовый бандл в ~/Applications и перезапускает.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="ClaudeX"
# One source of truth for the version: project.yml (the Xcode build reads the same keys).
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "$ROOT/project.yml")"
BUILD_NUMBER="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\([^"]*\)".*/\1/p' "$ROOT/project.yml")"
VERSION="${VERSION:-0.0.0}"; BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="$ROOT/build/$NAME.app"
INSTALL_DIR="$HOME/Applications"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>$NAME</string>
    <key>CFBundleDisplayName</key>     <string>ClaudeX</string>
    <key>CFBundleIdentifier</key>      <string>me.andrey.$NAME</string>
    <key>CFBundleExecutable</key>      <string>$NAME</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "==> Компиляция"
swiftc -O -whole-module-optimization \
       -target arm64-apple-macos13.0 \
       -o "$APP/Contents/MacOS/$NAME" \
       $(find "$ROOT/Sources/Shared" "$ROOT/Sources/App" -name '*.swift')

# Подпись обязательна: без неё SMAppService откажется регистрировать автозапуск.
echo "==> Подпись (ad-hoc)"
codesign --force --sign - --identifier "me.andrey.$NAME" "$APP"

if [ "${1:-}" = "--install" ]; then
    echo "==> Установка в $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    pkill -x "$NAME" 2>/dev/null || true
    # Ждём фактического завершения: иначе open ловит -600 на ещё живом процессе.
    for _ in $(seq 1 30); do pgrep -x "$NAME" >/dev/null || break; sleep 0.1; done
    rm -rf "${INSTALL_DIR:?}/$NAME.app"
    cp -R "$APP" "$INSTALL_DIR/"
    open "$INSTALL_DIR/$NAME.app"
    echo "==> Запущено из $INSTALL_DIR/$NAME.app"
else
    echo "==> Собрано: $APP"
    echo "    Запуск: open '$APP'   |   Установка: ./build.sh --install"
fi
