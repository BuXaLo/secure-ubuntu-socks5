#!/bin/bash
set -e

echo "== Secure Ubuntu Proxy Server Setup =="

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "Запусти скрипт от root: sudo $0"
  exit 1
fi

# --- 1. Создание нового администратора ---
read -rp "[1/8] Имя нового пользователя с sudo-доступом: " NEW_USER

if id "$NEW_USER" &>/dev/null; then
  echo "Пользователь $NEW_USER уже существует."
else
  useradd -m -s /bin/bash "$NEW_USER"
  echo "Введите пароль для $NEW_USER:"
  passwd "$NEW_USER"
  usermod -aG sudo "$NEW_USER"
  echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
fi

# --- 2. Смена порта SSH ---
read -rp "[2/8] Новый порт для SSH (по умолчанию 2222): " SSH_PORT
SSH_PORT=${SSH_PORT:-2222}

echo "Меняем порт SSH на $SSH_PORT..."
if grep -q "^Port " /etc/ssh/sshd_config; then
  sed -i "s/^Port .*/Port $SSH_PORT/" /etc/ssh/sshd_config
else
  echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
fi

# --- 3. Отключение root-входа по SSH ---
echo "Отключаем вход по root через SSH..."
if grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
  sed -i "s/^PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
else
  echo "PermitRootLogin no" >> /etc/ssh/sshd_config
fi

systemctl restart sshd

echo "Ждём 5 секунд, чтобы дать SSH подняться..."
sleep 5

# --- Проверка порта SSH через ss ---
if ss -tln | grep -q ":$SSH_PORT "; then
  echo "✅ SSH доступен на порту $SSH_PORT"
else
  echo "❌ SSH не слушает на порту $SSH_PORT! Отменяем изменения..."
  sed -i "s/^Port .*/Port 22/" /etc/ssh/sshd_config
  sed -i "s/^PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
  systemctl restart sshd
  exit 1
fi

# --- 4. Установка Danted ---
echo "[4/8] Устанавливаем Danted..."
apt update && apt install dante-server -y

# --- 5. Создание прокси-пользователя ---
read -rp "[5/8] Имя пользователя для SOCKS-прокси: " PROXY_USER
if id "$PROXY_USER" &>/dev/null; then
  echo "Пользователь $PROXY_USER уже существует."
else
  useradd -M -s /usr/sbin/nologin "$PROXY_USER"
fi

echo "Введите пароль для $PROXY_USER:"
passwd "$PROXY_USER"

# --- 6. Порт и интерфейс для прокси ---
read -rp "[6/8] Порт для SOCKS5-прокси (по умолчанию 1080): " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-1080}

INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n 1)
echo "Используется сетевой интерфейс: $INTERFACE"

# --- 7. Генерация /etc/danted.conf ---
echo "[7/8] Создаём конфигурационный файл /etc/danted.conf..."

cat > /etc/danted.conf <<EOF
logoutput: syslog

user.privileged: root
user.unprivileged: nobody

internal: 0.0.0.0 port = $PROXY_PORT
external: $INTERFACE

clientmethod: none
socksmethod: username

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect
    log: connect disconnect error
}
EOF

# --- 8. Перезапуск и проверка Danted ---
echo "[8/8] Перезапускаем Danted..."
systemctl restart danted
systemctl enable danted

echo "Проверка работы Danted..."
sleep 2

if systemctl is-active --quiet danted; then
  echo "✅ Danted успешно запущен!"

  # Запрашиваем пароль для проверки
  read -rsp "🔐 Введите пароль для $PROXY_USER для проверки прокси: " PROXY_PASS
  echo

  echo "🌐 Проверка работы SOCKS5-прокси через curl..."

  curl_result=$(curl -sS -U "$PROXY_USER:$PROXY_PASS" --socks5-hostname 127.0.0.1:$PROXY_PORT http://ifconfig.me || echo "curl_failed")

  if [[ "$curl_result" == "curl_failed" ]] || [[ -z "$curl_result" ]]; then
    echo "❌ Прокси не отвечает или отказал в авторизации. Проверь конфиг, логин/пароль и доступ в интернет."
    exit 1
  else
    echo
    echo "✅ Прокси успешно работает!"
    echo "🌍 Внешний IP через прокси: $curl_result"
    echo
    echo "== Итоговая информация =="
    echo "🔐 Новый sudo-пользователь: $NEW_USER"
    echo "📦 SSH теперь слушает на порту: $SSH_PORT"
    echo "🌐 SOCKS5-прокси: порт $PROXY_PORT, пользователь $PROXY_USER"
    echo
  fi

  unset PROXY_PASS

else
  echo "❌ Danted не запустился. Журнал:"
  journalctl -xeu danted
  exit 1
fi
