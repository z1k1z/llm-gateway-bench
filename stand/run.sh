#!/usr/bin/env bash
# ./run.sh prepare | control | saturate | report
# ./run.sh up | bench | security <gw> <profile>
# ./run.sh faults | fallback | down <gw>
# ./run.sh all <profile>
# gw: litellm bifrost newapi, profile: bare prod keys (fallback сам поднимается)

set -uo pipefail
STAND="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STAND"

# shellcheck disable=SC1091
set -a; . ./versions.env; . ./sentinels.env; set +a

# всё в host-сети: bifrost не ходит к провайдеру на 10/172/192.168,
# а allow_private_network из конфига не берёт. loopback пускают все трое
export RESULTS="${RESULTS:-$STAND/results}"
mkdir -p "$RESULTS"

CONC="${CONC:-8}"        # латентный режим
CONC_HI="${CONC_HI:-64}" # пропускной режим
REQS="${REQS:-120}"
REPEATS="${REPEATS:-5}"
# realistic это ~5.35 с на запрос, поэтому запросов меньше, p99 не смотрим
REQS_SLOW="${REQS_SLOW:-48}"
REPEATS_SLOW="${REPEATS_SLOW:-3}"
# в один процесс нагрузчик сам раздувает TTFT (51 мс против 29)
PROCS="${PROCS:-4}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

gw_port() {
  case "$1" in
    litellm) echo 4000 ;; bifrost) echo 8080 ;; newapi) echo 3000 ;;
    *) die "неизвестный гейтвей: $1" ;;
  esac
}

gw_model() {
  case "$1" in
    litellm) echo "mock-$2" ;;
    bifrost) echo "mocka/mock-$2" ;;
    newapi)  echo "mock-$2" ;;
  esac
}

# bifrost с config_store без VK не пускает, поэтому VK и в prod
gw_key() {
  if [ "${2:-}" = keys ] && [ "$1" != newapi ]; then echo "$BENCH_VK"; return; fi
  if [ "$1" = bifrost ] && { [ "${2:-}" = prod ] || [ "${2:-}" = fallback ]; }; then
    echo "$BENCH_VK"; return
  fi
  case "$1" in
    litellm|bifrost) echo "$MASTER_KEY" ;;
    newapi)
      local f="$STAND/gateways/newapi/data/api-key.txt"
      [ -f "$f" ] || die "нет $f, запусти gateways/newapi/seed.sh"
      tr -d '[:space:]' < "$f" ;;
  esac
}

wait_ready() {
  local url="$1" tries="${2:-45}" i=0 code
  while [ "$i" -lt "$tries" ]; do
    code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "$url" || true)
    case "$code" in 2??|3??|401|403) return 0 ;; esac
    i=$((i + 1)); sleep 2
  done
  return 1
}

mock_reset() {
  for p in 9000 9010; do
    curl -s -X POST "http://127.0.0.1:$p/control" -d '{"mode":"none"}' >/dev/null 2>&1 || true
  done
}

snapshot_stats() {
  docker stats --no-stream --format \
    '{"cpu":"{{.CPUPerc}}","mem":"{{.MemUsage}}","mem_pct":"{{.MemPerc}}"}' \
    "$1" 2>/dev/null > "$2" || echo '{}' > "$2"
}

harness() { # harness <label> <outfile> <остальные аргументы bench.py>
  local label="$1" out="$2"; shift 2
  # --user, иначе results/ будет root'овый
  docker run --rm --network host --user "$(id -u):$(id -g)" \
    -v "$RESULTS:/out" stand-harness:1 \
    --label "$label" --out "/out/$out" "$@"
}

