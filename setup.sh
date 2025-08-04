#!/bin/bash
set -e

echo "== Загрузка и запуск secure-proxy-setup.sh =="

SCRIPT_URL="https://raw.githubusercontent.com/BuXaLo/secure-ubuntu-socks5/main/secure-proxy-setup.sh"
SCRIPT_NAME="secure-proxy-setup.sh"

# Скачиваем
curl -sSL "$SCRIPT_URL" -o "$SCRIPT_NAME"

# Делаем исполняемым
chmod +x "$SCRIPT_NAME"

# Запускаем
sudo ./"$SCRIPT_NAME"
