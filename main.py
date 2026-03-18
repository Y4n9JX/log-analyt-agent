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
VERSION = "0.1.0"
LOG_PATTERN = re.compile(
    r'(?P<source_ip>\S+) \S+ \S+ \[(?P<time_local>[^\]]+)\] '
    r'"(?P<method>\S+) (?P<path>\S+) (?P<protocol>[^"]+)" '
    r'(?P<status_code>\d{3}) \S+ "(?P<referer>[^"]*)" "(?P<ua>[^"]*)"'
)


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


def heartbeat_payload(config: dict) -> dict:
    return {
        "server_uuid": config["server_uuid"],
        "agent_key": config["agent_key"],
        "agent_version": VERSION,
        "hostname": hostname(),
        "os": platform.platform(),
        "source_type": config.get("source_type", "nginx_access"),
        "parser_name": config.get("parser_name", "nginx_combined"),
        "sent_at": now_iso(),
    }


def load_state() -> dict:
    p = Path(STATE_PATH)
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state: dict) -> None:
    p = Path(STATE_PATH)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


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


def parse_nginx_line(line: str, log_file: str, source_type: str) -> dict | None:
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
        "extra_json": {
            "referer": gd.get("referer", ""),
        },
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

        file_key = str(path)
        prev_offset = int(files_state.get(file_key, 0))
        current_size = path.stat().st_size
        if prev_offset > current_size:
            prev_offset = 0

        with path.open("r", encoding="utf-8", errors="replace") as f:
            f.seek(prev_offset)
            for line in f:
                parsed = parse_nginx_line(line, file_key, source_type)
                if parsed:
                    events.append(parsed)
            files_state[file_key] = f.tell()

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
        payload = heartbeat_payload(config)
        try:
            response = post_json(heartbeat_url, payload)
            print(f"[log-analyt-agent] heartbeat ok: {response}")
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            print(f"[log-analyt-agent] heartbeat http_error status={e.code} body={body}", file=sys.stderr)
        except Exception as e:
            print(f"[log-analyt-agent] heartbeat failed: {e}", file=sys.stderr)

        events = collect_events(config, state)
        if events:
            try:
                response = post_json(ingest_url, ingest_payload(config, events))
                print(f"[log-analyt-agent] ingest ok: {response}")
                save_state(state)
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8", errors="replace")
                print(f"[log-analyt-agent] ingest http_error status={e.code} body={body}", file=sys.stderr)
            except Exception as e:
                print(f"[log-analyt-agent] ingest failed: {e}", file=sys.stderr)
        else:
            print("[log-analyt-agent] no new log events")

        time.sleep(interval)


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CONFIG
    sys.exit(run(path))
