#!/usr/bin/env python3
import json
import os
import platform
import socket
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

DEFAULT_CONFIG = "/etc/log-analyt-agent/config.json"
VERSION = "0.1.0"


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
        headers={"Content-Type": "application/json"},
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


def sample_events(config: dict) -> list:
    watch_list = config.get("watch", [])
    log_file = watch_list[0] if watch_list else "access.log"
    return [
        {
            "event_time": now_iso(),
            "log_file": log_file,
            "source_type": config.get("source_type", "nginx_access"),
            "source_ip": "127.0.0.1",
            "method": "GET",
            "path": "/agent/ping",
            "status_code": 200,
            "ua": f"log-analyt-agent/{VERSION}",
            "ua_family": "Agent",
            "extra_json": {
                "mode": "bootstrap_sample"
            }
        }
    ]


def ingest_payload(config: dict) -> dict:
    return {
        "server_uuid": config["server_uuid"],
        "agent_key": config["agent_key"],
        "events": sample_events(config),
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
        payload = heartbeat_payload(config)
        try:
            response = post_json(heartbeat_url, payload)
            print(f"[log-analyt-agent] heartbeat ok: {response}")
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            print(f"[log-analyt-agent] heartbeat http_error status={e.code} body={body}", file=sys.stderr)
        except Exception as e:
            print(f"[log-analyt-agent] heartbeat failed: {e}", file=sys.stderr)

        try:
            response = post_json(ingest_url, ingest_payload(config))
            print(f"[log-analyt-agent] ingest ok: {response}")
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", errors="replace")
            print(f"[log-analyt-agent] ingest http_error status={e.code} body={body}", file=sys.stderr)
        except Exception as e:
            print(f"[log-analyt-agent] ingest failed: {e}", file=sys.stderr)

        time.sleep(interval)


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_CONFIG
    sys.exit(run(path))
