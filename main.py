#!/usr/bin/env python3
import json
import os
import platform
import re
import socket
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_CONFIG = "/etc/log-analyt-agent/config.json"
STATE_PATH = "/opt/log-analyt-agent/state.json"
VERSION = "0.2.3"
METRICS_WINDOW_SECONDS = 180
LOG_PATTERN = re.compile(r'(?P<source_ip>\S+) \S+ \S+ \[(?P<time_local>[^\]]+)\] "(?P<method>\S+) (?P<path>\S+) (?P<protocol>[^"]+)" (?P<status_code>\d{3}) \S+ "(?P<referer>[^"]*)" "(?P<ua>[^"]*)"')


def load_config(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat()


def hostname() -> str:
    return socket.gethostname()


def post_json(url: str, payload: dict, timeout: int = 10) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": f"Log-Analyt-Agent/{VERSION}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8")
        return json.loads(body) if body else {"ok": True}


def read_uptime_seconds():
    try:
        with open('/proc/uptime', 'r', encoding='utf-8') as f:
            return int(float(f.read().split()[0]))
    except Exception:
        return None


def read_load_average():
    try:
        with open('/proc/loadavg', 'r', encoding='utf-8') as f:
            parts = f.read().strip().split()
        return {
            'load1': round(float(parts[0]), 2),
            'load5': round(float(parts[1]), 2),
            'load15': round(float(parts[2]), 2),
        }
    except Exception:
        return {
            'load1': None,
            'load5': None,
            'load15': None,
        }


def read_memory_percent():
    try:
        values = {}
        with open('/proc/meminfo', 'r', encoding='utf-8') as f:
            for line in f:
                key, value = line.split(':', 1)
                values[key] = int(value.strip().split()[0])
        total = values.get('MemTotal', 0)
        available = values.get('MemAvailable', values.get('MemFree', 0))
        if total <= 0:
            return None
        used_percent = (1 - (available / total)) * 100
        return round(max(0.0, min(100.0, used_percent)), 1)
    except Exception:
        return None


def read_cpu_snapshot():
    try:
        with open('/proc/stat', 'r', encoding='utf-8') as f:
            parts = f.readline().split()
        if not parts or parts[0] != 'cpu':
            return None
        values = [int(x) for x in parts[1:]]
        idle = values[3] + (values[4] if len(values) > 4 else 0)
        total = sum(values)
        return total, idle
    except Exception:
        return None


def read_cpu_percent(sample_seconds: float = 0.2):
    first = read_cpu_snapshot()
    if not first:
        return None
    time.sleep(sample_seconds)
    second = read_cpu_snapshot()
    if not second:
        return None
    total_delta = second[0] - first[0]
    idle_delta = second[1] - first[1]
    if total_delta <= 0:
        return None
    used_percent = (1 - (idle_delta / total_delta)) * 100
    return round(max(0.0, min(100.0, used_percent)), 1)


def load_state() -> dict:
    p = Path(STATE_PATH)
    if not p.exists():
        return {"files": {}, "metrics": []}
    try:
        state = json.loads(p.read_text(encoding="utf-8"))
        if not isinstance(state, dict):
            return {"files": {}, "metrics": []}
        state.setdefault("files", {})
        state.setdefault("metrics", [])
        return state
    except Exception:
        return {"files": {}, "metrics": []}


def save_state(state: dict) -> None:
    p = Path(STATE_PATH)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def average_metric(entries: list, key: str):
    values = [float(item[key]) for item in entries if item.get(key) is not None]
    if not values:
        return None
    return round(sum(values) / len(values), 1)


def capture_metrics(state: dict):
    now_ts = int(time.time())
    current = {
        "ts": now_ts,
        "cpu_percent": read_cpu_percent(),
        "memory_percent": read_memory_percent(),
    }
    metrics = state.setdefault("metrics", [])
    metrics.append(current)
    cutoff = now_ts - METRICS_WINDOW_SECONDS
    state["metrics"] = [item for item in metrics if int(item.get("ts", 0)) >= cutoff]
    averaged = {
        "cpu_percent": average_metric(state["metrics"], "cpu_percent"),
        "memory_percent": average_metric(state["metrics"], "memory_percent"),
    }
    return averaged


def heartbeat_payload(config: dict, metrics_avg: dict) -> dict:
    loadavg = read_load_average()
    return {
        "server_uuid": config["server_uuid"],
        "agent_key": config["agent_key"],
        "agent_version": VERSION,
        "hostname": hostname(),
        "os": platform.platform(),
        "source_type": config.get("source_type", "nginx_access"),
        "parser_name": config.get("parser_name", "nginx_combined"),
        "uptime_seconds": read_uptime_seconds(),
        "cpu_percent": metrics_avg.get("cpu_percent"),
        "memory_percent": metrics_avg.get("memory_percent"),
        "load1": loadavg.get("load1"),
        "load5": loadavg.get("load5"),
        "load15": loadavg.get("load15"),
        "sent_at": now_iso(),
    }


def parse_nginx_time(value: str) -> str:
    dt = datetime.strptime(value, "%d/%b/%Y:%H:%M:%S %z")
    return dt.isoformat()


def infer_ua_family(ua: str) -> str:
    text = (ua or "").lower()
    if "shadowrocket" in text:
        return "Shadowrocket"
    if "clash" in text:
        return "Clash"
    if "surge" in text:
        return "Surge"
    if "mozilla" in text:
        return "Browser"
    if "telegrambot" in text:
        return "TelegramBot"
    return "Other"


def parse_nginx_line(line: str, log_file: str, source_type: str):
    m = LOG_PATTERN.match(line.strip())
    if not m:
        return None
    gd = m.groupdict()
    return {
        "event_time": parse_nginx_time(gd["time_local"]),
        "log_file": log_file,
        "source_type": source_type,
        "source_ip": gd["source_ip"],
        "method": gd["method"],
        "path": gd["path"],
        "status_code": int(gd["status_code"]),
        "ua": gd["ua"],
        "ua_family": infer_ua_family(gd["ua"]),
        "extra_json": {"referer": gd.get("referer", "")},
    }


def collect_events(config: dict, state: dict) -> list:
    events = []
    watch_list = config.get("watch", [])
    source_type = config.get("source_type", "nginx_access")
    files_state = state.setdefault("files", {})

    for log_file in watch_list:
        path = Path(log_file)
        if not path.exists() or not path.is_file():
            continue

        key = str(path)
        prev_offset = int(files_state.get(key, 0))
        current_size = path.stat().st_size
        if prev_offset > current_size:
            prev_offset = 0

        with path.open("r", encoding="utf-8", errors="replace") as f:
            f.seek(prev_offset)
            for line in f:
                parsed = parse_nginx_line(line, key, source_type)
                if parsed:
                    events.append(parsed)
            files_state[key] = f.tell()
    return events


def ingest_payload(config: dict, events: list) -> dict:
    return {
        "server_uuid": config["server_uuid"],
        "agent_key": config["agent_key"],
        "events": events,
    }


def run(config_path: str) -> int:
    config = load_config(config_path)
    center_url = config["center_url"].rstrip("/")
    interval = int(config.get("interval_seconds", 15))
    heartbeat_url = center_url + "/api/agent/heartbeat.php"
    ingest_url = center_url + "/api/agent/ingest.php"

    print(f"[log-analyt-agent] start version={VERSION}")
    print(f"[log-analyt-agent] config={config_path}")
    print(f"[log-analyt-agent] heartbeat_url={heartbeat_url}")
    print(f"[log-analyt-agent] ingest_url={ingest_url}")

    while True:
        state = load_state()
        metrics_avg = capture_metrics(state)
        save_state(state)

        try:
            print(f"[log-analyt-agent] heartbeat ok: {post_json(heartbeat_url, heartbeat_payload(config, metrics_avg))}")
        except urllib.error.HTTPError as e:
            print(f"[log-analyt-agent] heartbeat http_error status={e.code} body={e.read().decode('utf-8', errors='replace')}", file=sys.stderr)
        except Exception as e:
            print(f"[log-analyt-agent] heartbeat failed: {e}", file=sys.stderr)

        events = collect_events(config, state)
        if events:
            try:
                print(f"[log-analyt-agent] ingest ok: {post_json(ingest_url, ingest_payload(config, events))}")
                save_state(state)
            except urllib.error.HTTPError as e:
                print(f"[log-analyt-agent] ingest http_error status={e.code} body={e.read().decode('utf-8', errors='replace')}", file=sys.stderr)
            except Exception as e:
                print(f"[log-analyt-agent] ingest failed: {e}", file=sys.stderr)
        else:
            print("[log-analyt-agent] no new log events")
        time.sleep(interval)


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CONFIG
    sys.exit(run(path))