cmd_prepare() {
  say "сеть, образы, мок-апстримы"
  docker build -q -t stand-mock:1 "$STAND/mock" >/dev/null || die "мок не собрался"
  docker build -q -t stand-harness:1 "$STAND/harness" >/dev/null || die "харнесс не собрался"
  docker rm -f mock-a mock-b >/dev/null 2>&1 || true
  docker run -d --name mock-a --network host -e MOCK_NAME=mock-a \
    -e MOCK_ADDR=127.0.0.1:9000 -e MOCK_TIMEOUT_SLEEP_MS=30000 stand-mock:1 >/dev/null
  docker run -d --name mock-b --network host -e MOCK_NAME=mock-b \
    -e MOCK_ADDR=127.0.0.1:9010 -e MOCK_TIMEOUT_SLEEP_MS=30000 stand-mock:1 >/dev/null
  wait_ready "http://127.0.0.1:9000/healthz" || die "mock-a не поднялся"
  wait_ready "http://127.0.0.1:9010/healthz" || die "mock-b не поднялся"
  mock_reset
  echo "mock-a :9000, mock-b :9010 готовы"
}

cmd_control() {
  say "контрольная группа: напрямую в мок, без гейтвея"
  mock_reset
  for kind in fast realistic; do
    local n r
    if [ "$kind" = realistic ]; then n="$REQS_SLOW"; r="$REPEATS_SLOW"; else n="$REQS"; r="$REPEATS"; fi
    for mode in stream complete; do
      echo "-- control/$mode/$kind ($n×$r)"
      harness "control/direct/$mode/$kind" "control-direct-$mode-$kind.json" \
        --url "http://127.0.0.1:9000/v1" --model "mock-$kind" --mode "$mode" \
        --concurrency "$CONC" --requests "$n" --repeats "$r" \
        || die "контрольный прогон упал"
    done
  done
  echo "-- control/throughput/fast (conc=$CONC_HI)"
  harness "control/direct/throughput/fast" "control-direct-throughput-fast.json" \
    --url "http://127.0.0.1:9000/v1" --model mock-fast --mode stream \
    --concurrency "$CONC_HI" --requests $((REQS * 4)) --repeats 3 \
    --processes "$PROCS" \
    || die "контрольный пропускной прогон упал"
}

# GW_CPUS=0-3 для локальных прогонов, чтобы не делить ядра с нагрузчиком
gw_cpu_args() { [ -n "${GW_CPUS:-}" ] && echo "--cpuset-cpus=$GW_CPUS"; }
gw_cpu_count() {
  [ -z "${GW_CPUS:-}" ] && { nproc; return; }
  echo "$GW_CPUS" | tr ',' '\n' | awk -F- '{n += ($2 == "" ? 1 : $2 - $1 + 1)} END {print n}'
}

up_litellm() {
  local profile="$1" cfg="$STAND/gateways/litellm/config.$profile.yaml"
  [ -f "$cfg" ] || die "нет конфига $cfg"
  local dburl=""
  if [ "$profile" = prod ] || [ "$profile" = keys ]; then
    docker rm -f gw-litellm-db >/dev/null 2>&1 || true
    # на 5432 может стоять свой postgres
    docker run -d --name gw-litellm-db --network host \
      -e POSTGRES_USER=litellm -e POSTGRES_PASSWORD=litellm -e POSTGRES_DB=litellm \
      postgres:17-alpine -p 55432 -c listen_addresses=127.0.0.1 >/dev/null
    local i=0
    until docker exec gw-litellm-db pg_isready -U litellm -p 55432 >/dev/null 2>&1; do
      i=$((i + 1)); [ "$i" -gt 30 ] && die "postgres не поднялся"; sleep 2
    done
    dburl="postgresql://litellm:litellm@127.0.0.1:55432/litellm"
  fi
  docker rm -f gw-litellm >/dev/null 2>&1 || true
  # пустой DATABASE_URL litellm считает заданным и падает
  local dbenv=()
  [ -n "$dburl" ] && dbenv=(-e "DATABASE_URL=$dburl")
  # по умолчанию один воркер, в доке советуют по числу vCPU
  local workers="${LITELLM_WORKERS:-$(gw_cpu_count)}"
  echo "litellm: воркеров $workers"
  docker run -d --name gw-litellm --network host $(gw_cpu_args) \
    -v "$cfg:/app/config.yaml:ro" \
    -e "LITELLM_MASTER_KEY=$MASTER_KEY" \
    "${dbenv[@]}" \
    -e "LITELLM_LOG=${LITELLM_LOG:-ERROR}" \
    "$LITELLM_IMAGE" --config /app/config.yaml --port 4000 --num_workers "$workers" >/dev/null
}

