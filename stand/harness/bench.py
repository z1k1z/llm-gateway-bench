#!/usr/bin/env python3
"""Харнесс нагрузки для замера LLM-гейтвеев.

Считает то, чего нет в вендорских бенчмарках: TTFT по первому непустому
токену, а не по заголовкам ответа. Стандартные нагрузчики мерят время до
заголовков, которые и гейтвей, и провайдер отдают сразу, — поэтому TTFT
у них всегда выходит близким к нулю и ни о чём не говорит.

Каждый замер повторяется N раз. В отчёт идёт медиана по повторам и разброс
min-max: один прогон публиковать нельзя.
"""

import argparse
import asyncio
import json
import os
import platform
import socket
import statistics
import sys
import time
from datetime import datetime, timezone

import httpx

PROMPT = (
    "Опиши в двух абзацах, зачем в инфраструктуре нужен прокси "
    "перед языковой моделью и какие метрики у него важны."
)


def percentile(values, q):
    """Перцентиль по методу nearest-rank. Пустой список -> None."""
    if not values:
        return None
    s = sorted(values)
    if len(s) == 1:
        return s[0]
    k = max(0, min(len(s) - 1, int(round((q / 100.0) * (len(s) - 1)))))
    return s[k]


class Result:
    __slots__ = ("ttft", "total", "inter", "status", "err", "tokens")

    def __init__(self, ttft, total, inter, status, err, tokens):
        self.ttft = ttft
        self.total = total
        self.inter = inter
        self.status = status
        self.err = err
        self.tokens = tokens


async def call_stream(client, url, model, key, timeout):
    t0 = time.perf_counter()
    ttft = None
    marks = []
    status = None
    err = None
    payload = {
        "model": model,
        "stream": True,
        "stream_options": {"include_usage": True},
        "messages": [{"role": "user", "content": PROMPT}],
    }
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    try:
        async with client.stream(
            "POST", url, json=payload, headers=headers, timeout=timeout
        ) as r:
            status = r.status_code
            if r.status_code != 200:
                body = await r.aread()
                err = f"http {r.status_code}: {body[:160].decode('utf-8', 'replace')}"
            else:
                async for line in r.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data = line[6:].strip()
                    if data == "[DONE]":
                        break
                    try:
                        obj = json.loads(data)
                    except ValueError:
                        continue
                    choices = obj.get("choices") or []
                    if not choices:
                        continue
                    piece = (choices[0].get("delta") or {}).get("content") or ""
                    if not piece:
                        continue
                    now = time.perf_counter()
                    if ttft is None:
                        ttft = now - t0
                    marks.append(now)
    except Exception as exc:  # обрыв стрима, таймаут, отказ соединения
        err = f"{type(exc).__name__}: {str(exc)[:160]}"
    total = time.perf_counter() - t0
    inter = [(b - a) for a, b in zip(marks, marks[1:])]
    return Result(ttft, total, inter, status, err, len(marks))


async def call_complete(client, url, model, key, timeout):
    t0 = time.perf_counter()
    status = None
    err = None
    tokens = 0
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": PROMPT}],
    }
    headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
    try:
        r = await client.post(url, json=payload, headers=headers, timeout=timeout)
        status = r.status_code
        if r.status_code != 200:
            err = f"http {r.status_code}: {r.text[:160]}"
        else:
            body = r.json()
            tokens = (body.get("usage") or {}).get("completion_tokens") or 0
    except Exception as exc:
        err = f"{type(exc).__name__}: {str(exc)[:160]}"
    return Result(None, time.perf_counter() - t0, [], status, err, tokens)


async def run_shard(url, model, key, mode, timeout, concurrency, count):
    """Закрытая модель нагрузки: ровно `concurrency` воркеров до `count` запросов."""
    limits = httpx.Limits(
        max_connections=concurrency + 4,
        max_keepalive_connections=concurrency + 4,
    )
    call = call_stream if mode == "stream" else call_complete
    results = []
    issued = 0
    lock = asyncio.Lock()

    async with httpx.AsyncClient(limits=limits, http2=False) as client:

        async def worker():
            nonlocal issued
            while True:
                async with lock:
                    if issued >= count:
                        return
                    issued += 1
                results.append(await call(client, url, model, key, timeout))

        await asyncio.gather(*[worker() for _ in range(concurrency)])

    # Кортежи, а не объекты: между процессами это уходит через pickle.
    return [(r.ttft, r.total, r.inter, r.status, r.err, r.tokens) for r in results]


def _shard_entry(payload):
    return asyncio.run(run_shard(*payload))


