#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME=log-analyt-agent
INSTALL_DIR=${LOGANALYT_INSTALL_DIR:-/opt/log-analyt-agent}
CONFIG_DIR=${LOGANALYT_CONFIG_DIR:-/etc/log-analyt-agent}

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
fi

rm -f "/etc/systemd/system/${SERVICE_NAME}.service"

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi

rm -rf "$INSTALL_DIR"
rm -rf "$CONFIG_DIR"
rm -f /usr/local/bin/laa
rm -rf /tmp/log-analyt-agent

echo "[log-analyt-agent] uninstall ok"
echo "removed_service=${SERVICE_NAME}"
echo "removed_install_dir=${INSTALL_DIR}"
echo "removed_config_dir=${CONFIG_DIR}"
echo "removed_shortcut=/usr/local/bin/laa"
echo "removed_tmp_dir=/tmp/log-analyt-agent"