up_bifrost() {
  local profile="$1" dir="$STAND/gateways/bifrost"
  local cfg="$dir/config.$profile.json"
  [ -f "$cfg" ] || die "нет конфига $cfg"
  # без доступного pricing_url bifrost не стартует, отключить нельзя
  [ -s "$dir/offline/pricing.json" ] || die "нет прайсинга: запусти gateways/bifrost/offline/fetch.sh"
  docker rm -f gw-bifrost >/dev/null 2>&1 || true
  # файлы там root'овые, поэтому чистим через контейнер
  docker run --rm -v "$dir:/w" alpine rm -rf /w/data >/dev/null 2>&1 || true
  mkdir -p "$dir/data"
  docker run -d --name gw-bifrost --network host $(gw_cpu_args) \
    -v "$cfg:/app/data/config.json:ro" \
    -v "$dir/data:/app/data/state" \
    -v "$dir/offline:/app/offline:ro" \
    -e "BIFROST_ADMIN_USERNAME=${BIFROST_ADMIN_USERNAME:-admin}" \
    -e "BIFROST_ADMIN_PASSWORD=${BIFROST_ADMIN_PASSWORD:-stand-admin-pass}" \
    -e "BENCH_VK=$BENCH_VK" \
    "$BIFROST_IMAGE" >/dev/null
}

up_newapi() {
  mkdir -p "$STAND/gateways/newapi/data"
  docker rm -f gw-newapi >/dev/null 2>&1 || true
  docker run -d --name gw-newapi --network host $(gw_cpu_args) \
    -v "$STAND/gateways/newapi/data:/data" \
    -e TZ=Europe/Moscow \
    -e "SESSION_SECRET=${NEWAPI_SESSION_SECRET:-stand-session-secret}" \
    "$NEWAPI_IMAGE" >/dev/null
}

cmd_up() {
  local gw="$1" profile="${2:-bare}" port probe
  port="$(gw_port "$gw")"
  say "$gw, профиль $profile"
  case "$gw" in
    litellm) up_litellm "$profile" ;;
    bifrost) up_bifrost "$profile" ;;
    newapi)  up_newapi ;;
  esac
  probe="http://127.0.0.1:$port/"
  [ "$gw" = litellm ] && probe="http://127.0.0.1:$port/health/liveliness"
  wait_ready "$probe" 90 || { docker logs --tail 60 "gw-$gw"; die "$gw не поднялся"; }
  if [ "$gw" = newapi ]; then
    NEWAPI_FALLBACK=$([ "$profile" = fallback ] && echo 1 || echo 0) \
      bash "$STAND/gateways/newapi/seed.sh" || die "seed new-api не прошёл"
  fi
  if [ "$gw" = litellm ] && [ "$profile" = keys ]; then
    curl -s -m 30 "http://127.0.0.1:$port/key/generate" \
      -H "Authorization: Bearer $MASTER_KEY" -H 'Content-Type: application/json' \
      -d "$(jq -cn --arg k "$BENCH_VK" '{key:$k,key_alias:"bench",max_budget:1000,
            models:["mock-fast","mock-realistic"]}')" \
      | jq -e '.key' >/dev/null || die "litellm: виртуальный ключ не создан"
    echo "litellm: виртуальный ключ bench, бюджет 1000"
  fi
  echo "$gw слушает 127.0.0.1:$port"
}

cmd_down() {
  local gw="$1"
  docker rm -f "gw-$gw" >/dev/null 2>&1 || true
  [ "$gw" = litellm ] && docker rm -f gw-litellm-db >/dev/null 2>&1
  echo "$gw погашен"
}

