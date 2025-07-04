#!/bin/bash

clear
echo -e "\033[1;31m"
cat << "EOF"
 ▄▄▄▄   ██▓   ▄▄▄       ▄████ ▒█████ ▓█████▄ ▄▄▄      ██▀███ ▓█████ ███▄    █ 
▓█████▄▓██▒  ▒████▄    ██▒ ▀█▒██▒  ██▒██▀ ██▒████▄   ▓██ ▒ ██▓█   ▀ ██ ▀█   █ 
▒██▒ ▄█▒██░  ▒██  ▀█▄ ▒██░▄▄▄▒██░  ██░██   █▒██  ▀█▄ ▓██ ░▄█ ▒███  ▓██  ▀█ ██▒
▒██░█▀ ▒██░  ░██▄▄▄▄██░▓█  ██▒██   ██░▓█▄   ░██▄▄▄▄██▒██▀▀█▄ ▒▓█  ▄▓██▒  ▐▌██▒
░▓█  ▀█░██████▓█   ▓██░▒▓███▀░ ████▓▒░▒████▓ ▓█   ▓██░██▓ ▒██░▒████▒██░   ▓██░
░▒▓███▀░ ▒░▓  ▒▒   ▓▒█░░▒   ▒░ ▒░▒░▒░ ▒▒▓  ▒ ▒▒   ▓▒█░ ▒▓ ░▒▓░░ ▒░ ░ ▒░   ▒ ▒ 
▒░▒   ░░ ░ ▒  ░▒   ▒▒ ░ ░   ░  ░ ▒ ▒░ ░ ▒  ▒  ▒   ▒▒ ░ ░▒ ░ ▒░░ ░  ░ ░░   ░ ▒░
 ░    ░  ░ ░   ░   ▒  ░ ░   ░░ ░ ░ ▒  ░ ░  ░  ░   ▒    ░░   ░   ░     ░   ░ ░ 
 ░         ░  ░    ░  ░     ░    ░ ░    ░         ░  ░  ░       ░  ░        ░ 
      ░                               ░                                       
EOF
echo -e "\033[0m"
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
debug() { echo -e "[DEBUG] $1"; }

# ======================== Параметры ========================
read -p "Установить BBR и Xanmod Kernel? (y/n): " ans_bbr
if [[ $ans_bbr =~ ^[Yy] ]]; then
    INSTALL_BBR=true
else
    INSTALL_BBR=false
fi

read -p "Настроить SSH ключ? (y/n): " ans_sshkey
if [[ $ans_sshkey =~ ^[Yy] ]]; then
    INSTALL_SSH_KEY=true
else
    INSTALL_SSH_KEY=false
fi

if [[ $EUID -ne 0 ]]; then
   error "Этот скрипт должен быть запущен с правами root"
fi

log "==================== НАЧАЛО УСТАНОВКИ ===================="
log "Этап 0: Сбор необходимых данных..."

while true; do
    read -p "Введите порт для SSH (по умолчанию 22): " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ]; then
        break
    else
        warning "Некорректный порт. Введите число от 1 до 65535"
    fi
done

