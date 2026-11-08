#!/usr/bin/env bash
# ./security/check.sh <gw> <profile>
# подписи, ключи и промпты в логах и БД, интерфейсы, что отдают без ключа

set -uo pipefail

STAND="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GW="${1:?gateway: litellm|bifrost|newapi}"
PROFILE="${2:-bare}"
COSIGN_IMAGE="ghcr.io/sigstore/cosign/cosign:v3.1.4"

# shellcheck disable=SC1091
. "$STAND/versions.env"
# shellcheck disable=SC1091
. "$STAND/sentinels.env"

case "$GW" in
  litellm) CONTAINER=gw-litellm; IMAGE="$LITELLM_IMAGE"; PORT=4000 ;;
  bifrost) CONTAINER=gw-bifrost; IMAGE="$BIFROST_IMAGE"; PORT=8080 ;;
  newapi)  CONTAINER=gw-newapi;  IMAGE="$NEWAPI_IMAGE";  PORT=3000 ;;
  *) echo "неизвестный гейтвей: $GW" >&2; exit 2 ;;
esac

OUT="${RESULTS:-$STAND/results}/security-$GW-$PROFILE.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

jqset() {
  local key="$1"; shift
  jq --argjson v "$1" ".$key = \$v" "$WORK/out.json" > "$WORK/tmp.json" && mv "$WORK/tmp.json" "$WORK/out.json"
}

printf '{"gateway":"%s","profile":"%s","image":"%s","checked_utc":"%s"}' \
  "$GW" "$PROFILE" "$IMAGE" "$(date -u +%FT%TZ)" > "$WORK/out.json"

echo "=== 1. Подпись образа ==="
sig_result='{"signed":false,"method":null,"detail":null}'
case "$GW" in
  litellm)
    # пин по коммиту, тег можно переставить
    KEY="https://raw.githubusercontent.com/BerriAI/litellm/e82a3c646908ba0a6ee0beddc4310d7a6cac4065/cosign.pub"
    if docker run --rm --network host "$COSIGN_IMAGE" verify --key "$KEY" "$IMAGE" > "$WORK/sig.txt" 2>&1; then
      sig_result='{"signed":true,"method":"cosign key, пин по коммиту","detail":null}'
    else
      sig_result=$(jq -cn --arg d "$(tail -c 400 "$WORK/sig.txt")" \
        '{signed:false,method:"cosign key",detail:$d}')
    fi
    ;;
  newapi|bifrost)
    REPO=$([ "$GW" = newapi ] && echo "QuantumNous/new-api" || echo "maximhq/bifrost")
    if docker run --rm --network host "$COSIGN_IMAGE" verify \
         --certificate-identity-regexp "^https://github.com/$REPO/" \
         --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
         "$IMAGE" > "$WORK/sig.txt" 2>&1; then
      sig_result=$(jq -cn --arg r "$REPO" \
        '{signed:true,method:"cosign keyless (GitHub Actions OIDC)",detail:$r}')
    else
      sig_result=$(jq -cn --arg d "$(tail -c 400 "$WORK/sig.txt")" \
        '{signed:false,method:"cosign keyless",detail:$d}')
    fi
    ;;
esac
echo "$sig_result" | jq -c .
jqset signature "$sig_result"

echo
echo "=== 2. Утечки в логах контейнера ==="
docker logs "$CONTAINER" > "$WORK/logs.txt" 2>&1 || true
PROMPT_FRAGMENT="зачем в инфраструктуре нужен прокси"
# промпт может лежать в JSON как за..., ищем и так
PROMPT_ESCAPED=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1])[1:-1])' "зачем в инфраструктуре")
prompt_hits() {
  echo $(( $(grep -ao "$PROMPT_FRAGMENT" "$1" | wc -l) + $(grep -aoF "$PROMPT_ESCAPED" "$1" | wc -l) ))
}
logs_result=$(jq -cn \
  --argjson lines "$(wc -l < "$WORK/logs.txt")" \
  --argjson up "$(grep -ao SENTINELUP "$WORK/logs.txt" | wc -l)" \
  --argjson cl "$(grep -ao SENTINELCL "$WORK/logs.txt" | wc -l)" \
  --argjson vk "$(grep -ao SENTINELVK "$WORK/logs.txt" | wc -l)" \
  --argjson pr "$(prompt_hits "$WORK/logs.txt")" \
  '{lines:$lines,upstream_key_hits:$up,client_key_hits:$cl,virtual_key_hits:$vk,prompt_hits:$pr}')
echo "$logs_result" | jq -c .
jqset logs "$logs_result"

