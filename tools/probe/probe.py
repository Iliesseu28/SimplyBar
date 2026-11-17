#!/usr/bin/env python3
"""Week-long probe of SimplyBar on this Mac, run every minute by launchd (see install.sh).

Each run stores one row: what SimplyBar costs (its app and widget processes) and what the system really shows
(CPU, RAM, disk, network, GPU, Keep Awake). Once an hour it also copies SimplyBar's own log lines (category
"probe", errors), WidgetKit's budget decisions about its widgets, new crash reports and the Bluetooth battery
levels. report.py turns the database into a report. Standard library only; stops by itself after the end date.
"""
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path

DATA = Path(os.environ.get("SIMPLYBAR_PROBE_DIR", Path.home() / "Library/Application Support/SimplyBarProbe"))
DB = DATA / "probe.sqlite"
CONFIG = DATA / "config.json"
APP = "/SimplyBar.app/Contents/MacOS/SimplyBar"
EXTENSION = "/SimplyBarWidgets.appex/Contents/MacOS/SimplyBarWidgets"
LOG_PREDICATE = (
    'subsystem == "fr.simplibot.simplybar" '
    'OR ((process == "SimplyBar" OR process == "SimplyBarWidgets") AND (messageType == error OR messageType == fault)) '
    'OR (process == "chronod" AND eventMessage CONTAINS "fr.simplibot.simplybar" '
    'AND (eventMessage CONTAINS[c] "budget" OR eventMessage CONTAINS[c] "throttl" OR eventMessage CONTAINS[c] "exempt"))'
)
SCHEMA = """
CREATE TABLE IF NOT EXISTS samples (
    ts INTEGER PRIMARY KEY, probe_ms INTEGER,
    app_pid INTEGER, app_cpu_s REAL, app_rss_kb INTEGER, app_cpu_pct REAL, app_idlew INTEGER, app_power REAL,
    ext_pid INTEGER, ext_cpu_s REAL, ext_rss_kb INTEGER, ext_cpu_pct REAL, ext_idlew INTEGER, ext_power REAL,
    sys_cpu REAL, ram_used INTEGER, ram_total INTEGER, mem_free_pct INTEGER, disk_free INTEGER,
    net_in INTEGER, net_out INTEGER, gpu REAL, awake INTEGER, thermal TEXT, volumes INTEGER
);
CREATE TABLE IF NOT EXISTS logs (
    ts TEXT, process TEXT, category TEXT, level TEXT, message TEXT, UNIQUE (ts, process, message)
);
CREATE TABLE IF NOT EXISTS crashes (name TEXT PRIMARY KEY, ts INTEGER);
CREATE TABLE IF NOT EXISTS bluetooth (ts INTEGER PRIMARY KEY, levels TEXT);
CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT);
"""


