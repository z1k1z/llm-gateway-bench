#!/usr/bin/env python3
# python3 collect/report.py results > results/REPORT.md

import json
import os
import sys
from glob import glob

GATEWAYS = ["litellm", "bifrost", "newapi"]
PROFILES = ["bare", "prod", "keys"]
KINDS = ["fast", "realistic"]
MODES = ["stream", "complete"]


def load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError) as exc:
        print(f"<!-- не прочитан {path}: {exc} -->", file=sys.stderr)
        return None


def spread(node):
    if not node:
        return "—"
    return f"{node['median']:.1f} ({node['min']:.1f}–{node['max']:.1f})"


def metric(report, group, stat):
    if not report:
        return None
    return (report.get("summary", {}).get(group) or {}).get(stat)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "results"

    control = {}
    for mode in MODES:
        for kind in KINDS:
            control[(mode, kind)] = load(
                os.path.join(root, f"control-direct-{mode}-{kind}.json")
            )

    bench = {}
    for gw in GATEWAYS:
        for pr in PROFILES:
            for mode in MODES:
                for kind in KINDS:
                    p = os.path.join(root, f"bench-{gw}-{pr}-{mode}-{kind}.json")
                    if os.path.exists(p):
                        bench[(gw, pr, mode, kind)] = load(p)
            p = os.path.join(root, f"bench-{gw}-{pr}-throughput-fast.json")
            if os.path.exists(p):
                bench[(gw, pr, "throughput", "fast")] = load(p)

    out = []
    out.append("# Результаты стенда\n")

    # контрольная группа
    out.append("## Контрольная группа: напрямую в мок, без гейтвея\n")
    out.append("| режим | профиль мока | TTFT p50, мс | total p50, мс | RPS |")
    out.append("|---|---|---|---|---|")
    for mode in MODES:
        for kind in KINDS:
            r = control[(mode, kind)]
            if not r:
                continue
            out.append(
                f"| {mode} | {kind} | {spread(metric(r, 'ttft_ms', 'p50'))} "
                f"| {spread(metric(r, 'total_ms', 'p50'))} "
                f"| {spread(r['summary'].get('rps'))} |"
            )
    out.append("")

    # главная таблица: профили против гейтвеев
    out.append("## TTFT на стриминге: bare против prod против keys\n")
    out.append(
        "Главное число статьи. Если разница между профилями одного гейтвея "
        "больше разницы между гейтвеями, значит публичные бенчмарки "
        "в профиле bare измеряют не то, что ставят в прод.\n"
    )
    for kind in KINDS:
        ctl = metric(control[("stream", kind)], "ttft_ms", "p50")
        base = ctl["median"] if ctl else None
        out.append(f"### Профиль мока `{kind}`\n")
        out.append(
            "| гейтвей | профиль | TTFT p50, мс | TTFT p95, мс | +к контролю, мс "
            "| между токенами p95, мс |"
        )
        out.append("|---|---|---|---|---|---|")
        if base is not None:
            itok = metric(control[("stream", kind)], "inter_token_ms", "p95")
            out.append(
                f"| контроль | — | {spread(ctl)} "
                f"| {spread(metric(control[('stream', kind)], 'ttft_ms', 'p95'))} "
                f"| 0 | {spread(itok)} |"
            )
        for gw in GATEWAYS:
            for pr in PROFILES:
                r = bench.get((gw, pr, "stream", kind))
                if not r:
                    continue
                p50 = metric(r, "ttft_ms", "p50")
                p95 = metric(r, "ttft_ms", "p95")
                added = (
                    f"{p50['median'] - base:+.1f}" if (p50 and base is not None) else "—"
                )
                out.append(
                    f"| {gw} | {pr} | {spread(p50)} | {spread(p95)} | {added} "
                    f"| {spread(metric(r, 'inter_token_ms', 'p95'))} |"
                )
        out.append("")

    # нестриминг
    out.append("## Полное время ответа, нестриминг\n")
    out.append("| гейтвей | профиль | профиль мока | total p50, мс | total p99, мс |")
    out.append("|---|---|---|---|---|")
    for gw in GATEWAYS:
        for pr in PROFILES:
            for kind in KINDS:
                r = bench.get((gw, pr, "complete", kind))
                if not r:
                    continue
                out.append(
                    f"| {gw} | {pr} | {kind} | {spread(metric(r, 'total_ms', 'p50'))} "
                    f"| {spread(metric(r, 'total_ms', 'p99'))} |"
                )
    out.append("")

    # пропускная способность и память
    out.append("## Пропускная способность и память\n")
    out.append(
        "Если RPS гейтвея близок к контролю, упёрлись в нагрузчик, а не в "
        "гейтвей: такое число публиковать нельзя (см. `run.sh saturate`).\n"
    )
    out.append(
        "| гейтвей | профиль | RPS | TTFT p50, мс | отказов | CPU под нагрузкой "
        "| память в покое | память под нагрузкой |"
    )
    out.append("|---|---|---|---|---|---|---|---|")
    ctl = load(os.path.join(root, "control-direct-throughput-fast.json"))
    if ctl:
        cs = ctl["summary"]
        out.append(
            f"| контроль | — | {spread(cs.get('rps'))} "
            f"| {spread(metric(ctl, 'ttft_ms', 'p50'))} "
            f"| {cs.get('failed_total', 0)}/{cs.get('requests_total', 0)} | — | — | — |"
        )
    for gw in GATEWAYS:
        for pr in PROFILES:
            r = bench.get((gw, pr, "throughput", "fast"))
            if not r:
                continue
            s = r["summary"]
            idle = load(os.path.join(root, f"stats-{gw}-{pr}-idle.json")) or {}
            under = load(os.path.join(root, f"stats-{gw}-{pr}-load.json")) or {}
            failed = f"{s.get('failed_total', 0)}/{s.get('requests_total', 0)}"
            out.append(
                f"| {gw} | {pr} | {spread(s.get('rps'))} "
                f"| {spread(metric(r, 'ttft_ms', 'p50'))} | {failed} "
                f"| {under.get('cpu', '—')} "
                f"| {idle.get('mem', '—')} | {under.get('mem', '—')} |"
            )
    out.append("")

    # отказы
    faults = sorted(glob(os.path.join(root, "faults-*.json")))
    if faults:
        out.append("## Поведение при отказах апстрима\n")
        out.append(
            "При обрыве апстрим успевает отдать 32 токена из 64. Код всегда 200: "
            "заголовки уже ушли, и об обрыве клиент узнаёт только по хвосту стрима.\n"
        )
        out.append("| гейтвей | сценарий | код клиенту | токенов дошло | [DONE] | событие ошибки | секунд |")
        out.append("|---|---|---|---|---|---|---|")
        for path in faults:
            gw = os.path.basename(path)[len("faults-") : -len(".json")]
            for row in load(path) or []:
                yn = lambda v: "—" if v is None else ("да" if v else "нет")
                out.append(
                    f"| {gw} | {row['mode']} | {row['http_code']} "
                    f"| {row.get('content_tokens', '—')} | {yn(row.get('done_marker'))} "
                    f"| {yn(row.get('error_event'))} | {row['seconds']} |"
                )
        out.append("")

    # фолбэк
    fbs = sorted(glob(os.path.join(root, "fallback-*.json")))
    if fbs:
        out.append("## Фолбэк mock-a → mock-b\n")
        out.append("| гейтвей | отказ основного | код клиенту | ответил | секунд |")
        out.append("|---|---|---|---|---|")
        for path in fbs:
            gw = os.path.basename(path)[len("fallback-") : -len(".json")]
            for row in load(path) or []:
                out.append(
                    f"| {gw} | {row['scenario']} | {row['http_code']} "
                    f"| {row['answered_by']} | {row['seconds']} |"
                )
        out.append("")

    # безопасность
    sec = sorted(glob(os.path.join(root, "security-*.json")))
    if sec:
        out.append("## Безопасность из коробки\n")
        out.append(
            "| гейтвей | профиль | подпись образа | в логах: апстрим / клиент / VK / промпт "
            "| в БД: апстрим / клиент / VK / промпт | слушает все интерфейсы "
            "| без ключа отдают JSON |"
        )
        out.append("|---|---|---|---|---|---|---|")
        for path in sec:
            r = load(path)
            if not r:
                continue
            sig = r.get("signature", {})
            logs = r.get("logs", {})
            db = r.get("database", {}).get("scanned") or []
            def hits(rows, key):
                return sum(x.get(key, 0) for x in rows)

            keys = ["upstream_key_hits", "client_key_hits", "virtual_key_hits", "prompt_hits"]
            in_logs = " / ".join(str(logs.get(k, "—")) for k in keys)
            in_db = " / ".join(str(hits(db, k)) for k in keys) if db else "базы нет"
            exp = r.get("exposure", {})
            signed = "да" if sig.get("signed") else "нет"
            if sig.get("signed") and sig.get("method"):
                signed = f"да ({sig['method']})"
            open_paths = ", ".join(
                f"{u['path']}" for u in exp.get("unauthenticated", [])
                if str(u.get("code", "")).startswith("2") and u.get("json", True)
            ) or "—"
            wide = exp.get("bound_to_all_interfaces")
            wide = "да" if wide else ("нет" if wide == 0 else "—")
            out.append(
                f"| {r['gateway']} | {r['profile']} | {signed} | {in_logs} | {in_db} "
                f"| {wide} | {open_paths} |"
            )
        out.append("")
        out.append(
            "Числа в колонках утечек: сколько раз маркер встретился открытым текстом "
            "(в БД считаются и файлы WAL). 0 значит, что открытым текстом его там нет: "
            "хеш или шифрование grep не находит.\n"
        )

    print("\n".join(out))


if __name__ == "__main__":
    main()
