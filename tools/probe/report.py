#!/usr/bin/env python3
"""Turns the probe database into a Markdown report: what SimplyBar costs, whether its numbers match the system,
how fresh the widgets stay, what failed and what was used. Prints the report path. Standard library only."""
import json
import os
import re
import sqlite3
import statistics
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

DATA = Path(os.environ.get("SIMPLYBAR_PROBE_DIR", Path.home() / "Library/Application Support/SimplyBarProbe"))
GB = 1e9


def parse_ts(text):
    return datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


def fields(message):
    return dict(part.split("=", 1) for part in message.split() if "=" in part)


def median(values):
    return statistics.median(values) if values else None


def pct(values, q):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(q * len(ordered)))]


def fmt(value, digits=1, unit=""):
    return "n/a" if value is None else f"{value:.{digits}f}{unit}"


def slope_per_day(points):
    """Least-squares slope of (seconds, value) points, per day."""
    if len(points) < 10:
        return None
    xs, ys = zip(*points)
    mx, my = statistics.mean(xs), statistics.mean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return None if den == 0 else sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den * 86400


def cost(rows, key):
    """Average %CPU from cumulative CPU time, RSS trend and restarts of one process."""
    busy = wall = 0.0
    runs = defaultdict(list)
    previous = None
    for row in rows:
        pid, cpu_s, rss = row[f"{key}_pid"], row[f"{key}_cpu_s"], row[f"{key}_rss_kb"]
        if pid is None:
            previous = None
            continue
        runs[pid].append((row["ts"], rss / 1024))
        if previous and previous[0] == pid and 0 < row["ts"] - previous[1] < 600:
            busy += max(0.0, cpu_s - previous[2])
            wall += row["ts"] - previous[1]
        previous = (pid, row["ts"], cpu_s)
    rss = [value for points in runs.values() for _, value in points]
    longest = max(runs.values(), key=len) if runs else []
    power = [row[f"{key}_power"] for row in rows if row[f"{key}_power"] is not None]
    wakeups = [row[f"{key}_idlew"] for row in rows if row[f"{key}_idlew"] is not None]
    return {
        "cpu_avg": busy / wall * 100 if wall else None,
        "rss_first": longest[0][1] if longest else None, "rss_last": longest[-1][1] if longest else None,
        "rss_max": max(rss) if rss else None, "rss_slope": slope_per_day(longest),
        "runs": len(runs), "power": statistics.mean(power) if power else None,
        "wakeups": statistics.mean(wakeups) if wakeups else None,
    }