def run(*args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def cpu_seconds(text):
    """ps TIME ("1:02.34", "1:02:03.45" or "2-01:02:03") to seconds."""
    days, _, rest = text.rpartition("-")
    total = 0.0
    for part in rest.split(":"):
        total = total * 60 + float(part)
    return total + (int(days) * 86400 if days else 0)


def processes():
    found = {}
    for line in run("ps", "-axo", "pid=,rss=,time=,comm=").splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        for key, suffix in (("app", APP), ("ext", EXTENSION)):
            if parts[3].endswith(suffix):
                found[key] = {"pid": int(parts[0]), "rss_kb": int(parts[1]), "cpu_s": cpu_seconds(parts[2])}
    return found


def top(found):
    """System CPU, and %CPU, idle wakeups and energy impact of SimplyBar's processes (second of two samples)."""
    args = ["top", "-l", "2", "-s", "1", "-n", "5", "-stats", "pid,cpu,idlew,power"]
    for info in found.values():
        args += ["-pid", str(info["pid"])]
    output = run(*args).split("Processes:")
    last = output[-1] if len(output) > 1 else ""
    busy = None
    match = re.search(r"CPU usage: ([\d.]+)% user, ([\d.]+)% sys", last)
    if match:
        busy = float(match.group(1)) + float(match.group(2))
    rows = {}
    for line in last.splitlines():
        parts = line.split()
        if len(parts) == 4 and parts[0].isdigit():
            try:
                rows[int(parts[0])] = (float(parts[1]), int(parts[2]), float(parts[3]))
            except ValueError:
                pass
    return busy, rows


def memory():
    """Used RAM as Activity Monitor counts it (app + wired + compressed), total, and the free percentage."""
    text = run("vm_stat")
    page = int(re.search(r"page size of (\d+)", text).group(1)) if "page size" in text else 16384

    def pages(label):
        match = re.search(re.escape(label) + r":\s+(\d+)", text)
        return int(match.group(1)) if match else 0

    app = max(0, pages("Anonymous pages") - pages("Pages purgeable"))
    used = (app + pages("Pages wired down") + pages("Pages occupied by compressor")) * page
    total = int(run("sysctl", "-n", "hw.memsize").strip() or 0)
    match = re.search(r"free percentage: (\d+)%", run("memory_pressure", "-Q"))
    return used, total, int(match.group(1)) if match else None


def network():
    """Bytes received and sent since boot on the en* interfaces (one link row each)."""
    received = sent = 0
    for line in run("netstat", "-ib").splitlines():
        parts = line.split()
        if len(parts) >= 10 and parts[0].startswith("en") and parts[2].startswith("<Link#"):
            try:
                received += int(parts[-5])
                sent += int(parts[-2])
            except ValueError:
                pass
    return received, sent


def gpu():
    values = [int(v) for v in re.findall(r'"Device Utilization %"=(\d+)', run("ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"))]
    return max(values) if values else None


def thermal():
    text = run("pmset", "-g", "therm")
    match = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", text)
    if match:
        return "limit" + match.group(1)
    return "warning" if "warning level" in text and "No thermal warning" not in text else "nominal"


def sample(db):
    started = time.monotonic()
    found = processes()
    busy, rows = top(found)
    used, total, free_pct = memory()
    received, sent = network()
    stat = os.statvfs("/")
    awake = 1 if "SimplyBar: Keep Awake" in run("pmset", "-g", "assertions") else 0
    volumes = len([name for name in os.listdir("/Volumes") if not name.startswith(".")]) if os.path.isdir("/Volumes") else None
    values = {"ts": int(time.time())}
    for key in ("app", "ext"):
        info = found.get(key)
        stats = rows.get(info["pid"]) if info else None
        values.update({
            f"{key}_pid": info and info["pid"], f"{key}_cpu_s": info and info["cpu_s"], f"{key}_rss_kb": info and info["rss_kb"],
            f"{key}_cpu_pct": stats and stats[0], f"{key}_idlew": stats and stats[1], f"{key}_power": stats and stats[2],
        })
    values.update({
        "sys_cpu": busy, "ram_used": used, "ram_total": total, "mem_free_pct": free_pct,
        "disk_free": stat.f_bavail * stat.f_frsize, "net_in": received, "net_out": sent, "gpu": gpu(),
        "awake": awake, "thermal": thermal(), "volumes": volumes,
    })
    values["probe_ms"] = int((time.monotonic() - started) * 1000)
    columns = ", ".join(values)
    db.execute(f"INSERT OR REPLACE INTO samples ({columns}) VALUES ({', '.join('?' * len(values))})", list(values.values()))


def hourly(db, now):
    row = db.execute("SELECT value FROM state WHERE key = 'last_hourly'").fetchone()
    last = float(row[0]) if row else now - 3600
    if now - last < 55 * 60:
        return
    start = datetime.fromtimestamp(last - 120).strftime("%Y-%m-%d %H:%M:%S")
    output = run("/usr/bin/log", "show", "--style", "ndjson", "--start", start, "--predicate", LOG_PREDICATE, timeout=240)
    for line in output.splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if "eventMessage" not in entry:
            continue
        db.execute(
            "INSERT OR IGNORE INTO logs VALUES (?, ?, ?, ?, ?)",
            (entry.get("timestamp"), Path(entry.get("processImagePath", "")).name, entry.get("category", ""),
             entry.get("messageType", ""), entry["eventMessage"][:500]),
        )
    reports = Path.home() / "Library/Logs/DiagnosticReports"
    for path in list(reports.glob("SimplyBar*")) + list(reports.glob("Retired/SimplyBar*")):
        db.execute("INSERT OR IGNORE INTO crashes VALUES (?, ?)", (path.name, int(path.stat().st_mtime)))
    levels = re.findall(r'"BatteryPercent" = (\d+)', run("ioreg", "-r", "-k", "BatteryPercent", "-l"))
    db.execute("INSERT OR REPLACE INTO bluetooth VALUES (?, ?)", (int(now), ",".join(levels)))
    db.execute("INSERT OR REPLACE INTO state VALUES ('last_hourly', ?)", (str(now),))


def main():
    DATA.mkdir(parents=True, exist_ok=True)
    if not CONFIG.exists():
        start = datetime.now()
        CONFIG.write_text(json.dumps({"start": start.isoformat(timespec="seconds"),
                                      "end": (start + timedelta(days=7)).isoformat(timespec="seconds")}))
    end = datetime.fromisoformat(json.loads(CONFIG.read_text())["end"])
    if datetime.now() > end:
        return 0
    with sqlite3.connect(DB, timeout=30) as db:
        db.executescript(SCHEMA)
        sample(db)
        hourly(db, time.time())
    return 0


if __name__ == "__main__":
    sys.exit(main())
