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
echo ""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARNING]${NC} $*"; }
debug()  { echo -e "[DEBUG] $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

trap 'error "Неожиданная ошибка на строке $LINENO"' ERR

# ======================== Docker Compose v2 auto-install ========================
install_docker_compose_v2() {
  local plugin_dir="/usr/local/lib/docker/cli-plugins"
  local plugin_path="${plugin_dir}/docker-compose"

  mkdir -p "${plugin_dir}"

  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) error "Неподдерживаемая архитектура: ${arch}" ;;
  esac

  log "Установка свежего Docker Compose v2 (plugin) для ${arch}..."
  curl -fsSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" \
    -o "${plugin_path}" || error "Не удалось скачать docker-compose v2 plugin"

  chmod +x "${plugin_path}"

  # На некоторых системах docker ищет плагины и тут
  mkdir -p /usr/lib/docker/cli-plugins
  cp -f "${plugin_path}" /usr/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/lib/docker/cli-plugins/docker-compose

  docker compose version >/dev/null 2>&1 || error "docker compose всё ещё недоступен после установки плагина"
  debug "OK: $(docker compose version 2>/dev/null | head -n 1)"
}

require_docker_and_compose_v2() {
  command -v docker >/dev/null 2>&1 || error "docker не найден"
  docker version >/dev/null 2>&1 || error "Docker daemon недоступен (проверь: systemctl status docker)"

  if ! docker compose version >/dev/null 2>&1; then
    install_docker_compose_v2
  fi
}

# ======================== Выбор DNS-провайдера ========================
while true; do
  echo -e "${YELLOW}Выберите DNS-провайдера для выпуска wildcard сертификата:${NC}"
  echo "1) deSEC.io"
  echo "2) Gcore DNS"
  read -p "Введите номер (1 или 2): " DNS_PROVIDER_NUM

  if [[ "$DNS_PROVIDER_NUM" == "1" ]]; then
    DNS_PROVIDER="desec"
    DNS_API="dns_desec"
    while true; do
      read -p "Введите deSEC API-токен: " DNS_TOKEN
      [[ -z "$DNS_TOKEN" ]] && { warn "Токен не может быть пустым."; continue; }
      break
    done
    export DEDYN_TOKEN="$DNS_TOKEN"
    break
  elif [[ "$DNS_PROVIDER_NUM" == "2" ]]; then
    DNS_PROVIDER="gcore"
    DNS_API="dns_gcore"
    while true; do
      read -p "Введите Gcore API-ключ (поле API Key из Gcore, права на DNS): " DNS_TOKEN
      [[ -z "$DNS_TOKEN" ]] && { warn "Ключ не может быть пустым."; continue; }
      break
    done
    export GCORE_Key="$DNS_TOKEN"
    break
  else
    warn "Только 1 (deSEC.io) или 2 (Gcore DNS)"
  fi
done

# ======================== Выбор протокола транспорта ========================
while true; do
  read -p "Выберите протокол транспорта для узла (xhttp/else) [else]: " TRANSPORT_PROTO
  TRANSPORT_PROTO=${TRANSPORT_PROTO:-else}
  case "$TRANSPORT_PROTO" in
    xhttp) XHTTP_MODE=true;  break ;;
    else)  XHTTP_MODE=false; break ;;
    *) echo "Допустимые значения: xhttp или else" ;;
  esac
done

# ======================== Параметры ========================
read -p "Установить BBR и Xanmod Kernel? (y/n): " ans_bbr
INSTALL_BBR=false; [[ $ans_bbr =~ ^[Yy] ]] && INSTALL_BBR=true

read -p "Настроить SSH ключ? (y/n): " ans_sshkey
INSTALL_SSH_KEY=false; [[ $ans_sshkey =~ ^[Yy] ]] && INSTALL_SSH_KEY=true

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
    warn "Некорректный порт. Введите число от 1 до 65535"
  fi
done

