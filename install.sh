#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=${LOGANALYT_INSTALL_DIR:-/opt/log-analyt-agent}
CONFIG_DIR=${LOGANALYT_CONFIG_DIR:-/etc/log-analyt-agent}
SERVICE_NAME=log-analyt-agent
CENTER_URL=${LOGANALYT_CENTER_URL:-}
SERVER_UUID=${LOGANALYT_SERVER_UUID:-}
AGENT_KEY=${LOGANALYT_AGENT_KEY:-}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR=${LOGANALYT_WORK_DIR:-/tmp/log-analyt-agent}

bootstrap_if_needed() {
  if [[ -n "$SERVER_UUID" && -n "$AGENT_KEY" ]]; then
    return 0
  fi

  if [[ -z "$CENTER_URL" ]]; then
    return 0
  fi

  echo "[log-analyt-agent] no server_uuid/agent_key provided, requesting bootstrap..."

  if ! command -v python3 >/dev/null 2>&1; then
    echo "[log-analyt-agent] python3 is required for bootstrap response parsing"
    exit 1
  fi

  HOSTNAME_VALUE=$(hostname 2>/dev/null || echo unknown)
  OS_VALUE=$(uname -a 2>/dev/null || echo unknown)
  BOOTSTRAP_URL="${CENTER_URL%/}/api/agent/bootstrap.php"
  BOOTSTRAP_PAYLOAD=$(python3 - <<'PYC'
import json, os
print(json.dumps({
    "hostname": os.environ.get("HOSTNAME_VALUE", "unknown"),
    "os": os.environ.get("OS_VALUE", "unknown"),
    "source_type": os.environ.get("LOGANALYT_SOURCE_TYPE", "nginx_access"),
    "parser_name": os.environ.get("LOGANALYT_PARSER_NAME", "nginx_combined"),
    "timezone": os.environ.get("LOGANALYT_TIMEZONE", "Asia/Shanghai"),
    "agent_version": "0.1.0"
}, ensure_ascii=False))
PYC
)

  BOOTSTRAP_RESPONSE=$(HOSTNAME_VALUE="$HOSTNAME_VALUE" OS_VALUE="$OS_VALUE" curl -fsSL -X POST "$BOOTSTRAP_URL" -H "Content-Type: application/json" -d "$BOOTSTRAP_PAYLOAD") || {
    echo "[log-analyt-agent] bootstrap request failed"
    exit 1
  }

  eval "$(BOOTSTRAP_RESPONSE_JSON="$BOOTSTRAP_RESPONSE" python3 - <<'PYC'
import json, os, shlex, sys
raw = os.environ.get("BOOTSTRAP_RESPONSE_JSON", "")
try:
    data = json.loads(raw)
except Exception as e:
    print(f'echo "[log-analyt-agent] invalid bootstrap response: {shlex.quote(str(e))}" >&2')
    print('exit 1')
    sys.exit(0)
if not data.get("ok"):
    print(f'echo "[log-analyt-agent] bootstrap failed: {shlex.quote(str(data))}" >&2')
    print('exit 1')
    sys.exit(0)
print('SERVER_UUID=' + shlex.quote(data.get('server_uuid', '')))
print('AGENT_KEY=' + shlex.quote(data.get('agent_key', '')))
PYC
)"

  if [[ -z "$SERVER_UUID" || -z "$AGENT_KEY" ]]; then
    echo "[log-analyt-agent] bootstrap did not return credentials"
    exit 1
  fi

  echo "[log-analyt-agent] bootstrap ok: server_uuid=$SERVER_UUID"
}

prompt_if_missing() {
  local interactive=0
  local force_non_interactive=${LOGANALYT_NON_INTERACTIVE:-0}
  local input_fd="/dev/tty"

  if [[ "$force_non_interactive" == "1" ]]; then
    return 0
  fi

  if [[ ! -r "$input_fd" ]]; then
    echo "[log-analyt-agent] non-interactive shell detected; skipping prompts"
    return 0
  fi

  if [[ -z "$CENTER_URL" ]]; then
    interactive=1
    read -r -p "请输入中心站地址 (如 https://your-domain.example): " CENTER_URL < "$input_fd"
  fi
  if [[ -z "$SERVER_UUID" ]]; then
    interactive=1
    read -r -p "请输入 server_uuid（留空则自动申请）: " SERVER_UUID < "$input_fd"
  fi
  if [[ -z "$AGENT_KEY" ]]; then
    interactive=1
    read -r -p "请输入 agent_key（留空则自动申请）: " AGENT_KEY < "$input_fd"
  fi

  if [[ "$interactive" -eq 1 ]]; then
    echo
    echo "安装信息确认："
    echo "- center_url: $CENTER_URL"
    echo "- server_uuid: $SERVER_UUID"
    echo "- agent_key: $AGENT_KEY"
    read -r -p "是否继续安装？[Y/n]: " confirm < "$input_fd"
    confirm=${confirm:-Y}
    case "$confirm" in
      Y|y|yes|YES) ;;
      *)
        echo "[log-analyt-agent] cancelled"
        exit 1
        ;;
    esac
  fi
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

mkdir -p "$WORK_DIR" "$INSTALL_DIR" "$CONFIG_DIR"
prompt_if_missing
bootstrap_if_needed

if [[ -z "$CENTER_URL" || -z "$SERVER_UUID" || -z "$AGENT_KEY" ]]; then
  echo "[log-analyt-agent] missing required values"
  echo "Need: LOGANALYT_CENTER_URL, LOGANALYT_SERVER_UUID, LOGANALYT_AGENT_KEY"
  exit 1
fi

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

SCRIPT_SOURCE="$WORK_DIR/main.py"
echo "[log-analyt-agent] downloading main.py..."
curl -fsSL https://raw.githubusercontent.com/Y4n9JX/log-analyt-agent/main/main.py -o "$SCRIPT_SOURCE"

UNINSTALL_SOURCE="$WORK_DIR/uninstall.sh"
echo "[log-analyt-agent] downloading uninstall.sh..."
curl -fsSL https://raw.githubusercontent.com/Y4n9JX/log-analyt-agent/main/uninstall.sh -o "$UNINSTALL_SOURCE"
chmod +x "$UNINSTALL_SOURCE"

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
        env LOGANALYT_NON_INTERACTIVE=1 LOGANALYT_CENTER_URL=$(python3 - <<'PYC'
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
    env LOGANALYT_NON_INTERACTIVE=1 LOGANALYT_CENTER_URL=$(python3 - <<'PYC'
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
echo "quick install: curl -L https://raw.githubusercontent.com/Y4n9JX/log-analyt-agent/main/install.sh -o agent.sh && chmod +x agent.sh && LOGANALYT_CENTER_URL=https://your-domain.example LOGANALYT_SERVER_UUID=... LOGANALYT_AGENT_KEY=... ./agent.sh"
