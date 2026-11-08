#!/usr/bin/env bash
# Первичная настройка new-api через его же HTTP API — то, что мастер делает
# в браузере: администратор, канал на мок-апстрим, токен для замеров.
#
# Пароль администратора генерируется и лежит только в data/admin.txt
# (каталог в .gitignore). Токен для замеров — в data/api-key.txt.
#
# Запуск: ./gateways/newapi/seed.sh  (гейтвей должен быть поднят)

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

# Ответы new-api: {"success":bool,"message":str,"data":...}. HTTP-код почти
# всегда 200, поэтому успех проверяем по полю success.
api() {
  local method="$1" path="$2" body="${3:-}" out
  local args=(-s -m 15 -b "$JAR" -c "$JAR" -X "$method" "$BASE$path"
              -H 'Content-Type: application/json')
  [ -n "${USER_ID:-}" ] && args+=(-H "New-Api-User: $USER_ID")
  [ -n "${ACCESS:-}" ] && args+=(-H "Authorization: Bearer $ACCESS")
  # Refresh защищён проверкой Origin от CSRF: шлём тот же, что у браузера.
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
  # Буквы, цифры и спецсимвол — чтобы пройти любую политику сложности.
  PASS="St$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)9!"
  umask 077; echo "$PASS" > "$DATA/admin.txt"
fi

echo "1. Администратор"
if curl -s -m 5 "$BASE/api/setup" | jq -e '.data.status == true' >/dev/null; then
  echo "   уже создан"
else
  # SelfUseModeEnabled: без него запрос к модели без прайса в таблице
  # new-api отклоняет. У мока прайса нет и быть не может.
  api POST /api/setup "$(jq -cn --arg u "$ADMIN" --arg p "$PASS" \
    '{username:$u,password:$p,confirmPassword:$p,SelfUseModeEnabled:true,DemoSiteEnabled:false}')" >/dev/null
  echo "   создан"
fi

echo "2. Вход"
USER_ID=$(api POST /api/user/login "$(jq -cn --arg u "$ADMIN" --arg p "$PASS" \
  '{username:$u,password:$p}')" | jq -r '.data.user.id // .data.id')
[ -n "$USER_ID" ] && [ "$USER_ID" != null ] || die "логин не вернул id"
# Логин отдаёт только refresh-куку. Короткоживущий access-токен для API
# выдаёт отдельный вызов (так в v1.0.0-rc.48, проверено на стенде).
ACCESS=$(api POST /api/user/auth/refresh | jq -r '.data.access_token')
[ -n "$ACCESS" ] && [ "$ACCESS" != null ] || die "refresh не вернул access_token"

echo "3. Канал на мок-апстрим"
if api GET '/api/channel/?p=1&page_size=50' | jq -e '[.data.items[]? | select(.name=="mock-a")] | length > 0' >/dev/null; then
  echo "   уже есть"
else
  # type 1 — OpenAI. base_url без /v1: путь new-api дописывает сам.
  api POST /api/channel/ "$(jq -cn --arg k "$UPSTREAM_KEY" '{mode:"single",channel:{
    type:1,name:"mock-a",key:$k,base_url:"http://127.0.0.1:9000",
    models:"mock-fast,mock-realistic",group:"default",status:1}}')" >/dev/null
  echo "   создан"
fi

echo "3б. Резервный канал (NEWAPI_FALLBACK=${NEWAPI_FALLBACK:-0})"
# Из коробки RetryTimes=0: new-api не повторяет запрос и не переключает канал.
# Для проверки фолбэка заводим mock-b с меньшим приоритетом и один повтор,
# в остальных профилях канала нет и повторов нет, иначе отказы mock-a
# в замерах маскировались бы.
CH=$(api GET '/api/channel/?p=1&page_size=50')
B_ID=$(echo "$CH" | jq -r '[.data.items[]? | select(.name=="mock-b")][0].id // empty')
if [ "${NEWAPI_FALLBACK:-0}" = 1 ]; then
  [ -z "$B_ID" ] && api POST /api/channel/ "$(jq -cn --arg k "$UPSTREAM_KEY" '{mode:"single",channel:{
    type:1,name:"mock-b",key:$k,base_url:"http://127.0.0.1:9010",
    models:"mock-fast,mock-realistic",group:"default",status:1,priority:0}}')" >/dev/null
  # mock-a должен быть приоритетнее, иначе часть запросов сразу уйдёт в mock-b.
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
