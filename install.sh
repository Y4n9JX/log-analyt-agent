#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=${LOGANALYT_INSTALL_DIR:-/opt/log-analyt-agent}
CONFIG_DIR=${LOGANALYT_CONFIG_DIR:-/etc/log-analyt-agent}
SERVICE_NAME=log-analyt-agent
CENTER_URL=${LOGANALYT_CENTER_URL:-}
SERVER_UUID=${LOGANALYT_SERVER_UUID:-}
AGENT_KEY=${LOGANALYT_AGENT_KEY:-}

prompt_if_missing() {
  if [[ -z "$CENTER_URL" ]]; then
    read -rp "请输入中心站地址 (如 https://tglog.99sla.de): " CENTER_URL
  fi
  if [[ -z "$SERVER_UUID" ]]; then
    read -rp "请输入 server_uuid: " SERVER_UUID
  fi
  if [[ -z "$AGENT_KEY" ]]; then
    read -rp "请输入 agent_key: " AGENT_KEY
  fi

  echo
  echo "安装信息确认："
  echo "- center_url: $CENTER_URL"
  echo "- server_uuid: $SERVER_UUID"
  echo "- agent_key: $AGENT_KEY"
  read -rp "是否继续安装？[Y/n]: " confirm
  confirm=${confirm:-Y}
  case "$confirm" in
    Y|y|yes|YES) ;;
    *)
      echo "[log-analyt-agent] cancelled"
      exit 1
      ;;
  esac
}

for arg in "$@"; do
  case $arg in
    --center-url=*) CENTER_URL="${arg#*=}" ;;
    --server-uuid=*) SERVER_UUID="${arg#*=}" ;;
    --agent-key=*) AGENT_KEY="${arg#*=}" ;;
    --install-dir=*) INSTALL_DIR="${arg#*=}" ;;
    --config-dir=*) CONFIG_DIR="${arg#*=}" ;;
  esac
done

prompt_if_missing

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
  echo "[log-analyt-agent] main.py not found next to install.sh, downloading..."
  curl -fsSL https://raw.githubusercontent.com/Y4n9JX/log-analyt-agent/main/main.py -o "$SCRIPT_SOURCE"
fi

UNINSTALL_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/uninstall.sh"
if [[ ! -f "$UNINSTALL_SOURCE" ]]; then
  echo "[log-analyt-agent] uninstall.sh not found next to install.sh, downloading..."
  curl -fsSL https://raw.githubusercontent.com/Y4n9JX/log-analyt-agent/main/uninstall.sh -o "$UNINSTALL_SOURCE"
  chmod +x "$UNINSTALL_SOURCE"
fi

install -m 0755 "$SCRIPT_SOURCE" "$INSTALL_DIR/main.py"
install -m 0755 "$UNINSTALL_SOURCE" "$INSTALL_DIR/uninstall.sh"

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

show_menu() {
  while true; do
    clear
    echo "请选择操作："
    echo
    echo "1. laa start"
    echo "   启动 agent"
    echo
    echo "2. laa stop"
    echo "   停止 agent"
    echo
    echo "3. laa restart"
    echo "   重启 agent"
    echo
    echo "4. laa status"
    echo "   看服务状态"
    echo
    echo "5. laa logs"
    echo "   看最近日志"
    echo
    echo "6. laa update"
    echo "   更新 agent"
    echo
    echo "7. laa uninstall"
    echo "   卸载 agent"
    echo
    echo "0. 退出"
    echo
    read -rp "请输入编号: " choice
    case "$choice" in
      1) systemctl start log-analyt-agent; echo "已启动"; read -rp "按回车继续..." ;;
      2) systemctl stop log-analyt-agent; echo "已停止"; read -rp "按回车继续..." ;;
      3) systemctl restart log-analyt-agent; echo "已重启"; read -rp "按回车继续..." ;;
      4) systemctl status log-analyt-agent --no-pager; read -rp "按回车继续..." ;;
      5) journalctl -u log-analyt-agent -n 100 --no-pager; read -rp "按回车继续..." ;;
      6)
        tmpdir=$(mktemp -d)
        curl -fsSL https://raw.githubusercontent.com/Y4n9JX/log-analyt-agent/main/install.sh -o "$tmpdir/install.sh"
        curl -fsSL https://raw.githubusercontent.com/Y4n9JX/log-analyt-agent/main/main.py -o "$tmpdir/main.py"
        chmod +x "$tmpdir/install.sh"
        env LOGANALYT_CENTER_URL=$(python3 - <<'PYC'
import json
print(json.load(open('/etc/log-analyt-agent/config.json'))['center_url'])
PYC
) LOGANALYT_SERVER_UUID=$(python3 - <<'PYC'
import json
print(json.load(open('/etc/log-analyt-agent/config.json'))['server_uuid'])
PYC
) LOGANALYT_AGENT_KEY=$(python3 - <<'PYC'
import json
print(json.load(open('/etc/log-analyt-agent/config.json'))['agent_key'])
PYC
) bash "$tmpdir/install.sh"
        rm -rf "$tmpdir"
        echo "已更新"
        read -rp "按回车继续..."
        ;;
      7)
        if [[ -x /opt/log-analyt-agent/uninstall.sh ]]; then
          /opt/log-analyt-agent/uninstall.sh
        elif [[ -x /tmp/log-analyt-agent/uninstall.sh ]]; then
          /tmp/log-analyt-agent/uninstall.sh
        elif [[ -x ./uninstall.sh ]]; then
          ./uninstall.sh
        else
          echo "uninstall.sh not found; download it from log-analyt-agent repo" >&2
          exit 1
        fi
        exit 0
        ;;
      0) exit 0 ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

cmd=${1:-menu}
case "$cmd" in
  menu) show_menu ;;
  start) systemctl start log-analyt-agent ;;
  stop) systemctl stop log-analyt-agent ;;
  restart) systemctl restart log-analyt-agent ;;
  status) systemctl status log-analyt-agent --no-pager ;;
  logs) journalctl -u log-analyt-agent -n 100 --no-pager ;;
  update)
    tmpdir=$(mktemp -d)
    curl -fsSL https://raw.githubusercontent.com/Y4n9JX/log-analyt-agent/main/install.sh -o "$tmpdir/install.sh"
    chmod +x "$tmpdir/install.sh"
    env LOGANALYT_CENTER_URL=$(python3 - <<'PYC'
import json
print(json.load(open('/etc/log-analyt-agent/config.json'))['center_url'])
PYC
) LOGANALYT_SERVER_UUID=$(python3 - <<'PYC'
import json
print(json.load(open('/etc/log-analyt-agent/config.json'))['server_uuid'])
PYC
) LOGANALYT_AGENT_KEY=$(python3 - <<'PYC'
import json
print(json.load(open('/etc/log-analyt-agent/config.json'))['agent_key'])
PYC
) bash "$tmpdir/install.sh"
    rm -rf "$tmpdir"
    ;;
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
    echo "Usage: laa {menu|start|stop|restart|status|logs|update|uninstall}" >&2
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
echo "commands: laa (menu) | laa status | laa restart | laa logs | laa update | laa uninstall"
echo "quick install: curl -fsSL https://raw.githubusercontent.com/Y4n9JX/log-analyt-agent/main/install.sh -o install.sh && chmod +x install.sh && LOGANALYT_CENTER_URL=... LOGANALYT_SERVER_UUID=... LOGANALYT_AGENT_KEY=... ./install.sh"
