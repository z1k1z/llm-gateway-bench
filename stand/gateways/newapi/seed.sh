#!/usr/bin/env bash
# настройка new-api через API: админ, канал на мок, токен
# пароль админа в data/admin.txt, токен в data/api-key.txt

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAND="$(cd "$DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$STAND/sentinels.env"

BASE="http://127.0.0.1:3000"
DATA="$DIR/data"
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT
mkdir -p "$DATA"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

# код почти всегда 200, смотрим success
api() {
  local method="$1" path="$2" body="${3:-}" out
  local args=(-s -m 15 -b "$JAR" -c "$JAR" -X "$method" "$BASE$path"
              -H 'Content-Type: application/json')
  [ -n "${USER_ID:-}" ] && args+=(-H "New-Api-User: $USER_ID")
  [ -n "${ACCESS:-}" ] && args+=(-H "Authorization: Bearer $ACCESS")
  # refresh без Origin не пускает
  [ "$path" = /api/user/auth/refresh ] && args+=(-H "Origin: $BASE")
  [ -n "$body" ] && args+=(-d "$body")
  out=$(curl "${args[@]}") || die "$method $path: нет ответа"
  echo "$out" | jq -e '.success == true' >/dev/null \
    || die "$method $path: $(echo "$out" | jq -c '.message // .' | cut -c1-200)"
  echo "$out"
}

ADMIN=admin
if [ -f "$DATA/admin.txt" ]; then
  PASS=$(tr -d '[:space:]' < "$DATA/admin.txt")
else
  PASS="St$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)9!"
  umask 077; echo "$PASS" > "$DATA/admin.txt"
fi

echo "1. Администратор"
if curl -s -m 5 "$BASE/api/setup" | jq -e '.data.status == true' >/dev/null; then
  echo "   уже создан"
else
  # без SelfUseMode модель без цены не пускает
  api POST /api/setup "$(jq -cn --arg u "$ADMIN" --arg p "$PASS" \
    '{username:$u,password:$p,confirmPassword:$p,SelfUseModeEnabled:true,DemoSiteEnabled:false}')" >/dev/null
  echo "   создан"
fi

echo "2. Вход"
USER_ID=$(api POST /api/user/login "$(jq -cn --arg u "$ADMIN" --arg p "$PASS" \
  '{username:$u,password:$p}')" | jq -r '.data.user.id // .data.id')
[ -n "$USER_ID" ] && [ "$USER_ID" != null ] || die "логин не вернул id"
# логин дает только refresh-куку, access берем отдельно
ACCESS=$(api POST /api/user/auth/refresh | jq -r '.data.access_token')
[ -n "$ACCESS" ] && [ "$ACCESS" != null ] || die "refresh не вернул access_token"

echo "3. Канал на мок-апстрим"
if api GET '/api/channel/?p=1&page_size=50' | jq -e '[.data.items[]? | select(.name=="mock-a")] | length > 0' >/dev/null; then
  echo "   уже есть"
else
  # type 1 = openai, /v1 он допишет сам
  api POST /api/channel/ "$(jq -cn --arg k "$UPSTREAM_KEY" '{mode:"single",channel:{
    type:1,name:"mock-a",key:$k,base_url:"http://127.0.0.1:9000",
    models:"mock-fast,mock-realistic",group:"default",status:1}}')" >/dev/null
  echo "   создан"
fi

echo "3б. Резервный канал (NEWAPI_FALLBACK=${NEWAPI_FALLBACK:-0})"
# по умолчанию RetryTimes=0. mock-b и ретрай только для фолбэка
CH=$(api GET '/api/channel/?p=1&page_size=50')
B_ID=$(echo "$CH" | jq -r '[.data.items[]? | select(.name=="mock-b")][0].id // empty')
if [ "${NEWAPI_FALLBACK:-0}" = 1 ]; then
  [ -z "$B_ID" ] && api POST /api/channel/ "$(jq -cn --arg k "$UPSTREAM_KEY" '{mode:"single",channel:{
    type:1,name:"mock-b",key:$k,base_url:"http://127.0.0.1:9010",
    models:"mock-fast,mock-realistic",group:"default",status:1,priority:0}}')" >/dev/null
  A=$(echo "$CH" | jq -c '[.data.items[]? | select(.name=="mock-a")][0]')
  api PUT /api/channel/ "$(echo "$A" | jq -c '{id, priority: 10}')" >/dev/null
  api PUT /api/option/ '{"key":"RetryTimes","value":"1"}' >/dev/null
  echo "   mock-b добавлен, RetryTimes=1"
else
  [ -n "$B_ID" ] && api DELETE "/api/channel/$B_ID" >/dev/null
  api PUT /api/option/ '{"key":"RetryTimes","value":"0"}' >/dev/null
  echo "   резерва нет, RetryTimes=0"
fi

echo "4. Токен для замеров"
TID=$(api GET '/api/token/?p=1&size=50' | jq -r '[.data.items[]? | select(.name=="bench")][0].id // empty')
if [ -z "$TID" ]; then
  api POST /api/token/ '{"name":"bench","unlimited_quota":true,"remain_quota":0,"expired_time":-1}' >/dev/null
  TID=$(api GET '/api/token/?p=1&size=50' | jq -r '[.data.items[]? | select(.name=="bench")][0].id')
fi
KEY=$(api POST "/api/token/$TID/key" | jq -r '.data.key // .data')
case "$KEY" in sk-*) ;; *) KEY="sk-$KEY" ;; esac
umask 077; echo "$KEY" > "$DATA/api-key.txt"
echo "   -> $DATA/api-key.txt"

echo "5. Проверка"
curl -s -m 30 "$BASE/v1/chat/completions" -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"mock-fast","messages":[{"role":"user","content":"привет"}]}' \
  | jq -c '{usage, first: ((.choices[0].message.content // "")|split(" ")[0]), err: .error.message}'
