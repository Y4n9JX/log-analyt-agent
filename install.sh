#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=${LOGANALYT_INSTALL_DIR:-/opt/log-analyt-agent}
CONFIG_DIR=${LOGANALYT_CONFIG_DIR:-/etc/log-analyt-agent}
SERVICE_NAME=log-analyt-agent
CENTER_URL=${LOGANALYT_CENTER_URL:-}
SERVER_UUID=${LOGANALYT_SERVER_UUID:-}
AGENT_KEY=${LOGANALYT_AGENT_KEY:-}

for arg in "$@"; do
  case $arg in
    --center-url=*) CENTER_URL="${arg#*=}" ;;
    --server-uuid=*) SERVER_UUID="${arg#*=}" ;;
    --agent-key=*) AGENT_KEY="${arg#*=}" ;;
    --install-dir=*) INSTALL_DIR="${arg#*=}" ;;
    --config-dir=*) CONFIG_DIR="${arg#*=}" ;;
  esac
done

if [[ -z "$CENTER_URL" || -z "$SERVER_UUID" || -z "$AGENT_KEY" ]]; then
  echo "[log-analyt-agent] missing required values"
  echo "Need: LOGANALYT_CENTER_URL, LOGANALYT_SERVER_UUID, LOGANALYT_AGENT_KEY"
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"

cat > "$CONFIG_DIR/config.json" <<EOF
{
  "center_url": "$CENTER_URL",
  "server_uuid": "$SERVER_UUID",
  "agent_key": "$AGENT_KEY",
  "watch": ["/var/log/nginx/access.log"],
  "source_type": "nginx_access",
  "parser_name": "nginx_combined",
  "interval_seconds": 15
}
EOF

if ! command -v python3 >/dev/null 2>&1; then
  echo "[log-analyt-agent] python3 is required"
  exit 1
fi

SCRIPT_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/main.py"
if [[ ! -f "$SCRIPT_SOURCE" ]]; then
  echo "[log-analyt-agent] main.py not found next to install.sh"
  echo "Download both install.sh and main.py from GitHub before running install.sh"
  exit 1
fi

install -m 0755 "$SCRIPT_SOURCE" "$INSTALL_DIR/main.py"

cat > "$INSTALL_DIR/agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CONFIG_PATH=${1:-/etc/log-analyt-agent/config.json}
exec /usr/bin/env python3 /opt/log-analyt-agent/main.py "$CONFIG_PATH"
EOF
chmod +x "$INSTALL_DIR/agent.sh"

cat > /usr/local/bin/laa <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-status}
case "$cmd" in
  start) systemctl start log-analyt-agent ;;
  stop) systemctl stop log-analyt-agent ;;
  restart) systemctl restart log-analyt-agent ;;
  status) systemctl status log-analyt-agent --no-pager ;;
  logs) journalctl -u log-analyt-agent -n 100 --no-pager ;;
  uninstall)
    if [[ -x /tmp/log-analyt-agent/uninstall.sh ]]; then
      /tmp/log-analyt-agent/uninstall.sh
    elif [[ -x ./uninstall.sh ]]; then
      ./uninstall.sh
    else
      echo "uninstall.sh not found; download it from log-analyt-agent repo" >&2
      exit 1
    fi
    ;;
  *)
    echo "Usage: laa {start|stop|restart|status|logs|uninstall}" >&2
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/laa

if command -v systemctl >/dev/null 2>&1; then
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Log-Analyt Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/agent.sh $CONFIG_DIR/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  echo "[log-analyt-agent] service installed: $SERVICE_NAME"
else
  echo "[log-analyt-agent] systemctl not found, service file not installed"
fi

echo "[log-analyt-agent] install ok"
echo "install_dir=$INSTALL_DIR"
echo "config=$CONFIG_DIR/config.json"
echo "commands: laa status | laa restart | laa logs | laa uninstall"