cmd_bench() {
  local gw="$1" profile="${2:-bare}" port key model
  port="$(gw_port "$gw")"; key="$(gw_key "$gw" "$profile")"
  mock_reset
  say "замеры: $gw / $profile"
  snapshot_stats "gw-$gw" "$RESULTS/stats-$gw-$profile-idle.json"

  local n r
  for kind in fast realistic; do
    if [ "$kind" = realistic ]; then n="$REQS_SLOW"; r="$REPEATS_SLOW"; else n="$REQS"; r="$REPEATS"; fi
    for mode in stream complete; do
      model="$(gw_model "$gw" "$kind")"
      echo "-- $gw/$profile/$mode/$kind (model=$model, $n×$r)"
      harness "$gw/$profile/$mode/$kind" "bench-$gw-$profile-$mode-$kind.json" \
        --url "http://127.0.0.1:$port/v1" --model "$model" --mode "$mode" \
        --api-key "$key" --concurrency "$CONC" --requests "$n" --repeats "$r" \
        || echo "  прогон не удался, продолжаю"
    done
  done

  model="$(gw_model "$gw" fast)"
  echo "-- $gw/$profile/throughput (conc=$CONC_HI)"
  ( sleep 5; snapshot_stats "gw-$gw" "$RESULTS/stats-$gw-$profile-load.json" ) &
  harness "$gw/$profile/throughput/fast" "bench-$gw-$profile-throughput-fast.json" \
    --url "http://127.0.0.1:$port/v1" --model "$model" --mode stream \
    --api-key "$key" --concurrency "$CONC_HI" --requests $((REQS * 4)) --repeats 3 \
    --processes "$PROCS" \
    || echo "  пропускной прогон не удался, продолжаю"
  wait
}

cmd_faults() {
  local gw="$1" port key model out body code secs t0 t1
  port="$(gw_port "$gw")"; key="$(gw_key "$gw")"; model="$(gw_model "$gw" fast)"
  out="$RESULTS/faults-$gw.json"
  say "сценарии отказов: $gw"
  echo '[]' > "$out"
  for mode in 429 503 truncate timeout; do
    curl -s -X POST http://127.0.0.1:9000/control -d "{\"mode\":\"$mode\",\"rate\":1}" >/dev/null
    t0=$(date +%s.%N)
    body=$(curl -s -m 60 -w '\n%{http_code}' "http://127.0.0.1:$port/v1/chat/completions" \
      -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$model\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"проверка отказа\"}]}" 2>&1)
    t1=$(date +%s.%N)
    code=$(printf '%s' "$body" | tail -1)
    secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
    # код всегда 200, что дошло видно только по хвосту стрима
    local toks done_m err_ev
    toks=$(printf '%s' "$body" | sed -n 's/^data: \({.*\)$/\1/p' \
      | jq -r '.choices[0].delta.content? // empty' 2>/dev/null | grep -c . || true)
    done_m=$(printf '%s' "$body" | grep -c '^data: \[DONE\]' || true)
    err_ev=$(printf '%s' "$body" | grep '^data: ' | grep -c '"error"' || true)
    jq --arg m "$mode" --arg c "$code" \
       --argjson s "$(printf '%s' "$body" | grep -c '^data: ' || true)" \
       --argjson t "$toks" --argjson dn "$done_m" --argjson e "$err_ev" \
       --argjson d "$secs" --arg head "$(printf '%s' "$body" | head -c 300)" \
       --arg tail "$(printf '%s' "$body" | grep -v '^[0-9]*$' | tail -c 300)" \
       '. += [{mode:$m, http_code:$c, sse_events:$s, content_tokens:$t,
               done_marker:($dn > 0), error_event:($e > 0), seconds:$d,
               response_head:$head, response_tail:$tail}]' \
       "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    echo "  $mode -> код $code за ${secs}с"
  done
  mock_reset
  echo "-> $out"
}