while true; do
    read -p "Введите IP адрес мастер-ноды: " MASTER_IP
    if [[ $MASTER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    else
        warning "Некорректный формат IP адреса. Попробуйте снова."
    fi
done

if $INSTALL_SSH_KEY; then
    while true; do
        log "Введите ваш публичный SSH ключ (должен начинаться с 'ssh-rsa' или 'ssh-ed25519'):"
        read SSH_KEY
        if [[ -z "$SSH_KEY" ]]; then
            warning "SSH ключ не может быть пустым."
        elif [[ "$SSH_KEY" =~ ^(ssh-rsa|ssh-ed25519)[[:space:]].*$ ]]; then
            break
        else
            warning "Некорректный формат SSH ключа."
        fi
    done
fi

while true; do
    read -p "Введите субдомен (например, us.domain.com): " SUBDOMAIN
    if [ -z "$SUBDOMAIN" ]; then
        warning "Субдомен не может быть пустым. Пожалуйста, введите значение."
    else
        break
    fi
done

while true; do
    read -p "Введите имя ноды (например, us-node-1): " NODE_NAME
    if [ -z "$NODE_NAME" ]; then
        warning "Имя ноды не может быть пустым. Пожалуйста, введите значение."
    else
        break
    fi
done

while true; do
    read -p "Введите deSEC API-токен: " DESEC_TOKEN
    if [ -z "$DESEC_TOKEN" ]; then
        warning "API-токен не может быть пустым. Пожалуйста, введите значение."
    else
        break
    fi
done

while true; do
    read -p "Введите email для Let's Encrypt (обязательно, не фейк): " LE_EMAIL
    if [ -z "$LE_EMAIL" ]; then
        warning "Email не может быть пустым. Пожалуйста, введите значение."
    else
        break
    fi
done

read -p "Введите порт для сервиса (по умолчанию 62050): " SERVICE_PORT
SERVICE_PORT=${SERVICE_PORT:-62050}
read -p "Введите порт для API (по умолчанию 62051): " API_PORT
API_PORT=${API_PORT:-62051}

log "Введите SSL client сертификат (После Enter - Ctrl+D для завершения ввода):"
SSL_CERT=$(cat)
if [ -z "$SSL_CERT" ]; then
    error "SSL сертификат не может быть пустым."
fi

CERT_BODY=$(echo "$SSL_CERT" | grep -v "BEGIN CERTIFICATE" | grep -v "END CERTIFICATE" | tr -d '\n')
if [[ ! $CERT_BODY =~ ^[A-Za-z0-9+/=]+$ ]]; then
    error "Некорректный формат сертификата. Пожалуйста, предоставьте валидный SSL сертификат."
fi

debug "Субдомен: ${SUBDOMAIN}"
debug "Название ноды: ${NODE_NAME}"
debug "Service port: ${SERVICE_PORT}"
debug "API port: ${API_PORT}"

MAIN_DOMAIN=$(echo ${SUBDOMAIN} | awk -F. '{print $(NF-1)"."$NF}')
debug "Основной домен: ${MAIN_DOMAIN}"

# ======================== Установка системных компонентов ========================
log "Системные компоненты..."
apt update 2>&1 | while read -r line; do debug "$line"; done
apt upgrade -y 2>&1 | while read -r line; do debug "$line"; done || error "Ошибка при обновлении системы"
apt install -y curl wget git expect ufw openssl lsb-release ca-certificates gnupg2 ubuntu-keyring socat 2>&1 | while read -r line; do debug "$line"; done || error "Ошибка при установке базовых пакетов"

# ======================== Опциональная установка BBR ========================
if $INSTALL_BBR; then
    log "Установка BBRv3..."
    curl -s https://raw.githubusercontent.com/opiran-club/VPS-Optimizer/main/bbrv3.sh --ipv4 > bbrv3.sh || error "Ошибка при скачивании BBRv3"
    expect << 'EOF'
spawn bash bbrv3.sh
expect "Enter"
send "1\r"
expect "y/n"
send "y\r"
expect eof
EOF
    rm bbrv3.sh
else
    debug "BBR не устанавливается."
fi

log "Установка NGINX и acme.sh..."
curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list
echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" | tee /etc/apt/preferences.d/99nginx
apt update 2>&1 | while read -r line; do debug "$line"; done
apt install -y nginx || error "Ошибка при установке Nginx"
mkdir -p /etc/nginx
openssl dhparam -out /etc/nginx/dhparam.pem 2048 || error "Ошибка при генерации dhparam"

# acme.sh install/update
log "Установка/обновление acme.sh..."
curl https://get.acme.sh | sh || error "Ошибка при установке acme.sh"
export DEDYN_TOKEN="${DESEC_TOKEN}"
export LE_EMAIL="${LE_EMAIL}"
export HOME="/root"
. /root/.acme.sh/acme.sh.env

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

log "Регистрация аккаунта Let's Encrypt через acme.sh..."
~/.acme.sh/acme.sh --register-account -m "${LE_EMAIL}" --server letsencrypt || warning "Аккаунт LE уже зарегистрирован"

log "Выпуск wildcard SSL для ${MAIN_DOMAIN} и *.${MAIN_DOMAIN} через deSEC..."
~/.acme.sh/acme.sh --issue --dns dns_desec -d "${MAIN_DOMAIN}" -d "*.${MAIN_DOMAIN}" --keylength ec-256 --dnssleep 120 --force --home /root/.acme.sh || error "Не удалось получить wildcard сертификат через deSEC"

mkdir -p /etc/letsencrypt/live/${MAIN_DOMAIN}
cp /root/.acme.sh/${MAIN_DOMAIN}_ecc/${MAIN_DOMAIN}.key /etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem
cp /root/.acme.sh/${MAIN_DOMAIN}_ecc/fullchain.cer /etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem
cp /root/.acme.sh/${MAIN_DOMAIN}_ecc/ca.cer /etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem

log "Nginx конфиг..."
mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup 2>/dev/null

cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
pid /var/run/nginx.pid;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;
events {
    multi_accept on;
    worker_connections 1024;
}
http {
    map $request_uri $cleaned_request_uri {
        default $request_uri;
        "~^(.*?)(\?x_padding=[^ ]*)$" $1;
    }
    log_format json_analytics escape=json '{'
        '$time_local, '
        '$http_x_forwarded_for, '
        '$proxy_protocol_addr, '
        '$request_method '
        '$status, '
        '$http_user_agent, '
        '$cleaned_request_uri, '
        '$http_referer, '
        '}';
    set_real_ip_from 127.0.0.1;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;
    access_log /var/log/nginx/access.log json_analytics;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;
    log_not_found off;
    types_hash_max_size 2048;
    types_hash_bucket_size 64;
    client_max_body_size 16M;
    keepalive_timeout 75s;
    keepalive_requests 1000;
    reset_timedout_connection on;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:1m;
    ssl_session_tickets off;
    ssl_prefer_server_ciphers on;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 127.0.0.1 valid=60s;
    resolver_timeout 2s;
    gzip on;
    add_header X-XSS-Protection "0" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Permissions-Policy "interest-cohort=()" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
    add_header X-Frame-Options "SAMEORIGIN";
    proxy_hide_header X-Powered-By;
    include /etc/nginx/conf.d/*.conf;
}
stream {
    include /etc/nginx/stream-enabled/stream.conf;
}
EOF

mkdir -p /etc/nginx/stream-enabled
rm -f /etc/nginx/conf.d/default.conf

cat > /etc/nginx/stream-enabled/stream.conf << EOF
map \$ssl_preread_server_name \$backend {
    default block;
    ${SUBDOMAIN} web;
}
upstream block {
    server 127.0.0.1:36076;
}
upstream web {
    server 127.0.0.1:7443;
}
upstream xtls {
    server 127.0.0.1:8443;
}
server {
    listen 443 reuseport;
    ssl_preread on;
    proxy_protocol on;
    proxy_pass \$backend;
}
EOF

cat > /etc/nginx/conf.d/local.conf << EOF
server {
    listen 80;
    server_name ${SUBDOMAIN};
    location / {
        return 301 https://${SUBDOMAIN}\$request_uri;
    }
}
server {
    listen 9090 default_server;
    server_name ${SUBDOMAIN};
    location / {
        return 301 https://${SUBDOMAIN}\$request_uri;
    }
}
server {
    listen 36076 ssl proxy_protocol;
    ssl_reject_handshake on;
}
server {
    listen 36077 ssl proxy_protocol;
    http2 on;
    server_name ${SUBDOMAIN};
    ssl_certificate /etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem;
    ssl_dhparam /etc/nginx/dhparam.pem;
    index index.html;
    root /var/www/${SUBDOMAIN}/;
}
EOF

mkdir -p /var/www/${SUBDOMAIN}
cat > /var/www/${SUBDOMAIN}/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Cloud Storage - Login</title>
    <style>
        body { font-family: Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 0; display: flex; justify-content: center; align-items: center; height: 100vh; }
        .login-container { background-color: white; padding: 40px; border-radius: 10px; box-shadow: 0 0 20px rgba(0, 0, 0, 0.1); width: 100%; max-width: 400px; }
        .login-header { text-align: center; margin-bottom: 30px; }
        .login-header h1 { color: #333; margin: 0; font-size: 24px; }
        .form-group { margin-bottom: 20px; }
        .form-group label { display: block; margin-bottom: 5px; color: #666; }
        .form-group input { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 5px; box-sizing: border-box; }
        .submit-btn { width: 100%; padding: 12px; background-color: #007bff; color: white; border: none; border-radius: 5px; cursor: pointer; font-size: 16px; }
        .submit-btn:hover { background-color: #0056b3; }
        .footer { text-align: center; margin-top: 20px; color: #666; font-size: 14px; }
    </style>
</head>
<body>
    <div class="login-container">
        <div class="login-header">
            <h1>Cloud Storage</h1>
        </div>
        <form action="#" method="POST" onsubmit="return false;">
            <div class="form-group">
                <label for="email">Email</label>
                <input type="email" id="email" name="email" required>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" required>
            </div>
            <button type="submit" class="submit-btn">Log In</button>
        </form>
        <div class="footer">
            <p>Protected by CloudFlare</p>
        </div>
    </div>
</body>
</html>
EOF

chown -R www-data:www-data /var/www/${SUBDOMAIN}
chmod -R 755 /var/www/${SUBDOMAIN}

# ======================== Установка Marzban Node ========================
log "Установка Marzban Node..."
curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban-node.sh > marzban-node.sh
chmod +x marzban-node.sh

expect << EOF
spawn ./marzban-node.sh @ install --name ${NODE_NAME}
expect "Please paste the content of the Client Certificate"
send -- "-----BEGIN CERTIFICATE-----\n"
send -- "${CERT_BODY}\n"
send -- "-----END CERTIFICATE-----\n\n"
expect "Do you want to use REST protocol?"
send -- "y\n"
expect "Enter the SERVICE_PORT"
send -- "${SERVICE_PORT}\n"
expect "Enter the XRAY_API_PORT"
send -- "${API_PORT}\n"
expect eof
EOF

rm -f marzban-node.sh

mkdir -p /var/lib/marzban/log
touch /var/lib/marzban/log/access.log
chmod 755 /var/lib/marzban/log
chmod 644 /var/lib/marzban/log/access.log

DOCKER_COMPOSE_FILE="/opt/${NODE_NAME}/docker-compose.yml"
if [[ -f "${DOCKER_COMPOSE_FILE}" ]]; then
    sed -i '/volumes:/a\      - /var/lib/marzban/log:/var/lib/marzban/log' ${DOCKER_COMPOSE_FILE}
    cd /opt/${NODE_NAME}
    docker compose down
    docker compose up -d
else
    warning "Файл docker-compose.yml не найден, пропуск настройки монтирования логов."
fi

nginx -t 2>&1 | while read -r line; do debug "$line"; done || error "Ошибка в конфигурации Nginx"
systemctl enable nginx 2>&1 | while read -r line; do debug "$line"; done
systemctl start nginx 2>&1 | while read -r line; do debug "$line"; done
if ! systemctl is-active --quiet nginx; then
    error "Не удалось запустить Nginx"
fi

log "Настройка UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow ${SSH_PORT}/tcp
ufw allow from ${MASTER_IP}
echo "y" | ufw enable
ufw status verbose || error "Ошибка при настройке UFW"

log "Настройка SSH..."
if $INSTALL_SSH_KEY; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    cat > /root/.ssh/authorized_keys << EOF
${SSH_KEY}
EOF

    cat > /etc/ssh/sshd_config << EOF
Port ${SSH_PORT}
Protocol 2
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 60
AllowUsers root
EOF

    systemctl restart ssh
    if ! systemctl is-active --quiet ssh; then
        error "Не удалось запустить SSH"
    fi
fi

log "Установка успешно завершена!"
debug "Все компоненты установлены и настроены"
read -p "Перезагрузить систему сейчас? (y/n): " reboot_now
if [[ $reboot_now == "y" ]]; then
    debug "Выполняется перезагрузка системы..."
    reboot
fi