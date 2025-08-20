#!/bin/bash
set -euo pipefail

clear
echo -e "\033[1;31m"
cat << "EOF"

 __       __                          __     _  __         
/\ \     /\ \                        /\ \  /' \/\ \        
\ \ \____\ \ \____    ___      __    \_\ \/\_, \ \ \/'\    
 \ \ '__`\\ \ '__`\  / __`\  /'_ `\  /'_` \/_/\ \ \ , <    
  \ \ \L\ \\ \ \L\ \/\ \L\ \/\ \L\ \/\ \L\ \ \ \ \ \ \\`\  
   \ \_,__/ \ \_,__/\ \____/\ \____ \ \___,_\ \ \_\ \_\ \_\
    \/___/   \/___/  \/___/  \/___L\ \/__,_ /  \/_/\/_/\/_/
                               /\____/                     
                               \_/__/                                                          
EOF
echo -e "\033[0m"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log(){ echo -e "${GREEN}[INFO]${NC} $1"; }
err(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn(){ echo -e "${YELLOW}[WARNING]${NC} $1"; }
dbg(){ echo -e "[DEBUG] $1"; }
trap 'err "Неожиданная ошибка на строке $LINENO"' ERR

# ==================== DNS-провайдер для ACME ====================
while true; do
  echo -e "${YELLOW}DNS-провайдер для выпуска wildcard-серта:${NC}"
  echo "  1) deSEC.io"
  echo "  2) Gcore DNS"
  read -p "Введите номер (1/2): " DNS_PROVIDER_NUM
  case "$DNS_PROVIDER_NUM" in
    1)
      DNS_PROVIDER="desec"; DNS_API="dns_desec"
      while true; do
        read -p "Введите deSEC API-токен: " DNS_TOKEN
        [[ -z "$DNS_TOKEN" ]] && { warn "Токен пустой"; continue; }
        export DEDYN_TOKEN="$DNS_TOKEN"; break
      done
      break
      ;;
    2)
      DNS_PROVIDER="gcore"; DNS_API="dns_gcore"
      while true; do
        read -p "Введите Gcore API Key (права на DNS): " DNS_TOKEN
        [[ -z "$DNS_TOKEN" ]] && { warn "Ключ пустой"; continue; }
        export GCORE_Key="$DNS_TOKEN"; break
      done
      break
      ;;
    *) warn "Только 1 или 2";;
  esac
done

# ==================== Выбор транспорта ====================
while true; do
  read -p "Выберите транспорт (xhttp/else) [else]: " TRANSPORT_PROTO
  TRANSPORT_PROTO=${TRANSPORT_PROTO:-else}
  case "$TRANSPORT_PROTO" in
    xhttp) XHTTP_MODE=true; break;;
    else)  XHTTP_MODE=false; break;;
    *) echo "Доступно: xhttp или else";;
  esac
done

# ==================== Параметры ====================
read -p "Установить BBR и Xanmod Kernel? (y/n): " a_bbr
INSTALL_BBR=false; [[ $a_bbr =~ ^[Yy]$ ]] && INSTALL_BBR=true

read -p "Настроить SSH ключ? (y/n): " a_key
INSTALL_SSH_KEY=false; [[ $a_key =~ ^[Yy]$ ]] && INSTALL_SSH_KEY=true

[[ $EUID -ne 0 ]] && err "Запустите с root"

log "=== Сбор параметров ==="
read -p "SSH порт [22]: " SSH_PORT; SSH_PORT=${SSH_PORT:-22}
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT<1 || SSH_PORT>65535 )); then err "Неверный SSH порт"; fi