echo
echo "=== 3. Утечки в базе ==="
db_result='{"scanned":[],"note":"базы не найдено"}'
scan_blob() {
  local f="$1"
  jq -cn --arg file "$(basename "$f")" \
    --argjson size "$(stat -c %s "$f")" \
    --argjson up "$(grep -ao SENTINELUP "$f" | wc -l)" \
    --argjson cl "$(grep -ao SENTINELCL "$f" | wc -l)" \
    --argjson vk "$(grep -ao SENTINELVK "$f" | wc -l)" \
    --argjson pr "$(prompt_hits "$f")" \
    '{file:$file,bytes:$size,upstream_key_hits:$up,client_key_hits:$cl,virtual_key_hits:$vk,prompt_hits:$pr}'
}
case "$GW" in
  litellm)
    if docker ps --format '{{.Names}}' | grep -q '^gw-litellm-db$'; then
      docker exec gw-litellm-db pg_dump -U litellm -p 55432 litellm > "$WORK/dump.sql" 2>/dev/null || true
      [ -s "$WORK/dump.sql" ] && db_result=$(jq -cn --argjson s "[$(scan_blob "$WORK/dump.sql")]" '{scanned:$s}')
    fi
    ;;
  bifrost)
    found=()
    # свежие записи sqlite лежат в -wal до чекпойнта
    for f in "$STAND"/gateways/bifrost/data/*.db* "$STAND"/gateways/bifrost/data/state/*.db*; do
      [ -f "$f" ] && found+=("$(scan_blob "$f")")
    done
    [ ${#found[@]} -gt 0 ] && db_result=$(jq -cn --argjson s "[$(IFS=,; echo "${found[*]}")]" '{scanned:$s}')
    ;;
  newapi)
    found=()
    for f in "$STAND"/gateways/newapi/data/*.db*; do
      [ -f "$f" ] && found+=("$(scan_blob "$f")")
    done
    [ ${#found[@]} -gt 0 ] && db_result=$(jq -cn --argjson s "[$(IFS=,; echo "${found[*]}")]" '{scanned:$s}')
    ;;
esac
echo "$db_result" | jq -c .
jqset database "$db_result"

echo
echo "=== 4. Что торчит наружу ==="
# host network, docker port ничего не покажет, смотрим ss
LISTEN=$(ss -ltnH "( sport = :$PORT )" 2>/dev/null | awk '{print $4}' | sort -u | jq -R . | jq -sc .)
WIDE=$(echo "$LISTEN" | jq '[.[] | select(test("^(\\*|0\\.0\\.0\\.0|\\[::\\]):"))] | length')
BINDINGS="$LISTEN"
if [ "$GW" = litellm ]; then
  DBL=$(ss -ltnH "( sport = :55432 )" 2>/dev/null | awk '{print $4}' | sort -u | jq -R . | jq -sc .)
  BINDINGS=$(jq -cn --argjson g "$LISTEN" --argjson d "$DBL" '{gateway:$g,postgres:$d}')
fi
declare -A CODES
for path in / /v1/models /ui /public/ /health /healthz \
            /api/providers /api/config /model/info /key/list /api/option/ /api/channel/; do
  # bifrost и new-api на любой путь отдают html UI, считаем только json
  CODES[$path]=$(curl -s -o /dev/null -m 5 -w '%{http_code} %{content_type}' "http://127.0.0.1:$PORT$path" || true)
done
unauth=$(for p in "${!CODES[@]}"; do
  read -r code ctype <<< "${CODES[$p]}"
  jq -cn --arg p "$p" --arg c "$code" --arg t "${ctype:-}" \
    '{path:$p, code:$c, content_type:$t, json:($t|test("json"))}'
done | jq -sc .)
expose_result=$(jq -cn --argjson b "$BINDINGS" --argjson wide "$WIDE" --argjson u "$unauth" \
  '{listen:$b,bound_to_all_interfaces:$wide,unauthenticated:$u}')
echo "$expose_result" | jq -c '{bound_to_all_interfaces,unauthenticated}'
jqset exposure "$expose_result"

echo
echo "=== 5. Где лежат ключи ==="
ENVJSON=$(docker inspect -f '{{json .Config.Env}}' "$CONTAINER" 2>/dev/null || echo '[]')
ENV_LEAK=$(echo "$ENVJSON" | jq '[.[] | select(test("SENTINEL"))] | length')
PID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER" 2>/dev/null || echo 0)
PROC_READABLE=false; PROC_LEAK=0
if [ "$PID" != 0 ] && [ -r "/proc/$PID/environ" ]; then
  PROC_READABLE=true
  PROC_LEAK=$(tr '\0' '\n' < "/proc/$PID/environ" | grep -ac SENTINEL || true)
fi
secrets_result=$(jq -cn --argjson e "$ENV_LEAK" --argjson p "$PROC_LEAK" \
  --arg r "$PROC_READABLE" --argjson pid "$PID" \
  '{docker_inspect_env_hits:$e,proc_environ_readable:($r=="true"),proc_environ_hits:$p,pid:$pid}')
echo "$secrets_result" | jq -c .
echo "  (proc_environ_readable=false означает только, что мы запущены без root)"
jqset secrets "$secrets_result"

mkdir -p "$(dirname "$OUT")"
cp "$WORK/out.json" "$OUT"
echo
echo "-> $OUT"