while true; do
  read -p "Введите IP адрес мастер-ноды: " MASTER_IP
  if [[ $MASTER_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    break
  else
    warn "Некорректный формат IP адреса. Попробуйте снова."
  fi
done

if $INSTALL_SSH_KEY; then
  while true; do
    log "Введите ваш публичный SSH ключ (должен начинаться с 'ssh-rsa' или 'ssh-ed25519'):"
    read -r SSH_KEY
    if [[ -z "$SSH_KEY" ]]; then
      warn "SSH ключ не может быть пустым."
    elif [[ "$SSH_KEY" =~ ^(ssh-rsa|ssh-ed25519)[[:space:]].*$ ]]; then
      break
    else
      warn "Некорректный формат SSH ключа."
    fi
  done
fi

while true; do
  read -p "Введите субдомен (например, us.domain.com): " SUBDOMAIN
  [[ -z "$SUBDOMAIN" ]] && { warn "Субдомен не может быть пустым."; continue; }
  break
done

while true; do
  read -p "Введите имя ноды (например, us-node-1): " NODE_NAME
  [[ -z "$NODE_NAME" ]] && { warn "Имя ноды не может быть пустым."; continue; }
  break
done

while true; do
  read -p "Введите email для Let's Encrypt (обязательно, не фейк): " LE_EMAIL
  [[ -z "$LE_EMAIL" ]] && { warn "Email не может быть пустым."; continue; }
  break
done

read -p "Введите порт для сервиса (по умолчанию 62050): " SERVICE_PORT
SERVICE_PORT=${SERVICE_PORT:-62050}

read -p "Введите порт для API (по умолчанию 62051): " API_PORT
API_PORT=${API_PORT:-62051}

if $XHTTP_MODE; then
  echo
  echo "Укажи домены, которые должны идти в XHTTP (через пробел)."
  echo "Если оставить пустым — XHTTP-роутинг по 443 будет только для явно указанных позже."
  read -r XHTTP_SNI_LINE || true
  read -ra XHTTP_SNI <<< "${XHTTP_SNI_LINE:-}"
fi

log "Введите SSL client сертификат (после Enter нажми Ctrl+D для завершения ввода):"
SSL_CERT="$(cat)"

if [[ -z "${SSL_CERT}" ]]; then
  error "SSL сертификат не может быть пустым."
fi

# Проверка PEM
echo "${SSL_CERT}" | grep -q "BEGIN CERTIFICATE" || error "В сертификате нет BEGIN CERTIFICATE"
echo "${SSL_CERT}" | grep -q "END CERTIFICATE"   || error "В сертификате нет END CERTIFICATE"

debug "Субдомен: ${SUBDOMAIN}"
debug "Название ноды: ${NODE_NAME}"
debug "Service port: ${SERVICE_PORT}"
debug "API port: ${API_PORT}"

MAIN_DOMAIN="$(echo "${SUBDOMAIN}" | awk -F. '{print $(NF-1)"."$NF}')"
debug "Основной домен: ${MAIN_DOMAIN}"

# ======================== Установка системных компонентов ========================
log "Системные компоненты..."
apt update 2>&1 | while read -r line; do debug "$line"; done
apt upgrade -y 2>&1 | while read -r line; do debug "$line"; done || error "Ошибка при обновлении системы"
apt install -y curl wget git expect ufw openssl lsb-release ca-certificates gnupg2 ubuntu-keyring socat 2>&1 \
  | while read -r line; do debug "$line"; done || error "Ошибка при установке базовых пакетов"

# Проверим docker и поставим compose v2
require_docker_and_compose_v2

# ======================== Опциональная установка BBR ========================
if $INSTALL_BBR; then
  log "Установка BBRv3..."
  curl -s https://raw.githubusercontent.com/opiran-club/VPS-Optimizer/main/bbrv3.sh --ipv4 > /root/bbrv3.sh || error "Ошибка при скачивании BBRv3"
  chmod +x /root/bbrv3.sh
  expect << 'EOF'
spawn bash /root/bbrv3.sh
expect "Enter"
send "1\r"
expect "y/n"
send "y\r"
expect eof
EOF
  rm -f /root/bbrv3.sh
else
  debug "BBR не устанавливается."
fi

# ======================== NGINX + acme.sh ========================
log "Установка NGINX и acme.sh..."
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" \
  | tee /etc/apt/sources.list.d/nginx.list >/dev/null

cat >/etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF

apt update 2>&1 | while read -r line; do debug "$line"; done
apt install -y nginx || error "Ошибка при установке Nginx"
mkdir -p /etc/nginx
openssl dhparam -out /etc/nginx/dhparam.pem 2048 || error "Ошибка при генерации dhparam"

log "Установка/обновление acme.sh..."
curl -fsSL https://get.acme.sh | sh || error "Ошибка при установке acme.sh"
export HOME="/root"
. /root/.acme.sh/acme.sh.env

/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

log "Регистрация аккаунта Let's Encrypt через acme.sh..."
/root/.acme.sh/acme.sh --register-account -m "${LE_EMAIL}" --server letsencrypt || warn "Аккаунт LE уже зарегистрирован"

log "Выпуск wildcard SSL для ${MAIN_DOMAIN} и *.${MAIN_DOMAIN} через ${DNS_PROVIDER}..."
/root/.acme.sh/acme.sh --issue --dns "${DNS_API}" -d "${MAIN_DOMAIN}" -d "*.${MAIN_DOMAIN}" \
  --keylength ec-256 --dnssleep 120 --force --home /root/.acme.sh \
  || error "Не удалось получить wildcard сертификат через ${DNS_PROVIDER}"

mkdir -p "/etc/letsencrypt/live/${MAIN_DOMAIN}"
cp "/root/.acme.sh/${MAIN_DOMAIN}_ecc/${MAIN_DOMAIN}.key" "/etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem"
cp "/root/.acme.sh/${MAIN_DOMAIN}_ecc/fullchain.cer"      "/etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem"
cp "/root/.acme.sh/${MAIN_DOMAIN}_ecc/ca.cer"             "/etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem"

# ======================== Функции генерации конфигов Nginx ========================
write_nginx_common_conf() {
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
}

write_nginx_xhttp_with_stub() {
  mkdir -p /etc/nginx/stream-enabled

  local -a XHTTP_SNI_CLEAN=()
  if [ "${#XHTTP_SNI[@]}" -gt 0 ]; then
    for d in "${XHTTP_SNI[@]}"; do
      [[ -n "$d" && "$d" != "$SUBDOMAIN" ]] && XHTTP_SNI_CLEAN+=("$d")
    done
  fi

  {
    echo 'map $ssl_preread_server_name $backend {'
    echo '    default block;'
    echo "    ${SUBDOMAIN} web;"
    if [ "${#XHTTP_SNI_CLEAN[@]}" -gt 0 ]; then
      for d in "${XHTTP_SNI_CLEAN[@]}"; do
        echo "    ${d} xhttp;"
      done
    fi
    echo '}'
    echo
    echo 'upstream block { server 127.0.0.1:36076; }'
    echo 'upstream xhttp  { server 127.0.0.1:5443;  }'
    echo 'upstream web    { server 127.0.0.1:36077; }'
    echo 'server {'
    echo '    listen 443 reuseport;'
    echo '    ssl_preread on;'
    echo '    proxy_pass $backend;'
    echo '}'
  } > /etc/nginx/stream-enabled/stream.conf

  {
cat <<EOF
server {
    listen 80;
    server_name ${SUBDOMAIN};
    location / { return 301 https://${SUBDOMAIN}\$request_uri; }
}
EOF

    if [ "${#XHTTP_SNI_CLEAN[@]}" -gt 0 ]; then
      for d in "${XHTTP_SNI_CLEAN[@]}"; do
cat <<EOF
server {
    listen 80;
    server_name ${d};
    location / { return 301 https://${SUBDOMAIN}\$request_uri; }
}
EOF
      done
    fi

cat <<EOF
server {
    listen 36076 ssl;
    ssl_reject_handshake on;
}
EOF

    local ALL_SRV_NAMES="${SUBDOMAIN}"
    if [ "${#XHTTP_SNI_CLEAN[@]}" -gt 0 ]; then
      ALL_SRV_NAMES="${ALL_SRV_NAMES} ${XHTTP_SNI_CLEAN[*]}"
    fi

cat <<EOF
server {
    listen 127.0.0.1:36077 ssl http2;
    server_name ${ALL_SRV_NAMES};
    ssl_certificate         /etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem;
    ssl_dhparam             /etc/nginx/dhparam.pem;

    if (\$host != "${SUBDOMAIN}") {
        return 301 https://${SUBDOMAIN}\$request_uri;
    }

    index index.html;
    root  /var/www/${SUBDOMAIN}/;
}
EOF
  } > /etc/nginx/conf.d/local.conf

  mkdir -p "/var/www/${SUBDOMAIN}"
  if [ ! -f "/var/www/${SUBDOMAIN}/index.html" ]; then
cat > "/var/www/${SUBDOMAIN}/index.html" <<'EOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Cloud Login</title></head><body style="background:#0f1220;color:#e8e8ea;font-family:system-ui,Arial,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0"><div style="max-width:420px;padding:22px;border-radius:16px;background:#171a2a;border:1px solid #2a3052;box-shadow:0 10px 30px rgba(0,0,0,.4)"><h1 style="margin:0 0 8px">Вход в облако</h1><p style="margin:0 0 12px;color:#9aa3b2">Авторизуйтесь для продолжения</p><input style="width:100%;padding:12px;border-radius:10px;border:1px solid #2a3052;background:#0f142a;color:#fff;margin:6px 0" placeholder="email@example.com"><input type="password" style="width:100%;padding:12px;border-radius:10px;border:1px solid #2a3052;background:#0f142a;color:#fff;margin:6px 0" placeholder="••••••••"><button style="width:100%;padding:12px;border-radius:10px;border:1px solid #33406d;background:#25305a;color:#fff;font-weight:700;margin-top:8px">Войти</button><div style="margin-top:10px;color:#7f89a1;font-size:12px;text-align:center">© Cloud Systems</div></div></body></html>
EOF
  fi

  chown -R www-data:www-data "/var/www/${SUBDOMAIN}"
  chmod -R 755 "/var/www/${SUBDOMAIN}"
}

write_nginx_else_with_site() {
  mkdir -p /etc/nginx/stream-enabled

cat > /etc/nginx/stream-enabled/stream.conf <<EOF
map \$ssl_preread_server_name \$backend {
    default block;
    ${SUBDOMAIN} web;
}
upstream block { server 127.0.0.1:36076; }
upstream web   { server 127.0.0.1:7443; }

server {
    listen 443 reuseport;
    ssl_preread on;
    proxy_protocol on;
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
    listen 36076 ssl proxy_protocol;
    ssl_reject_handshake on;
}
server {
    listen 36077 ssl proxy_protocol;
    http2 on;
    server_name ${SUBDOMAIN};
    ssl_certificate         /etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem;
    ssl_dhparam             /etc/nginx/dhparam.pem;
    index index.html;
    root  /var/www/${SUBDOMAIN}/;
}
EOF

  mkdir -p "/var/www/${SUBDOMAIN}"
  if [ ! -f "/var/www/${SUBDOMAIN}/index.html" ]; then
cat > "/var/www/${SUBDOMAIN}/index.html" <<'EOF'
<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>Cloud Login</title></head><body style="background:#0f1220;color:#e8e8ea;font-family:system-ui,Arial,sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0"><div style="max-width:420px;padding:22px;border-radius:16px;background:#171a2a;border:1px solid #2a3052;box-shadow:0 10px 30px rgba(0,0,0,.4)"><h1 style="margin:0 0 8px">Вход в облако</h1><p style="margin:0 0 12px;color:#9aa3b2">Авторизуйтесь для продолжения</p><input style="width:100%;padding:12px;border-radius:10px;border:1px solid #2a3052;background:#0f142a;color:#fff;margin:6px 0" placeholder="email@example.com"><input type="password" style="width:100%;padding:12px;border-radius:10px;border:1px solid #2a3052;background:#0f142a;color:#fff;margin:6px 0" placeholder="••••••••"><button style="width:100%;padding:12px;border-radius:10px;border:1px solid #33406d;background:#25305a;color:#fff;font-weight:700;margin-top:8px">Войти</button><div style="margin-top:10px;color:#7f89a1;font-size:12px;text-align:center">© Cloud Systems</div></div></body></html>
EOF
  fi

  chown -R www-data:www-data "/var/www/${SUBDOMAIN}"
  chmod -R 755 "/var/www/${SUBDOMAIN}"
}

# ======================== Генерация конфигов Nginx ========================
log "Nginx конфиг..."
mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.backup 2>/dev/null || true
mkdir -p /etc/nginx/stream-enabled
rm -f /etc/nginx/conf.d/default.conf 2>/dev/null || true

write_nginx_common_conf
if $XHTTP_MODE; then
  write_nginx_xhttp_with_stub
else
  write_nginx_else_with_site
fi

nginx -t 2>&1 | while read -r l; do debug "$l"; done
systemctl enable nginx
systemctl restart nginx
systemctl is-active --quiet nginx || error "Nginx не запустился"

# ======================== Установка Marzban Node ========================
log "==================== УСТАНОВКА MARZBAN NODE ===================="
log "Этап 3: Установка Marzban Node..."

require_docker_and_compose_v2

WORKDIR="/opt/${NODE_NAME}"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

curl -fsSL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban-node.sh -o marzban-node.sh
chmod +x marzban-node.sh

# Уберём возможные конфликтующие контейнеры/хвосты
docker rm -f "${NODE_NAME}" 2>/dev/null || true
docker rm -f "$(docker ps -aq --filter "name=${NODE_NAME}")" 2>/dev/null || true

# Передадим сертификат в expect как есть
export CERT_RAW="${SSL_CERT}"
export NODE_NAME SERVICE_PORT API_PORT

expect << 'EOF'
log_user 1
set timeout 600

spawn ./marzban-node.sh @ install --name $env(NODE_NAME)

expect {
  -re "already installed" { exp_continue }
  -re "override.*\\(y/n\\)" { send -- "y\r"; exp_continue }
  -re "Please paste the content of the Client Certificate" {
      send -- "$env(CERT_RAW)\r"
      send -- "\r"
      exp_continue
  }
  -re "Do you want to use REST protocol" { send -- "y\r"; exp_continue }
  -re "Enter the SERVICE_PORT" { send -- "$env(SERVICE_PORT)\r"; exp_continue }
  -re "Enter the XRAY_API_PORT" { send -- "$env(API_PORT)\r"; exp_continue }
  eof
}
EOF

rm -f marzban-node.sh

# Добавим монтирование логов в compose и перезапустим
DOCKER_COMPOSE_FILE="/opt/${NODE_NAME}/docker-compose.yml"
mkdir -p /var/lib/marzban/log
touch /var/lib/marzban/log/access.log
chmod 755 /var/lib/marzban/log
chmod 644 /var/lib/marzban/log/access.log

if [[ -f "${DOCKER_COMPOSE_FILE}" ]]; then
  # добавим volume, если его ещё нет
  if ! grep -q "/var/lib/marzban/log:/var/lib/marzban/log" "${DOCKER_COMPOSE_FILE}"; then
    # если volumes: есть — допишем; если нет — создадим в сервисе
    if grep -qE '^\s*volumes:\s*$' "${DOCKER_COMPOSE_FILE}"; then
      sed -i '/^\s*volumes:\s*$/a\      - /var/lib/marzban/log:/var/lib/marzban/log' "${DOCKER_COMPOSE_FILE}"
    else
      # попробуем вставить после container_name или image в первом сервисе (аккуратно)
      sed -i '0,/^\s*image:\s*/s//&\n    volumes:\n      - \/var\/lib\/marzban\/log:\/var\/lib\/marzban\/log\n/' "${DOCKER_COMPOSE_FILE}"
    fi
  fi

  cd "/opt/${NODE_NAME}"
  docker compose down --remove-orphans || true
  docker compose up -d
else
  warn "Файл docker-compose.yml не найден, пропуск настройки монтирования логов."
fi

# ======================== Финальные проверки и настройки ========================
log "==================== ФИНАЛЬНЫЕ ПРОВЕРКИ ===================="
nginx -t 2>&1 | while read -r line; do debug "$line"; done || error "Ошибка в конфигурации Nginx"

systemctl enable nginx 2>&1 | while read -r line; do debug "$line"; done
systemctl start nginx 2>&1 | while read -r line; do debug "$line"; done
systemctl is-active --quiet nginx || error "Не удалось запустить Nginx"

log "Настройка UFW..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow "${SSH_PORT}/tcp"
ufw allow from "${MASTER_IP}"
echo "y" | ufw enable
ufw status verbose || error "Ошибка при настройке UFW"

log "Настройка SSH..."
if $INSTALL_SSH_KEY; then
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  cat > /root/.ssh/authorized_keys <<EOF
${SSH_KEY}
EOF
  chmod 600 /root/.ssh/authorized_keys

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
  systemctl is-active --quiet ssh || error "Не удалось запустить SSH"
fi

log "Установка успешно завершена!"
debug "Compose: $(docker compose version 2>/dev/null | head -n 1)"
debug "Node dir: /opt/${NODE_NAME}"
debug "Compose file: ${DOCKER_COMPOSE_FILE}"

read -p "Перезагрузить систему сейчас? (y/n): " reboot_now
if [[ "${reboot_now}" == "y" ]]; then
  debug "Выполняется перезагрузка системы..."
  reboot
fi