while true; do
  read -p "IP мастер-ноды (доступ к REST/API): " MASTER_IP
  [[ $MASTER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break || warn "Неверный IPv4"
done

if $INSTALL_SSH_KEY; then
  while true; do
    log "Вставьте публичный SSH ключ (ssh-rsa/ssh-ed25519):"
    read SSH_KEY
    [[ -z "$SSH_KEY" ]] && { warn "Ключ пустой"; continue; }
    [[ "$SSH_KEY" =~ ^(ssh-rsa|ssh-ed25519)[[:space:]].*$ ]] && break || warn "Неверный формат ключа"
  done
fi

while true; do
  read -p "Субдомен (например, us.domain.com): " SUBDOMAIN
  [[ -n "$SUBDOMAIN" ]] && break || warn "Субдомен пустой"
done

while true; do
  read -p "Имя ноды (например, us-node-1): " NODE_NAME
  [[ -n "$NODE_NAME" ]] && break || warn "Имя ноды пустое"
done

while true; do
  read -p "Email для Let's Encrypt: " LE_EMAIL
  if [ -z "$LE_EMAIL" ]; then warn "Email пустой"; else break; fi  # фикс -z
done

read -p "SERVICE порт [62050]: " SERVICE_PORT; SERVICE_PORT=${SERVICE_PORT:-62050}
read -p "API порт [62051]: " API_PORT; API_PORT=${API_PORT:-62051}

if $XHTTP_MODE; then
  echo "Домены (SNI), которые должны идти в XHTTP (через пробел)."
  echo "Пример: login.vpnabe.online x.vpnabe.online sp1.zvng.ru ya.ru google.com"
  read -r XHTTP_SNI_LINE || true
  read -ra XHTTP_SNI <<< "${XHTTP_SNI_LINE:-}"
fi

# Требования: домен != SUBDOMAIN, валидный формат, без дубликатов, нижний регистр
read -ra XHTTP_RAW <<< "${XHTTP_SNI_LINE:-}"

declare -A __seen
XHTTP_SNI=()

is_valid_domain() {
  [[ "$1" =~ ^([a-z0-9-]+\.)+[a-z0-9-]+$ ]]
}

for d in "${XHTTP_RAW[@]}"; do
  d=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]')
  d="${d%.}"                         # уберём завершающую точку, если была
  [[ -z "$d" ]] && continue

  if [[ "$d" == "$SUBDOMAIN" ]]; then
    warning "Домены для xhttp не могут совпадать с доменом заглушки (${SUBDOMAIN}). '${d}' исключён."
    continue
  fi
  if ! is_valid_domain "$d"; then
    warning "Пропускаю некорректный домен для xhttp: ${d}"
    continue
  fi
  if [[ -z "${__seen[$d]:-}" ]]; then
    __seen[$d]=1
    XHTTP_SNI+=("$d")
  fi
done

if [[ ${#XHTTP_SNI[@]} -eq 0 ]]; then
  warning "Список xhttp-доменов пуст. xhttp будет работать только по явно разрешённым SNI (если добавишь позже)."
fi


log "Вставьте SSL client сертификат (после Enter нажмите Ctrl+D):"
SSL_CERT=$(cat)
[[ -z "$SSL_CERT" ]] && err "Сертификат пустой"

CERT_BODY=$(echo "$SSL_CERT" | grep -v "BEGIN CERTIFICATE" | grep -v "END CERTIFICATE" | tr -d '\n')
[[ $CERT_BODY =~ ^[A-Za-z0-9+/=]+$ ]] || err "Неверный формат сертификата"

MAIN_DOMAIN=$(echo ${SUBDOMAIN} | awk -F. '{print $(NF-1)"."$NF}')
dbg "MAIN_DOMAIN=${MAIN_DOMAIN}"

# ==================== Система ====================
log "Обновление системы и базовые пакеты..."
apt update 2>&1 | while read -r l; do dbg "$l"; done
apt upgrade -y 2>&1 | while read -r l; do dbg "$l"; done
apt install -y curl wget git expect ufw openssl lsb-release ca-certificates gnupg2 ubuntu-keyring socat cron 2>&1 | while read -r l; do dbg "$l"; done
systemctl enable --now cron

# ======== УСТАНОВКА BBRv3 (устойчивый expect) ========
if $INSTALL_BBR; then
    log "==================== УСТАНОВКА BBRv3 ===================="
    log "Шаг 1.3: Установка BBRv3..."
    dbg "Загрузка скрипта BBRv3..."
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
    debug "Опциональная установка BBR пропущена."
fi


# ==================== NGINX ====================
log "Установка NGINX..."
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
cat >/etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF
apt update 2>&1 | while read -r l; do dbg "$l"; done
apt install -y nginx
mkdir -p /etc/nginx
openssl dhparam -out /etc/nginx/dhparam.pem 2048

# ==================== ACME (Let’s Encrypt) ====================
log "Устанавливаем acme.sh и регистрируем аккаунт..."
export HOME="/root"
curl -fsSL https://get.acme.sh | sh
. /root/.acme.sh/acme.sh.env
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --register-account -m "${LE_EMAIL}" --server letsencrypt || warn "LE аккаунт уже есть"

log "Выпуск wildcard для ${MAIN_DOMAIN} (+ *.${MAIN_DOMAIN}) через ${DNS_PROVIDER}..."
~/.acme.sh/acme.sh --issue --dns ${DNS_API} -d "${MAIN_DOMAIN}" -d "*.${MAIN_DOMAIN}" --keylength ec-256 --dnssleep 120 --force

cat >/usr/local/sbin/nginx-acme-reload.sh <<'SH'
#!/usr/bin/env bash
set -e
if systemctl is-active --quiet nginx; then
  nginx -t && systemctl reload nginx
else
  echo "[acme] nginx inactive, skip reload"
fi
SH
chmod +x /usr/local/sbin/nginx-acme-reload.sh

log "Деплой сертификатов в боевые пути + auto-reload nginx при продлении..."
mkdir -p /etc/letsencrypt/live/${MAIN_DOMAIN}
~/.acme.sh/acme.sh --install-cert -d "${MAIN_DOMAIN}" --ecc \
  --key-file       "/etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem" \
  --fullchain-file "/etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem" \
  --ca-file        "/etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem" \
  --reloadcmd      "/usr/local/sbin/nginx-acme-reload.sh"

# ==================== NGINX конфиги ====================
write_nginx_common_conf() {
cat > /etc/nginx/nginx.conf <<'EOF'
user  www-data;
pid   /var/run/nginx.pid;
worker_processes auto;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log;
include /etc/nginx/modules-enabled/*.conf;

events { multi_accept on; worker_connections 1024; }

http {
  map $request_uri $cleaned_request_uri {
    default $request_uri;
    "~^(.*?)(\?x_padding=[^ ]*)$" $1;
  }
  log_format json_analytics escape=json '{'
    '$time_local, $remote_addr, $request_method $status, '
    '$http_user_agent, $cleaned_request_uri, $http_referer }';

  access_log /var/log/nginx/access.log json_analytics;
  sendfile on; tcp_nopush on; tcp_nodelay on;
  server_tokens off; log_not_found off;
  types_hash_max_size 2048; types_hash_bucket_size 64;
  client_max_body_size 16M;
  keepalive_timeout 75s; keepalive_requests 1000; reset_timedout_connection on;

  include /etc/nginx/mime.types; default_type application/octet-stream;

  ssl_session_timeout 1d; ssl_session_cache shared:SSL:1m; ssl_session_tickets off;
  ssl_prefer_server_ciphers on; ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
  ssl_stapling on; ssl_stapling_verify on;

  gzip on;
  add_header X-Content-Type-Options "nosniff" always;
  add_header Referrer-Policy "no-referrer-when-downgrade" always;
  add_header Permissions-Policy "interest-cohort=()" always;
  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
  add_header X-Frame-Options "SAMEORIGIN";
  proxy_hide_header X-Powered-By;

  include /etc/nginx/conf.d/*.conf;
}
stream { include /etc/nginx/stream-enabled/stream.conf; }
EOF
}

write_nginx_xhttp_with_stub() {
  mkdir -p /etc/nginx/stream-enabled

  # stream: SNI-роутинг без proxy_protocol
  {
    echo 'map $ssl_preread_server_name $backend {'
    echo '    default block;'
    # заглушка всегда на SUBDOMAIN → web
    echo "    ${SUBDOMAIN} web;"
    # каждый валидный SNI из списка → xhttp (SUBDOMAIN здесь уже исключён на этапе sanitize)
    if [ "${#XHTTP_SNI[@]}" -gt 0 ]; then
      for d in "${XHTTP_SNI[@]}"; do
        echo "    ${d} xhttp;"
      done
    fi
    echo '}'

    echo
    echo 'upstream block { server 127.0.0.1:36076; }' # ssl_reject_handshake
    echo 'upstream xhttp { server 127.0.0.1:5443; }' # XRAY REALITY XHTTP
    echo 'upstream web   { server 127.0.0.1:36077; }' # HTTPS-заглушка

    echo 'server {'
    echo '    listen 443 reuseport;'
    echo '    ssl_preread on;'
    echo '    proxy_pass $backend;'
    echo '}'
  } > /etc/nginx/stream-enabled/stream.conf

  # http: заглушка (web) и жёсткий reject (block)
  cat > /etc/nginx/conf.d/local.conf <<EOF
server {
  listen 80;
  server_name ${SUBDOMAIN};
  location / { return 301 https://${SUBDOMAIN}\$request_uri; }
}
server {
  listen 36076 ssl;
  ssl_reject_handshake on;
}
server {
  listen 36077 ssl http2;
  server_name ${SUBDOMAIN};
  ssl_certificate           /etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem;
  ssl_certificate_key       /etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem;
  ssl_trusted_certificate   /etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem;
  ssl_dhparam               /etc/nginx/dhparam.pem;
  root /var/www/${SUBDOMAIN}/;
  index index.html;
}
EOF

  # http: РЕДИРЕКТЫ ДЛЯ КАЖДОГО xhttp-домена НА ЗАГЛУШКУ (80→HTTPS SUBDOMAIN)
  : > /etc/nginx/conf.d/xhttp-redirects.conf
  if [ "${#XHTTP_SNI[@]}" -gt 0 ]; then
    for d in "${XHTTP_SNI[@]}"; do
      cat >> /etc/nginx/conf.d/xhttp-redirects.conf <<EOF
server {
  listen 80;
  server_name ${d};
  location / { return 301 https://${SUBDOMAIN}\$request_uri; }
}
EOF
    done
  fi

  # контент заглушки (ровно тот, что ты хотел)
  mkdir -p /var/www/${SUBDOMAIN}
  cat > /var/www/${SUBDOMAIN}/index.html <<'EOF'
<!DOCTYPE html> <html lang="en"> <head> <meta charset="UTF-8"> <meta name="viewport" content="width=device-width, initial-scale=1.0"> <title>Cloud Storage - Login</title> <style> body { font-family: Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 0; display: flex; justify-content: center; align-items: center; height: 100vh; } .login-container { background-color: white; padding: 40px; border-radius: 10px; box-shadow: 0 0 20px rgba(0, 0, 0, 0.1); width: 100%; max-width: 400px; } .login-header { text-align: center; margin-bottom: 30px; } .login-header h1 { color: #333; margin: 0; font-size: 24px; } .form-group { margin-bottom: 20px; } .form-group label { display: block; margin-bottom: 5px; color: #666; } .form-group input { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 5px; box-sizing: border-box; } .submit-btn { width: 100%; padding: 12px; background-color: #007bff; color: white; border: none; border-radius: 5px; cursor: pointer; font-size: 16px; } .submit-btn:hover { background-color: #0056b3; } .footer { text-align: center; margin-top: 20px; color: #666; font-size: 14px; } </style> </head> <body> <div class="login-container"> <div class="login-header"> <h1>Cloud Storage</h1> </div> <form action="#" method="POST" onsubmit="return false;"> <div class="form-group"> <label for="email">Email</label> <input type="email" id="email" name="email" required> </div> <div class="form-group"> <label for="password">Password</label> <input type="password" id="password" name="password" required> </div> <button type="submit" class="submit-btn">Log In</button> </form> <div class="footer"> <p>Protected by CloudFlare</p> </div> </div> </body> </html>
EOF
  chown -R www-data:www-data /var/www/${SUBDOMAIN}
  chmod -R 755 /var/www/${SUBDOMAIN}
}

# «else»-режим (ваша прежняя схема, без proxy_protocol для совместимости)
write_nginx_else_with_site() {
  mkdir -p /etc/nginx/stream-enabled
cat > /etc/nginx/stream-enabled/stream.conf <<EOF
map \$ssl_preread_server_name \$backend {
  default block;
  ${SUBDOMAIN} web;
}
upstream block { server 127.0.0.1:36076; }
upstream web   { server 127.0.0.1:7443; }
upstream xtls  { server 127.0.0.1:8443; }
server {
  listen 443 reuseport;
  ssl_preread on;
  proxy_pass \$backend;
}
EOF

cat > /etc/nginx/conf.d/local.conf <<EOF
server {
  listen 80;
  server_name ${SUBDOMAIN};
  location / { return 301 https://${SUBDOMAIN}\$request_uri; }
}
server {
  listen 9090 default_server;
  server_name ${SUBDOMAIN};
  location / { return 301 https://${SUBDOMAIN}\$request_uri; }
}
server {
  listen 36076 ssl;
  ssl_reject_handshake on;
}
server {
  listen 36077 ssl http2;
  server_name ${SUBDOMAIN};
  ssl_certificate           /etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem;
  ssl_certificate_key       /etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem;
  ssl_trusted_certificate   /etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem;
  ssl_dhparam               /etc/nginx/dhparam.pem;
  root /var/www/${SUBDOMAIN}/;
  index index.html;
}
EOF

mkdir -p /var/www/${SUBDOMAIN}
cat > /var/www/${SUBDOMAIN}/index.html <<'EOF'
<!DOCTYPE html> <html lang="en"> <head> <meta charset="UTF-8"> <meta name="viewport" content="width=device-width, initial-scale=1.0"> <title>Cloud Storage - Login</title> <style> body { font-family: Arial, sans-serif; background-color: #f5f5f5; margin: 0; padding: 0; display: flex; justify-content: center; align-items: center; height: 100vh; } .login-container { background-color: white; padding: 40px; border-radius: 10px; box-shadow: 0 0 20px rgba(0, 0, 0, 0.1); width: 100%; max-width: 400px; } .login-header { text-align: center; margin-bottom: 30px; } .login-header h1 { color: #333; margin: 0; font-size: 24px; } .form-group { margin-bottom: 20px; } .form-group label { display: block; margin-bottom: 5px; color: #666; } .form-group input { width: 100%; padding: 10px; border: 1px solid #ddd; border-radius: 5px; box-sizing: border-box; } .submit-btn { width: 100%; padding: 12px; background-color: #007bff; color: white; border: none; border-radius: 5px; cursor: pointer; font-size: 16px; } .submit-btn:hover { background-color: #0056b3; } .footer { text-align: center; margin-top: 20px; color: #666; font-size: 14px; } </style> </head> <body> <div class="login-container"> <div class="login-header"> <h1>Cloud Storage</h1> </div> <form action="#" method="POST" onsubmit="return false;"> <div class="form-group"> <label for="email">Email</label> <input type="email" id="email" name="email" required> </div> <div class="form-group"> <label for="password">Password</label> <input type="password" id="password" name="password" required> </div> <button type="submit" class="submit-btn">Log In</button> </form> <div class="footer"> <p>Protected by CloudFlare</p> </div> </div> </body> </html>
EOF
chown -R www-data:www-data /var/www/${SUBDOMAIN}
chmod -R 755 /var/www/${SUBDOMAIN}
}

# Применяем
log "Генерация конфигов nginx..."
mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup 2>/dev/null || true
mkdir -p /etc/nginx/stream-enabled
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true
write_nginx_common_conf
if $XHTTP_MODE; then write_nginx_xhttp_with_stub; else write_nginx_else_with_site; fi

# ==================== Marzban Node ====================
log "Установка Marzban Node..."
curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban-node.sh -o /root/marzban-node.sh
chmod +x /root/marzban-node.sh

export CERT_BODY SERVICE_PORT API_PORT NODE_NAME
expect <<'EOF'
set timeout -1
spawn /root/marzban-node.sh @ install --name $env(NODE_NAME)
# Вставка клиентского сертификата
expect -re {Please paste .* Client Certificate}
send -- "-----BEGIN CERTIFICATE-----\r"
send -- "$env(CERT_BODY)\r"
send -- "-----END CERTIFICATE-----\r\r"
# Включаем REST
expect -re {(Do you want to use REST protocol\?.*)}
send -- "y\r"
# Порты
expect -re {Enter the SERVICE_PORT.*}
send -- "$env(SERVICE_PORT)\r"
expect -re {Enter the XRAY_API_PORT.*}
send -- "$env(API_PORT)\r"
expect eof
EOF
rm -f /root/marzban-node.sh

# Логи
mkdir -p /var/lib/marzban/log
touch /var/lib/marzban/log/access.log
chmod 755 /var/lib/marzban/log
chmod 644 /var/lib/marzban/log/access.log

DOCKER_COMPOSE_FILE="/opt/${NODE_NAME}/docker-compose.yml"
if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
  if ! grep -q "/var/lib/marzban/log" "$DOCKER_COMPOSE_FILE"; then
    sed -i '/volumes:/a\      - /var/lib/marzban/log:/var/lib/marzban/log' "$DOCKER_COMPOSE_FILE"
  fi
  pushd "/opt/${NODE_NAME}" >/dev/null
  docker compose down
  docker compose up -d
  popd >/dev/null
else
  warn "docker-compose.yml не найден — монтирование логов пропущено"
fi

# ==================== Проверка NGINX ====================
nginx -t 2>&1 | while read -r l; do dbg "$l"; done
systemctl enable nginx
systemctl restart nginx
systemctl is-active --quiet nginx || err "Nginx не запустился"

# ==================== UFW ====================
log "Настройка UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp
ufw allow 80/tcp
ufw allow 443/tcp
# REST/API только с MASTER_IP (IPv4). Если используете IPv6, добавьте отдельные v6-правила.
ufw allow from ${MASTER_IP} to any port ${SERVICE_PORT} proto tcp
ufw allow from ${MASTER_IP} to any port ${API_PORT} proto tcp
yes | ufw enable
ufw status verbose | while read -r l; do dbg "$l"; done

# ==================== SSH ====================
log "Настройка SSH..."
if $INSTALL_SSH_KEY; then
  mkdir -p /root/.ssh; chmod 700 /root/.ssh
  printf "%s\n" "${SSH_KEY}" > /root/.ssh/authorized_keys
  cat > /etc/ssh/sshd_config <<EOF
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
  systemctl is-active --quiet ssh || err "SSH не запустился"
else
  if ! grep -q "^Port " /etc/ssh/sshd_config; then
    sed -i "1i Port ${SSH_PORT}" /etc/ssh/sshd_config
  else
    sed -i "s/^Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
  fi
  systemctl restart ssh || true
fi

log "Готово. Заглушка: https://${SUBDOMAIN}"
log "Напоминание: при наличии AAAA-записи для домена добавьте IPv6-правила UFW на ${SERVICE_PORT}/${API_PORT}, либо уберите AAAA."

read -p "Перезагрузить систему сейчас? (y/n): " reboot_now
[[ $reboot_now =~ ^[Yy]$ ]] && { dbg "Перезагрузка..."; reboot; }