cmd_saturate() {
  local out="$RESULTS/saturate-control.json"
  say "насыщение стенда: контроль без гейтвея"
  mock_reset
  echo '[]' > "$out"
  for c in 16 32 64 128 256; do
    local f="$RESULTS/.sat-$c.json"
    harness "saturate/control/conc$c" ".sat-$c.json" \
      --url "http://127.0.0.1:9000/v1" --model mock-fast --mode stream \
      --concurrency "$c" --requests $((c * 8)) --repeats 2 --warmup 8 \
      --processes "$PROCS" >/dev/null 2>&1 || { echo "  conc=$c не прошёл"; continue; }
    jq --argjson c "$c" --slurpfile r "$f" \
      '. += [{concurrency:$c,
              rps: $r[0].summary.rps.median,
              ttft_p50: $r[0].summary.ttft_ms.p50.median,
              ttft_p95: $r[0].summary.ttft_ms.p95.median}]' \
      "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    rm -f "$f"
    echo "  conc=$c -> $(jq -r '.[-1] | "rps=\(.rps) ttft_p50=\(.ttft_p50)"' "$out")"
  done
  echo "-> $out"
  echo "rps гейтвея имеет смысл, только если он заметно ниже этого"
}

cmd_fallback() {
  # гейтвеи переписывают id и режут заголовки, поэтому мок подписывается в тексте
  local gw="$1" port key out model
  port="$(gw_port "$gw")"; key="$(gw_key "$gw" fallback)"
  out="$RESULTS/fallback-$gw.json"
  case "$gw" in
    litellm) model=primary ;;
    bifrost) model="mocka/mock-fast" ;;
    newapi)  model="mock-fast" ;;
  esac
  say "фолбэк: $gw (модель $model)"
  cmd_up "$gw" fallback >/dev/null || die "не поднялся в профиле fallback"
  echo '[]' > "$out"

  for scenario in healthy 503 429; do
    if [ "$scenario" = healthy ]; then
      mock_reset
    else
      curl -s -X POST http://127.0.0.1:9000/control -d "{\"mode\":\"$scenario\",\"rate\":1}" >/dev/null
      curl -s -X POST http://127.0.0.1:9010/control -d '{"mode":"none"}' >/dev/null
    fi
    local t0 t1 secs answered content code
    t0=$(date +%s.%N)
    content=$(curl -s -m 60 -o "$RESULTS/.fb-body.json" -w '%{http_code}' \
      "http://127.0.0.1:$port/v1/chat/completions" \
      -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"фолбэк\"}]}")
    t1=$(date +%s.%N)
    code="$content"
    secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
    answered=$(jq -r '.choices[0].message.content // ""' "$RESULTS/.fb-body.json" 2>/dev/null | awk '{print $1}')
    [ -z "$answered" ] && answered="(нет ответа)"
    jq --arg s "$scenario" --arg c "$code" --arg who "$answered" --argjson d "$secs" \
       '. += [{scenario:$s, http_code:$c, answered_by:$who, seconds:$d}]' \
       "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    echo "  $scenario -> код $code, ответил $answered, ${secs}с"
  done
  mock_reset
  echo "-> $out"
}

cmd_security() { bash "$STAND/security/check.sh" "$1" "${2:-bare}"; }
cmd_report()   { python3 -I "$STAND/collect/report.py" "$RESULTS" > "$RESULTS/REPORT.md" \
                 && echo "-> $RESULTS/REPORT.md"; }

cmd_all() {
  local profile="${1:-bare}"
  cmd_prepare
  cmd_control
  for gw in litellm bifrost newapi; do
    cmd_up "$gw" "$profile" && cmd_bench "$gw" "$profile"
    cmd_security "$gw" "$profile"
    # от профиля не зависят
    if [ "$profile" = bare ]; then
      cmd_faults "$gw"
      cmd_down "$gw"
      cmd_fallback "$gw"
    fi
    cmd_down "$gw"
  done
  cmd_report
  say "готово, пришли мне содержимое results/"
}

case "${1:-}" in
  prepare)  cmd_prepare ;;
  control)  cmd_control ;;
  up)       cmd_up "${2:?нужен gw}" "${3:-bare}" ;;
  down)     cmd_down "${2:?нужен gw}" ;;
  bench)    cmd_bench "${2:?нужен gw}" "${3:-bare}" ;;
  faults)   cmd_faults "${2:?нужен gw}" ;;
  fallback) cmd_fallback "${2:?нужен gw}" ;;
  saturate) cmd_saturate ;;
  security) cmd_security "${2:?нужен gw}" "${3:-bare}" ;;
  report)   cmd_report ;;
  all)      cmd_all "${2:-bare}" ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac
