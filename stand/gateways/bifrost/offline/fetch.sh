#!/usr/bin/env bash
# Bifrost не запускается, если pricing_url недоступен, а отключить
# синхронизацию прайсинга нельзя — только подменить на локальный файл.
# Скачиваем датасеты один раз; дальше гейтвей читает их с диска,
# и фоновая синхронизация не влияет на замеры.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
curl -fsSL -o pricing.json          https://getbifrost.ai/datasheet
curl -fsSL -o model-parameters.json https://getbifrost.ai/datasheet/model-parameters
for f in pricing.json model-parameters.json; do
  jq -e type "$f" >/dev/null || { echo "$f не JSON" >&2; exit 1; }
  printf '%-22s %s байт\n' "$f" "$(stat -c %s "$f")"
done