def run_batch(args, count):
    """Разбивает нагрузку на `processes` процессов.

    Один процесс Python упирается в разбор SSE примерно на 300 rps: при 68
    событиях на запрос это около 19 тысяч разборов JSON в секунду. Если
    нагрузчик сам стал узким местом, замер показывает его потолок, а не
    потолок гейтвея — именно на этом горят публичные бенчмарки. Поэтому
    процессов несколько, а перед публикацией чисел пропускной способности
    надо проверить командой saturate, что у контрольной группы есть запас
    над лучшим из гейтвеев.
    """
    procs = max(1, args.processes)
    url = args.url.rstrip("/") + "/chat/completions"
    per_conc = max(1, args.concurrency // procs)
    per_count = max(1, count // procs)
    payload = (url, args.model, args.api_key, args.mode,
               args.timeout, per_conc, per_count)

    t0 = time.perf_counter()
    if procs == 1:
        shards = [_shard_entry(payload)]
    else:
        import multiprocessing as mp

        with mp.get_context("spawn").Pool(procs) as pool:
            shards = pool.map(_shard_entry, [payload] * procs)
    wall = time.perf_counter() - t0

    return [Result(*t) for shard in shards for t in shard], wall


def summarize(results, wall):
    ok = [r for r in results if r.err is None]
    ttfts = [r.ttft * 1000 for r in ok if r.ttft is not None]
    totals = [r.total * 1000 for r in ok]
    inters = [d * 1000 for r in ok for d in r.inter]
    statuses = {}
    for r in results:
        key = str(r.status) if r.status is not None else "conn_error"
        statuses[key] = statuses.get(key, 0) + 1
    errs = {}
    for r in results:
        if r.err:
            short = r.err.split(":")[0]
            errs[short] = errs.get(short, 0) + 1
    return {
        "requests": len(results),
        "ok": len(ok),
        "failed": len(results) - len(ok),
        "wall_s": round(wall, 3),
        "rps": round(len(results) / wall, 1) if wall > 0 else None,
        "statuses": statuses,
        "errors": errs,
        "tokens_median": statistics.median([r.tokens for r in ok]) if ok else None,
        "ttft_ms": {
            "p50": percentile(ttfts, 50),
            "p95": percentile(ttfts, 95),
            "p99": percentile(ttfts, 99),
            "n": len(ttfts),
        },
        "total_ms": {
            "p50": percentile(totals, 50),
            "p95": percentile(totals, 95),
            "p99": percentile(totals, 99),
        },
        "inter_token_ms": {
            "p50": percentile(inters, 50),
            "p95": percentile(inters, 95),
            "n": len(inters),
        },
    }


def aggregate(repeats):
    """Медиана по повторам плюс разброс min-max для каждой метрики."""
    out = {}
    for group in ("ttft_ms", "total_ms", "inter_token_ms"):
        out[group] = {}
        for stat in ("p50", "p95", "p99"):
            vals = [
                rep[group][stat]
                for rep in repeats
                if rep[group].get(stat) is not None
            ]
            if not vals:
                continue
            out[group][stat] = {
                "median": round(statistics.median(vals), 2),
                "min": round(min(vals), 2),
                "max": round(max(vals), 2),
            }
    rps = [r["rps"] for r in repeats if r["rps"] is not None]
    if rps:
        out["rps"] = {
            "median": round(statistics.median(rps), 1),
            "min": min(rps),
            "max": max(rps),
        }
    out["failed_total"] = sum(r["failed"] for r in repeats)
    out["requests_total"] = sum(r["requests"] for r in repeats)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True, help="база, например http://127.0.0.1:4000/v1")
    ap.add_argument("--model", required=True)
    ap.add_argument("--api-key", default=os.getenv("BENCH_API_KEY", "dummy"))
    ap.add_argument("--mode", choices=["stream", "complete"], default="stream")
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--requests", type=int, default=120)
    ap.add_argument("--repeats", type=int, default=5)
    ap.add_argument("--warmup", type=int, default=10)
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--processes", type=int, default=1,
                    help="процессов нагрузки; >1 нужно, когда один упирается в CPU")
    ap.add_argument("--label", required=True, help="например litellm/prod/stream")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.warmup > 0:
        run_batch(args, args.warmup)

    repeats = []
    for i in range(args.repeats):
        res, wall = run_batch(args, args.requests)
        s = summarize(res, wall)
        repeats.append(s)
        print(
            f"  повтор {i + 1}/{args.repeats}: "
            f"ok={s['ok']}/{s['requests']} rps={s['rps']} "
            f"ttft_p50={s['ttft_ms']['p50']} total_p50={s['total_ms']['p50']}",
            file=sys.stderr,
            flush=True,
        )

    report = {
        "label": args.label,
        "started_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "config": {
            "url": args.url,
            "model": args.model,
            "mode": args.mode,
            "concurrency": args.concurrency,
            "requests_per_repeat": args.requests,
            "repeats": args.repeats,
            "warmup": args.warmup,
            "processes": args.processes,
            "timeout_s": args.timeout,
        },
        "env": {
            "hostname": socket.gethostname(),
            "python": platform.python_version(),
            "cpu_count": os.cpu_count(),
        },
        "repeats_detail": repeats,
        "summary": aggregate(repeats),
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=2)
    print(f"-> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