def main():
    db = sqlite3.connect(DATA / "probe.sqlite")
    db.row_factory = sqlite3.Row
    config = json.loads((DATA / "config.json").read_text())
    samples = db.execute("SELECT * FROM samples ORDER BY ts").fetchall()
    logs = db.execute("SELECT * FROM logs ORDER BY ts").fetchall()
    if not samples:
        sys.exit("No samples yet.")
    first, last = samples[0]["ts"], samples[-1]["ts"]
    hours = (last - first) / 3600
    out = [f"# Sonde SimplyBar : rapport du {datetime.now():%d/%m/%Y %H:%M}", ""]
    out += [f"Période : {datetime.fromtimestamp(first):%d/%m %H:%M} au {datetime.fromtimestamp(last):%d/%m %H:%M} "
            f"({hours:.1f} h, {len(samples)} mesures, couverture {len(samples) / max(1, hours * 60) * 100:.0f} %). "
            f"Fin prévue : {config['end']}.", ""]
    flags = []

    # 1. Cost
    out += ["## 1. Ce que SimplyBar coûte au Mac", "", "| Processus | CPU moyen | Impact énergie | Réveils/s | RAM début → fin (max) | Pente RAM | Relances |", "|---|---|---|---|---|---|---|"]
    for key, label in (("app", "App"), ("ext", "Widgets")):
        c = cost(samples, key)
        out.append(f"| {label} | {fmt(c['cpu_avg'], 2, ' %')} | {fmt(c['power'], 2)} | {fmt(c['wakeups'], 0)} | "
                   f"{fmt(c['rss_first'], 0)} → {fmt(c['rss_last'], 0)} Mo ({fmt(c['rss_max'], 0)}) | {fmt(c['rss_slope'], 1, ' Mo/j')} | {max(0, c['runs'] - 1)} |")
        if c["cpu_avg"] and c["cpu_avg"] > 0.5:
            flags.append(f"{label} : CPU moyen {c['cpu_avg']:.2f} % (> 0,5 %).")
        if c["rss_slope"] and c["rss_slope"] > 10:
            flags.append(f"{label} : la RAM monte de {c['rss_slope']:.0f} Mo par jour (fuite possible).")
        if c["wakeups"] and c["wakeups"] > 50:
            flags.append(f"{label} : {c['wakeups']:.0f} réveils par seconde en moyenne (batterie, énergie).")
    probe_ms = [row["probe_ms"] for row in samples if row["probe_ms"]]
    out += ["", f"La sonde elle-même : {fmt(median(probe_ms), 0)} ms par mesure (médiane), une fois par minute.", ""]

    # 2. Cost per module
    publishes = [(parse_ts(row["ts"]), fields(row["message"])) for row in logs if row["category"] == "probe" and row["message"].startswith("publish ")]
    per_module = defaultdict(lambda: [0, 0])
    for _, f in publishes:
        for item in filter(None, f.get("cost", "").split(",")):
            module, _, spec = item.partition(":")
            count, _, micro = spec.partition("x")
            per_module[module][0] += int(count)
            per_module[module][1] += int(micro)
    out += ["## 2. Coût de chaque lecture", "", "| Module | Lectures | Temps total | Par lecture |", "|---|---|---|---|"]
    for module, (count, micro) in sorted(per_module.items(), key=lambda item: -item[1][1]):
        out.append(f"| {module} | {count} | {micro / 1000:.0f} ms | {micro / max(1, count):.0f} µs |")
        if count and micro / count > 20000:
            flags.append(f"Lecture {module} : {micro / count / 1000:.0f} ms en moyenne (> 20 ms).")
    out += ["", "(Bluetooth : seul le lancement de la lecture est compté.)", ""]

    # 3. Accuracy
    by_ts = {row["ts"]: row for row in samples}
    stamps = sorted(by_ts)

    def nearest(ts):
        import bisect
        i = bisect.bisect_left(stamps, ts)
        best = min((stamps[j] for j in (i - 1, i) if 0 <= j < len(stamps)), key=lambda s: abs(s - ts), default=None)
        return by_ts[best] if best is not None and abs(best - ts) <= 90 else None

    diffs = defaultdict(list)
    for ts, f in publishes:
        row = nearest(ts)
        if not row:
            continue
        if "cpu" in f and row["sys_cpu"] is not None:
            diffs["CPU (points de %)"].append(abs(float(f["cpu"]) - row["sys_cpu"]))
        if "ram" in f and row["ram_used"]:
            diffs["RAM (Go)"].append(abs(int(f["ram"]) - row["ram_used"]) / GB)
        if "diskFree" in f and row["disk_free"]:
            diffs["Disque libre, app moins système (Go)"].append((int(f["diskFree"]) - row["disk_free"]) / GB)
        if "gpu" in f and row["gpu"] is not None:
            diffs["GPU (points de %)"].append(abs(float(f["gpu"]) - row["gpu"]))
        if "volumes" in f and row["volumes"] is not None:
            diffs["Disques, app moins /Volumes"].append(int(f["volumes"]) - row["volumes"])
    out += ["## 3. Justesse des chiffres (publication du widget contre le système, à 90 s près)", "",
            "| Mesure | Comparaisons | Écart médian | Écart à 90 % |", "|---|---|---|---|"]
    for name, values in diffs.items():
        out.append(f"| {name} | {len(values)} | {fmt(median(values), 2)} | {fmt(pct(values, 0.9), 2)} |")
    if diffs["RAM (Go)"] and median(diffs["RAM (Go)"]) > 0.3:
        flags.append(f"RAM : écart médian de {median(diffs['RAM (Go)']):.2f} Go avec le système.")
    out += ["", "Le disque de l'app compte aussi l'espace purgeable (écart positif attendu). Le CPU bouge vite : "
            "un écart de quelques points est normal.", ""]

    # 4. Freshness
    full = [ts for ts, f in publishes if f.get("only") == "all"]
    gaps = [b - a for a, b in zip(full, full[1:])]
    timelines = [(parse_ts(row["ts"]), fields(row["message"])) for row in logs if row["category"] == "probe" and row["message"].startswith("timeline ")]
    kinds = defaultdict(list)
    for _, f in timelines:
        kinds[f.get("kind", "?")].append(f)
    out += ["## 4. Fraîcheur des widgets", "",
            f"Publications complètes : {len(full)} ({len(full) / max(1, hours / 24):.0f} par jour), écart médian "
            f"{fmt(median(gaps) / 60 if gaps else None, 0, ' min')}, plus long {fmt(max(gaps) / 60 if gaps else None, 0, ' min')}, "
            f"{sum(g > 15 * 60 for g in gaps)} trous de plus de 15 min (le widget affichait alors « app arrêtée »).",
            f"Publications partielles (un seul widget) : {sum(1 for _, f in publishes if f.get('only') != 'all')}.", "",
            "| Widget | Redessins demandés par macOS | Par jour | Âge médian des chiffres | Âge max | Périmés |", "|---|---|---|---|---|---|"]
    for kind, items in sorted(kinds.items()):
        ages = [int(f["age"]) for f in items if f.get("age", "-1") != "-1"]
        stale = sum(1 for f in items if f.get("fresh") == "false")
        out.append(f"| {kind} | {len(items)} | {len(items) / max(1, hours / 24):.0f} | {fmt(median(ages) / 60 if ages else None, 0, ' min')} | "
                   f"{fmt(max(ages) / 60 if ages else None, 0, ' min')} | {stale} |")
        if ages and median(ages) > 7 * 60:
            flags.append(f"Widget {kind} : chiffres vieux de {median(ages) / 60:.0f} min en médiane quand macOS le redessine.")
    budget = Counter()
    for row in logs:
        if row["process"] == "chronod":
            for word in re.findall(r"budget exempt reason: \w+|throttled reload|budgeted: \w+ for reason: \w+", row["message"]):
                budget[word] += 1
    if budget:
        out += ["", "Décisions de WidgetKit sur le budget de rafraîchissement :", ""]
        out += [f"- {word} : {count}" for word, count in budget.most_common(8)]
    out.append("")

    # 5. Reliability
    crashes = db.execute("SELECT name FROM crashes WHERE ts >= ?", (first - 3600,)).fetchall()
    errors = Counter(re.sub(r"\d+", "#", row["message"])[:140] for row in logs
                     if row["process"] in ("SimplyBar", "SimplyBarWidgets") and row["level"] in ("Error", "Fault"))
    out += ["## 5. Fiabilité", "", f"Plantages : {len(crashes)}" + (f" ({', '.join(r['name'] for r in crashes[:5])})" if crashes else "") + ".",
            f"Erreurs et fautes dans le journal : {sum(errors.values())}.", ""]
    out += [f"- {count} × {message}" for message, count in errors.most_common(10)]
    if crashes:
        flags.append(f"{len(crashes)} plantage(s) : lire les rapports .ips.")
    out.append("")

    # 6. Usage
    popups = Counter(fields(row["message"]).get("module") for row in logs if row["category"] == "probe" and row["message"].startswith("popup "))
    diagnostics = sum(1 for row in logs if row["category"] == "diagnostic" and row["message"].startswith("Diagnostic done"))
    disks = sum(1 for row in logs if row["message"].startswith("Disks changed"))
    awake = [row["awake"] for row in samples if row["awake"] is not None]
    lastf = publishes[-1][1] if publishes else {}
    out += ["## 6. Usage", "",
            f"Barre de menus : {lastf.get('bar', 'n/a')}. Widgets posés : {lastf.get('widgets', 'n/a')}.",
            f"Fenêtres ouvertes : " + (", ".join(f"{m} {c}" for m, c in popups.most_common()) or "aucune") + ".",
            f"Diagnostics lancés : {diagnostics}. Disques branchés ou éjectés : {disks}. "
            f"Anti-veille actif : {fmt(sum(awake) / len(awake) * 100 if awake else None, 0, ' %')} du temps.", ""]

    out += ["## 7. Pistes repérées automatiquement", ""]
    out += [f"- {flag}" for flag in flags] or ["- Rien d'anormal selon les seuils de la sonde."]
    path = DATA / f"rapport-{datetime.now():%Y-%m-%d}.md"
    path.write_text("\n".join(out) + "\n")
    print(path)


if __name__ == "__main__":
    main()
