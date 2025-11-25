#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root"
  exit
fi

echo "--- 1. Подготовка системы и установка зависимостей ---"
apt-get update
apt-get install -y wget curl socat cron tar

# Лечим DNS
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# Включаем BBR
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
fi

echo "--- 2. Генерация домена (Magic DNS) ---"
PUBLIC_IP=$(curl -s4 icanhazip.com)
if [[ -z "$PUBLIC_IP" ]]; then
    echo "Ошибка: Не удалось определить IP адрес."
    exit 1
fi
DOMAIN="${PUBLIC_IP}.sslip.io"
echo "Домен: $DOMAIN"

echo "--- 3. Получение SSL сертификата (Исправлено) ---"
# Останавливаем веб-серверы, чтобы освободить 80 порт для проверки
systemctl stop nginx 2>/dev/null
systemctl stop apache2 2>/dev/null

mkdir -p /etc/hysteria

# Установка acme.sh (если еще нет)
if [ ! -f ~/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh
fi

# ! ИСПРАВЛЕНИЕ: Переключаемся на Let's Encrypt и регистрируем аккаунт
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --register-account -m "admin@$DOMAIN"

# Выпуск сертификата
echo "Попытка получить сертификат для $DOMAIN..."
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force

if [ $? -ne 0 ]; then
    echo "❌ ОШИБКА: Опять не вышло."
    echo "Проверьте, открыт ли у вас порт 80 (TCP) в панели хостинга."
    echo "Без открытого 80 порта валидный сертификат получить нельзя."
    exit 1
fi

# Копирование сертификатов
~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file /etc/hysteria/server.crt \
    --key-file       /etc/hysteria/server.key

chmod 644 /etc/hysteria/server.crt
chmod 644 /etc/hysteria/server.key

echo "✅ Сертификаты получены!"

echo "--- 4. Установка Hysteria 2 ---"
rm -f /usr/local/bin/hysteria
wget -O /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/download/app%2Fv2.5.1/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

# Генерация паролей
PASSWORD=$(openssl rand -hex 16)
OBFS_PASSWORD=$(openssl rand -hex 16)

echo "--- 5. Пишем конфиг ---"
cat <<EOF > /etc/hysteria/config.yaml
listen: :443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $PASSWORD

obfs:
  type: salamander
  salamander:
    password: $OBFS_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps
EOF

echo "--- 6. Запуск сервиса ---"
cat <<EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
Restart=always
User=root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# Вывод
if systemctl is-active --quiet hysteria-server; then
    echo ""
    echo "========================================================"
    echo "✅ УСПЕШНО! (Secure Mode)"
    echo "========================================================"
    echo "Домен: $DOMAIN"
    echo ""
    echo "⬇️  ТВОЯ ССЫЛКА (Копируй полностью) ⬇️"
    echo ""
    echo "hysteria2://$PASSWORD@$DOMAIN:443/?sni=$DOMAIN&obfs=salamander&obfs-password=$OBFS_PASSWORD"
    echo ""
    echo "========================================================"
else
    echo "❌ Сервис не запустился. Логи:"
    journalctl -u hysteria-server -n 20 --no-pager
fi