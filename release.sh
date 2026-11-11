#!/bin/bash
# Заверенный архив menu bar-приложения для релиза на GitHub:
# сборка с подписью Developer ID -> заверение Apple -> прикрепление -> zip.
# Публикацию (тег, gh release) скрипт не делает.
#
# Нужно: сертификат "Developer ID Application" в Keychain и ключ App Store
# Connect API. Переменные (значения - не в репозитории):
#   CLAUDEX_SIGN_IDENTITY  "Developer ID Application: Name (TEAMID)"
#   ASC_KEY_PATH           путь к AuthKey_XXXX.p8
#   ASC_KEY_ID             id ключа
#   ASC_ISSUER_ID          issuer id
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="ClaudeX"
VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "$ROOT/project.yml")"
: "${CLAUDEX_SIGN_IDENTITY:?нужна подпись Developer ID}"
: "${ASC_KEY_PATH:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"

APP="$ROOT/build/$NAME.app"
ZIP="$ROOT/build/$NAME-$VERSION-menubar.zip"

"$ROOT/build.sh"
codesign --verify --strict "$APP"

echo "==> Заверение Apple"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" \
      --issuer "$ASC_ISSUER_ID" --wait --timeout 30m

echo "==> Прикрепление и проверка"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

# Архив пересобирается: в нём должно быть приложение с прикреплённым заверением.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> Готово: $ZIP"
