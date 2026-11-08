# Стенд

LiteLLM, Bifrost и new-api на одном сервере в профилях `bare`, `prod`
и `keys`. Меряется TTFT, пропускная способность, память, поведение при
отказах апстрима и что лежит в логах и БД.

Публичные бенчмарки гейтвеев сняты без логирования и учёта расходов,
поэтому тут интереснее не кто быстрее, а сколько каждый теряет между
`bare` и `prod`/`keys`.

## Нужно

- Linux и docker (compose не нужен)
- curl, jq, awk, python3
- интернет для образов

Все контейнеры в host-сети, так что гейтвеи поднимаются по одному.

## Порты

| что | порт |
|---|---|
| mock-a | 9000 |
| mock-b (фолбэк) | 9010 |
| LiteLLM | 4000 |
| Bifrost | 8080 |
| new-api | 3000 |
| Postgres для LiteLLM | 55432 |

## Запуск

```bash
./gateways/bifrost/offline/fetch.sh   # один раз, прайсинг для bifrost
./run.sh prepare
./run.sh control
./run.sh saturate

./run.sh up       bifrost bare
./run.sh bench    bifrost bare
./run.sh faults   bifrost
./run.sh fallback bifrost
./run.sh security bifrost bare
./run.sh down     bifrost

# или все три гейтвея разом
./run.sh all bare
./run.sh all prod
./run.sh all keys

./run.sh report   # results/REPORT.md
```

Всё пишется в `results/`.

## Профили

| профиль | что включено |
|---|---|
| `bare` | только прокси, как в вендорских бенчмарках |
| `prod` | журнал запросов и расходы в БД |
| `keys` | то же плюс виртуальные ключи с бюджетом |
| `fallback` | два апстрима, только для `./run.sh fallback` |

Ключи клиента: LiteLLM в `bare` и `prod` ходит мастер-ключом, в `keys`
ключом `BENCH_VK`, его создает `run.sh up` через `/key/generate`. Bifrost
с `config_store` (prod, keys, fallback) без виртуального ключа не пускает,
так что ему `BENCH_VK` нужен везде кроме `bare`. Без хранилища он пускает
вообще без ключа. new-api всегда со своим токеном из `seed.sh`.

У мока нет цены в каталогах, поэтому она задана руками в `config.keys.yaml`
и в `pricing_overrides` у Bifrost: 1 и 2 доллара за миллион токенов.

Одинакового `bare` у них нет. У LiteLLM учёт включается вместе с
`DATABASE_URL`, у Bifrost через `client.enable_logging` и сторы, а new-api
без учёта не работает вообще.

## Мок

Профиль задается именем модели, свои заголовки гейтвеи не пропускают.

| модель | TTFT | на токен | токенов | всего |
|---|---|---|---|---|
| `mock-fast` | 20 мс | 2 мс | 64 | ~148 мс |
| `mock-realistic` | 400 мс | 33 мс | 150 | ~5.35 с |

Отказы, каждый N-й запрос:

```bash
curl -X POST http://127.0.0.1:9000/control -d '{"mode":"503","rate":0.25}'
curl -X POST http://127.0.0.1:9000/control -d '{"mode":"none"}'
```

Режимы `none`, `429`, `503`, `timeout`, `truncate` (рвет стрим на середине
без `finish_reason` и `[DONE]`).

id у каждого ответа свой. С одинаковым LiteLLM складывал все запросы в одну
строку `SpendLogs`.

## Нагрузчик

curl и обычные нагрузчики считают время до заголовков, на моке это 0.5 мс
при настроенных 20. Поэтому TTFT считается до первого непустого
`delta.content`. Каждый замер повторяется, в отчете медиана и min-max.

```bash
CONC=8 CONC_HI=64 REQS=120 REPEATS=5 REQS_SLOW=48 REPEATS_SLOW=3 ./run.sh all bare
```

Нагрузка закрытая: `CONC_HI` клиентов шлют запросы подряд. При ответе
~160 мс потолок около `CONC_HI / 0.16` rps, и на 64 Go-гейтвеи упираются
в мок, а не в CPU (контроль 304 rps, Bifrost 298, CPU 36-55%). Чтобы
нагрузить гейтвей, поднимайте `CONC_HI` и сверяйтесь с `saturate`.

## Ядра

- `GW_CPUS`: cpuset для гейтвея, например `0-3`, если нагрузчик на той же машине.
- `LITELLM_WORKERS`: по умолчанию по числу ядер. Сам LiteLLM стартует с одним.

На VDS не нужно, нагрузчик там на втором сервере.

## Маркеры

В `sentinels.env` ключ апстрима, мастер-ключ и виртуальный ключ с
нетипичными значениями. `security` ищет их и текст промпта в логах и БД.
Ключи ненастоящие.

## Чего нет

- Rust-версии LiteLLM: образа нет, и стриминг `/chat/completions` она не держит.
- Portkey Gateway: ставится через `npx`, OSS-репозиторий не обновлялся с 25.05.2026.
- Plano: это про оркестрацию агентов, другая задача.
