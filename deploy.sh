#!/bin/bash

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, запустите скрипт от имени root"
  exit
fi

echo "--- 1. Подготовка системы ---"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl socat cron tar iptables iptables-persistent netfilter-persistent

# Лечим системный DNS (для работы самого сервера)
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# Включаем BBR и IP Forwarding
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    sysctl -p
fi

echo "--- 2. Магия с доменом ---"
PUBLIC_IP=$(curl -s4 icanhazip.com)
if [[ -z "$PUBLIC_IP" ]]; then
    echo "Ошибка: Не удалось определить IP."
    exit 1
fi
DOMAIN="${PUBLIC_IP}.sslip.io"
echo "Домен: $DOMAIN"

echo "--- 3. Port Hopping (Маскировка портов) ---"
START_PORT=20000
END_PORT=50000
MAIN_PORT=443

iptables -t nat -F PREROUTING
iptables -t nat -A PREROUTING -p udp --dport $START_PORT:$END_PORT -j DNAT --to-destination :$MAIN_PORT
netfilter-persistent save

echo "✅ Port Hopping: $START_PORT-$END_PORT -> $MAIN_PORT"

echo "--- 4. SSL Сертификат ---"
systemctl stop nginx 2>/dev/null
systemctl stop apache2 2>/dev/null
systemctl stop hysteria-server 2>/dev/null

mkdir -p /etc/hysteria

if [ ! -f ~/.acme.sh/acme.sh ]; then
    curl https://get.acme.sh | sh
fi

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --register-account -m "admin@$DOMAIN"
~/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone -k ec-256 --force

if [ $? -ne 0 ]; then
    echo "❌ Ошибка SSL. Проверьте 80 порт."
    exit 1
fi

~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file /etc/hysteria/server.crt \
    --key-file       /etc/hysteria/server.key

chmod 644 /etc/hysteria/server.crt
chmod 644 /etc/hysteria/server.key

echo "--- 5. Установка ядра Hysteria 2 ---"
rm -f /usr/local/bin/hysteria
wget -O /usr/local/bin/hysteria https://github.com/apernet/hysteria/releases/download/app%2Fv2.5.1/hysteria-linux-amd64
chmod +x /usr/local/bin/hysteria

PASSWORD=$(openssl rand -hex 16)
OBFS_PASSWORD=$(openssl rand -hex 16)

echo "--- 6. Конфигурация (Anti-Ad + Secure DNS) ---"
cat <<EOF > /etc/hysteria/config.yaml
listen: :$MAIN_PORT

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

# === БЛОКИРОВЩИК РЕКЛАМЫ (AdGuard DNS over HTTPS) ===
# Шифрует DNS-запросы, чтобы провайдер VPS их не видел
resolver:
  type: https
  https:
    addr: 94.140.14.14:443
    sni: dns.adguard-dns.com
    insecure: false
    timeout: 10s
# ====================================================

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
    url: https://news.ycombinator.com/
    rewriteHost: true

ignoreClientBandwidth: true
EOF

echo "--- 7. Создание службы (BLACK HOLE LOGGING) ---"
cat <<EOF > /etc/systemd/system/hysteria-server.service
[Unit]
Description=Hysteria 2 Server (No Logs)
After=network.target

[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
WorkingDirectory=/etc/hysteria
Restart=always
User=root
LimitNOFILE=65536

# === ПОЛНОЕ УНИЧТОЖЕНИЕ ЛОГОВ ===
# Весь вывод (stdout/stderr) отправляется в никуда (null)
StandardOutput=null
StandardError=null
# ================================

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hysteria-server
systemctl restart hysteria-server

# Проверка статуса
if systemctl is-active --quiet hysteria-server; then
    echo ""
    echo "========================================================"
    echo "🛡️  HYSTERIA 2 АКТИВИРОВАНА"
    echo "========================================================"
    echo "IP сервера: $PUBLIC_IP"
    echo "Домен: $DOMAIN"
    echo "Логирование: ОТКЛЮЧЕНО (Black Hole Mode)"
    echo "Реклама: БЛОКИРУЕТСЯ (AdGuard DNS over HTTPS)"
    echo "Port Hopping: $START_PORT-$END_PORT"
    echo "========================================================"
    echo ""
    echo "⬇️  ТВОЯ ССЫЛКА ⬇️"
    echo ""
    echo "hysteria2://$PASSWORD@$DOMAIN:$MAIN_PORT/?sni=$DOMAIN&obfs=salamander&obfs-password=$OBFS_PASSWORD&insecure=0&mport=$START_PORT-$END_PORT#Hysteria2-NoAds"
    echo ""
    echo "========================================================"
else
    echo "❌ Сервис не запущен. Проверьте конфиг вручную:"
    echo "/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml"
fi