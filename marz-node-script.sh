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

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
debug() { echo -e "[DEBUG] $1"; }
# --- совместимость лог-функций / алиасы ---
if ! declare -F debug >/dev/null 2>&1; then debug(){ echo -e "[DEBUG] $*"; } fi
if ! declare -F warn  >/dev/null 2>&1; then warn(){  echo -e "${YELLOW:-}[WARNING]${NC:-} $*"; } fi
if ! declare -F warning >/dev/null 2>&1; then warning(){ warn "$@"; } fi
if ! declare -F dbg >/dev/null 2>&1; then dbg(){ debug "$@"; } fi
if ! declare -F error >/dev/null 2>&1; then
  if declare -F err >/dev/null 2>&1; then error(){ err "$@"; }
  else error(){ echo -e "${RED:-}[ERROR]${NC:-} $*"; exit 1; }
  fi
fi

# если нет debug(), делаем no-op с меткой
if ! declare -F debug >/dev/null 2>&1; then
  debug(){ echo -e "[DEBUG] $*"; }
fi
# выравниваем warn/warning
if ! declare -F warn >/dev/null 2>&1; then
  warn(){ echo -e "${YELLOW:-}[WARNING]${NC:-} $*"; }
fi
if ! declare -F warning >/dev/null 2>&1; then
  warning(){ warn "$@"; }
fi
# выравниваем error/err (что бы ни было — оба работают)
if ! declare -F error >/dev/null 2>&1; then
  if declare -F err >/dev/null 2>&1; then
    error(){ err "$@"; }
  else
    error(){ echo -e "${RED:-}[ERROR]${NC:-} $*"; exit 1; }
  fi
fi

# если нет debug(), делаем no-op с меткой
if ! declare -F debug >/dev/null 2>&1; then
  debug(){ echo -e "[DEBUG] $*"; }
fi
# выравниваем warn/warning
if ! declare -F warn >/dev/null 2>&1; then
  warn(){ echo -e "${YELLOW:-}[WARNING]${NC:-} $*"; }
fi
if ! declare -F warning >/dev/null 2>&1; then
  warning(){ warn "$@"; }
fi
# выравниваем error/err (что бы ни было — оба работают)
if ! declare -F error >/dev/null 2>&1; then
  if declare -F err >/dev/null 2>&1; then
    error(){ err "$@"; }
  else
    error(){ echo -e "${RED:-}[ERROR]${NC:-} $*"; exit 1; }
  fi
fi

trap 'error "Неожиданная ошибка на строке $LINENO"' ERR

# ======================== Выбор DNS-провайдера ========================
while true; do
    echo -e "${YELLOW}Выберите DNS-провайдера для выпуска wildcard сертификата:"
    echo "1) deSEC.io"
    echo "2) Gcore DNS"
    read -p "Введите номер (1 или 2): " DNS_PROVIDER_NUM
    if [[ "$DNS_PROVIDER_NUM" == "1" ]]; then
        DNS_PROVIDER="desec"
        DNS_API="dns_desec"
        while true; do
            read -p "Введите deSEC API-токен: " DNS_TOKEN
            [[ -z "$DNS_TOKEN" ]] && { warning "Токен не может быть пустым."; continue; }
            break
        done
        export DEDYN_TOKEN="$DNS_TOKEN"
        break
    elif [[ "$DNS_PROVIDER_NUM" == "2" ]]; then
        DNS_PROVIDER="gcore"
        DNS_API="dns_gcore"
        while true; do
            read -p "Введите Gcore API-ключ (поле API Key из Gcore, права на DNS): " DNS_TOKEN
            [[ -z "$DNS_TOKEN" ]] && { warning "Ключ не может быть пустым."; continue; }
            break
        done
        export GCORE_Key="$DNS_TOKEN"
        break
    else
        warning "Только 1 (deSEC.io) или 2 (Gcore DNS)"
    fi
done

# ======================== Выбор протокола транспорта ========================
while true; do
    read -p "Выберите протокол транспорта для узла (xhttp/else) [else]: " TRANSPORT_PROTO
    TRANSPORT_PROTO=${TRANSPORT_PROTO:-else}
    case "$TRANSPORT_PROTO" in
        xhttp) XHTTP_MODE=true;  break ;;
        else)  XHTTP_MODE=false; break ;;
        *) echo "Допустимые значения: xhttp или else";;
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

if $XHTTP_MODE; then
    echo
    echo "Укажи домены, которые должны идти в XHTTP (через пробел)."
    echo "Если оставить пустым — XHTTP-роутинг по 443 будет только для явно указанных позже (по умолчанию всё, кроме ${SUBDOMAIN}, попадёт в блок)."
    read -r XHTTP_SNI_LINE || true
    # нормализуем в массив
    read -ra XHTTP_SNI <<< "${XHTTP_SNI_LINE:-}"
fi

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

log "Установка NGINX и acme.sh..."
curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
gpg --dry-run --quiet --no-keyring --import --import-options import-show /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/ubuntu $(lsb_release -cs) nginx" | tee /etc/apt/sources.list.d/nginx.list >/dev/null
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

# acme.sh install/update
log "Установка/обновление acme.sh..."
curl -fsSL https://get.acme.sh | sh || error "Ошибка при установке acme.sh"
export LE_EMAIL="${LE_EMAIL}"
export HOME="/root"
. /root/.acme.sh/acme.sh.env

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt

log "Регистрация аккаунта Let's Encrypt через acme.sh..."
~/.acme.sh/acme.sh --register-account -m "${LE_EMAIL}" --server letsencrypt || warning "Аккаунт LE уже зарегистрирован"

log "Выпуск wildcard SSL для ${MAIN_DOMAIN} и *.${MAIN_DOMAIN} через $DNS_PROVIDER..."
~/.acme.sh/acme.sh --issue --dns $DNS_API -d "${MAIN_DOMAIN}" -d "*.${MAIN_DOMAIN}" --keylength ec-256 --dnssleep 120 --force --home /root/.acme.sh || error "Не удалось получить wildcard сертификат через $DNS_PROVIDER"

mkdir -p /etc/letsencrypt/live/${MAIN_DOMAIN}
cp /root/.acme.sh/${MAIN_DOMAIN}_ecc/${MAIN_DOMAIN}.key /etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem
cp /root/.acme.sh/${MAIN_DOMAIN}_ecc/fullchain.cer /etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem
cp /root/.acme.sh/${MAIN_DOMAIN}_ecc/ca.cer /etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem

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

write_nginx_https_stub_no_stream() {
  local www_root="${WWW_ROOT:-/var/www/${SUBDOMAIN}}"

  mkdir -p /etc/nginx/conf.d
  mkdir -p "${www_root}"

  # ----- /etc/nginx/conf.d/local.conf -----
  {
    # HTTP :80 → 301 на основной SUBDOMAIN
    cat <<EOF
server {
    listen 80;
    server_name ${SUBDOMAIN};
    location / { return 301 https://${SUBDOMAIN}\$request_uri; }
}
EOF

    if [ "${#REDIRECT_SNI[@]}" -gt 0 ]; then
      for d in "${REDIRECT_SNI[@]}"; do
        [ -n "$d" ] || continue
        cat <<EOF
server {
    listen 80;
    server_name ${d};
    location / { return 301 https://${SUBDOMAIN}\$request_uri; }
}
EOF
      done
    fi

    # L4-заглушка (как у тебя): «намеренный reject» на отдельном порту
    cat <<'EOF'
server {
    listen 36076 ssl;
    ssl_reject_handshake on;
}
EOF

    # HTTPS 443: основной хост со статикой
    cat <<EOF
server {
    listen 443 ssl http2;
    server_name ${SUBDOMAIN};

    ssl_certificate         /etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem;
    ssl_dhparam             /etc/nginx/dhparam.pem;

    root  ${www_root};
    index index.html;
}
EOF

    # HTTPS 443: для каждого редиректного хоста — сразу 301 на SUBDOMAIN
    if [ "${#REDIRECT_SNI[@]}" -gt 0 ]; then
      for d in "${REDIRECT_SNI[@]}"; do
        [ -n "$d" ] || continue
        cat <<EOF
server {
    listen 443 ssl http2;
    server_name ${d};

    ssl_certificate         /etc/letsencrypt/live/${MAIN_DOMAIN}/fullchain.pem;
    ssl_certificate_key     /etc/letsencrypt/live/${MAIN_DOMAIN}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${MAIN_DOMAIN}/chain.pem;
    ssl_dhparam             /etc/nginx/dhparam.pem;

    return 301 https://${SUBDOMAIN}\$request_uri;
}
EOF
      done
    fi
  } > /etc/nginx/conf.d/local.conf

  # КРИТИЧЕСКОЕ: убедимся, что stream на 443 НЕ включён.
  # Если у тебя есть /etc/nginx/stream-enabled/stream.conf со слушателем 443 — отключи его:
  if grep -qE 'listen[[:space:]]+443' /etc/nginx/stream-enabled/stream.conf 2>/dev/null; then
    echo "[warn] Обнаружен stream 443. Комментирую, чтобы избежать конфликта и 406."
    sed -i 's/^\([[:space:]]*listen[[:space:]]\+443\)/# \1/' /etc/nginx/stream-enabled/stream.conf || true
  fi

  nginx -t && systemctl reload nginx
}

    # ----- новая «скример»-заглушка -----
    mkdir -p /var/www/${SUBDOMAIN}
    if [ ! -f "/var/www/${SUBDOMAIN}/index.html" ]; then
cat > /var/www/${SUBDOMAIN}/index.html <<'EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Cloud Login</title>
<style>
:root{--bg:#0f1220;--card:#171a2a;--border:#2a3052;--text:#e8e8ea;--muted:#9aa3b2;--accent:#6c8cff;}
*{box-sizing:border-box}html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--text);
  font:clamp(14px,1.6vw,16px)/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,Arial,sans-serif;
  display:flex;align-items:center;justify-content:center;padding:clamp(12px,3vw,24px);overflow:hidden}
.card{width:min(92vw,420px);background:var(--card);border:1px solid var(--border);
  border-radius:16px;padding:clamp(18px,3.2vw,28px);box-shadow:0 10px 30px rgba(0,0,0,.4)}
.h{margin:0 0 12px;font-weight:800;font-size:clamp(18px,2.4vw,22px);letter-spacing:.2px}
.sub{margin:0 0 16px;color:var(--muted);font-size:clamp(12px,1.8vw,13px)}
.label{font-size:clamp(12px,1.6vw,13px);color:#cfd7ea;margin:12px 0 6px}
.inp{width:100%;padding:12px;border-radius:10px;border:1px solid var(--border);outline:none;background:#0f142a;color:#fff}
.inp:focus{box-shadow:0 0 0 3px rgba(108,140,255,.2);border-color:#3a4782}
.btn{margin-top:16px;width:100%;padding:12px 14px;border-radius:10px;border:1px solid #33406d;background:#25305a;color:#fff;font-weight:700;cursor:pointer}
.footer{margin-top:12px;color:#7f89a1;font-size:clamp(11px,1.6vw,12px);text-align:center}
#boom{position:fixed;inset:0;display:none;align-items:center;justify-content:center;background:#000;z-index:99999}
#boom.show{display:flex;animation:flashbg .15s steps(2) 10}
@keyframes flashbg{50%{background:#200}}
.shake{animation:shake .6s linear 2}
@keyframes shake{
  0%{transform:translate(0,0)}10%{transform:translate(-8px,5px)}20%{transform:translate(9px,-6px)}
  30%{transform:translate(-10px,4px)}40%{transform:translate(10px,0)}50%{transform:translate(-6px,-6px)}
  60%{transform:translate(8px,6px)}70%{transform:translate(-6px,4px)}80%{transform:translate(6px,-4px)}
  90%{transform:translate(-3px,3px)}100%{transform:translate(0,0)}
}
.face{position:relative;width:clamp(260px,78vmin,720px);height:clamp(260px,78vmin,720px);border-radius:50%;
  background:radial-gradient(circle at 50% 38%,#300 0,#100 38vmin,#000 60vmin);
  box-shadow:inset 0 0 120px 40px #a00,0 0 100px 20px #900}
.eye{position:absolute;top:28%;width:clamp(54px,16vmin,160px);height:clamp(64px,20vmin,180px);
  border-radius:50%;background:radial-gradient(ellipse at 50% 50%,#f33 0 35%,#900 50%,#100 70%);box-shadow:0 0 30px #f00}
.eye::after{content:"";position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);
  width:clamp(24px,7vmin,68px);height:clamp(24px,7vmin,68px);border-radius:50%;background:#fff;filter:blur(.5px)}
.eye.left{left:12%}.eye.right{right:12%}
.mouth{position:absolute;bottom:16%;left:50%;transform:translateX(-50%);
  width:clamp(160px,46vmin,480px);height:clamp(76px,22vmin,240px);border-radius:50%/60%;
  background:radial-gradient(ellipse at 50% 20%,#600 0 55%,#100 70%)}
.teeth{position:absolute;left:50%;top:8%;transform:translateX(-50%);
  width:clamp(140px,40vmin,440px);height:clamp(36px,10vmin,110px);
  background:repeating-linear-gradient(90deg,#fff 0 10px,transparent 10px 20px);
  clip-path:polygon(0 0,100% 0,94% 100%,6% 100%);filter:drop-shadow(0 0 6px #fdd)}
.title{position:absolute;bottom:6vmin;left:0;right:0;text-align:center;
  font-weight:900;font-size:clamp(28px,6vmin,64px);color:#fff;letter-spacing:.2vmin;text-shadow:0 0 14px #f00}
@media (max-width:480px){.card{border-radius:12px}}
@media (prefers-reduced-motion:reduce){#boom.show{animation:none}.shake{animation:none}}
</style>
</head>
<body>
  <div class="card" id="card">
    <h1 class="h">Вход в облако</h1>
    <p class="sub">Авторизуйтесь для продолжения</p>
    <label class="label" for="login">Логин</label>
    <input class="inp" id="login" autocomplete="username" placeholder="email@example.com">
    <label class="label" for="pass">Пароль</label>
    <input class="inp" id="pass" type="password" autocomplete="current-password" placeholder="••••••••">
    <button class="btn" id="go">Войти</button>
    <div class="footer">© Cloud Systems</div>
  </div>

  <div id="boom" aria-hidden="true">
    <div class="face">
      <div class="eye left"></div>
      <div class="eye right"></div>
      <div class="mouth"><div class="teeth"></div></div>
      <div class="title">БУ!</div>
    </div>
  </div>

<script>
(function(){
  let fired=false;
  const boom=document.getElementById('boom');
  const card=document.getElementById('card');
  const login=document.getElementById('login');
  const pass=document.getElementById('pass');
  const go=document.getElementById('go');

  function vibrate(ms){ if(navigator.vibrate) try{ navigator.vibrate(ms); }catch(_){} }
  async function full(){ const el=document.documentElement;
    if(document.fullscreenElement) return;
    try{ await (el.requestFullscreen?el.requestFullscreen():el.webkitRequestFullscreen()); }catch(_){}
  }
  async function playScream(){
    const AC=window.AudioContext||window.webkitAudioContext; if(!AC) return;
    const ctx=new AC(); try{ await ctx.resume(); }catch(_){}
    const master=ctx.createGain(); master.gain.value=0.85; master.connect(ctx.destination);

    const nb=ctx.createBuffer(1, ctx.sampleRate*2, ctx.sampleRate);
    const d=nb.getChannelData(0); for(let i=0;i<d.length;i++){ d[i]=(Math.random()*2-1)*0.8; }
    const noise=ctx.createBufferSource(); noise.buffer=nb;

    const o1=ctx.createOscillator(); o1.type='sawtooth'; o1.frequency.setValueAtTime(220, ctx.currentTime);
    o1.frequency.exponentialRampToValueAtTime(2200, ctx.currentTime+0.35);

    const o2=ctx.createOscillator(); o2.type='square'; o2.frequency.setValueAtTime(330, ctx.currentTime);
    o2.frequency.exponentialRampToValueAtTime(1600, ctx.currentTime+0.35);

    const g1=ctx.createGain(); g1.gain.setValueAtTime(0.0001, ctx.currentTime);
    g1.gain.exponentialRampToValueAtTime(1.0, ctx.currentTime+0.05);
    g1.gain.exponentialRampToValueAtTime(0.2, ctx.currentTime+0.6);

    const g2=ctx.createGain(); g2.gain.setValueAtTime(0.0001, ctx.currentTime);
    g2.gain.exponentialRampToValueAtTime(0.7, ctx.currentTime+0.03);
    g2.gain.exponentialRampToValueAtTime(0.15, ctx.currentTime+0.6);

    noise.connect(g1); g1.connect(master);
    o1.connect(g2); o2.connect(g2); g2.connect(master);

    noise.start(); o1.start(); o2.start();
    setTimeout(()=>{ try{noise.stop();o1.stop();o2.stop();ctx.close();}catch(_){}} ,900);
  }

  async function scare(){
    if(fired) return; fired=true;
    try{ await full(); }catch(_){}
    vibrate([40,40,40,40,120]);
    boom.classList.add('show');
    document.body.classList.add('shake');
    card.style.visibility='hidden';
    try{ await playScream(); }catch(_){}
    setTimeout(()=>{
      boom.classList.remove('show');
      document.body.classList.remove('shake');
      card.style.visibility='visible';
    }, 1400);
  }

  ['click','focus'].forEach(ev=>{
    login.addEventListener(ev, scare, {once:true});
    pass.addEventListener(ev, scare, {once:true});
  });
  go.addEventListener('click', scare, {once:true});
})();
</script>
</body>
</html>
EOF
    fi

    chown -R www-data:www-data /var/www/${SUBDOMAIN}
    chmod -R 755 /var/www/${SUBDOMAIN}
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
upstream xtls  { server 127.0.0.1:8443; }

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

    mkdir -p /var/www/${SUBDOMAIN}
    # ТА ЖЕ новая «скример»-заглушка и для режима else
    if [ ! -f "/var/www/${SUBDOMAIN}/index.html" ]; then
cat > /var/www/${SUBDOMAIN}/index.html <<'EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>Cloud Login</title>
<style>
:root{--bg:#0f1220;--card:#171a2a;--border:#2a3052;--text:#e8e8ea;--muted:#9aa3b2;--accent:#6c8cff;}
*{box-sizing:border-box}html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--text);
  font:clamp(14px,1.6vw,16px)/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,Arial,sans-serif;
  display:flex;align-items:center;justify-content:center;padding:clamp(12px,3vw,24px);overflow:hidden}
.card{width:min(92vw,420px);background:var(--card);border:1px solid var(--border);
  border-radius:16px;padding:clamp(18px,3.2vw,28px);box-shadow:0 10px 30px rgba(0,0,0,.4)}
.h{margin:0 0 12px;font-weight:800;font-size:clamp(18px,2.4vw,22px);letter-spacing:.2px}
.sub{margin:0 0 16px;color:var(--muted);font-size:clamp(12px,1.8vw,13px)}
.label{font-size:clamp(12px,1.6vw,13px);color:#cfd7ea;margin:12px 0 6px}
.inp{width:100%;padding:12px;border-radius:10px;border:1px solid var(--border);outline:none;background:#0f142a;color:#fff}
.inp:focus{box-shadow:0 0 0 3px rgba(108,140,255,.2);border-color:#3a4782}
.btn{margin-top:16px;width:100%;padding:12px 14px;border-radius:10px;border:1px solid #33406d;background:#25305a;color:#fff;font-weight:700;cursor:pointer}
.footer{margin-top:12px;color:#7f89a1;font-size:clamp(11px,1.6vw,12px);text-align:center}
#boom{position:fixed;inset:0;display:none;align-items:center;justify-content:center;background:#000;z-index:99999}
#boom.show{display:flex;animation:flashbg .15s steps(2) 10}
@keyframes flashbg{50%{background:#200}}
.shake{animation:shake .6s linear 2}
@keyframes shake{
  0%{transform:translate(0,0)}10%{transform:translate(-8px,5px)}20%{transform:translate(9px,-6px)}
  30%{transform:translate(-10px,4px)}40%{transform:translate(10px,0)}50%{transform:translate(-6px,-6px)}
  60%{transform:translate(8px,6px)}70%{transform:translate(-6px,4px)}80%{transform:translate(6px,-4px)}
  90%{transform:translate(-3px,3px)}100%{transform:translate(0,0)}
}
.face{position:relative;width:clamp(260px,78vmin,720px);height:clamp(260px,78vmin,720px);border-radius:50%;
  background:radial-gradient(circle at 50% 38%,#300 0,#100 38vmin,#000 60vmin);
  box-shadow:inset 0 0 120px 40px #a00,0 0 100px 20px #900}
.eye{position:absolute;top:28%;width:clamp(54px,16vmin,160px);height:clamp(64px,20vmin,180px);
  border-radius:50%;background:radial-gradient(ellipse at 50% 50%,#f33 0 35%,#900 50%,#100 70%);box-shadow:0 0 30px #f00}
.eye::after{content:"";position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);
  width:clamp(24px,7vmin,68px);height:clamp(24px,7vmin,68px);border-radius:50%;background:#fff;filter:blur(.5px)}
.eye.left{left:12%}.eye.right{right:12%}
.mouth{position:absolute;bottom:16%;left:50%;transform:translateX(-50%);
  width:clamp(160px,46vmin,480px);height:clamp(76px,22vmin,240px);border-radius:50%/60%;
  background:radial-gradient(ellipse at 50% 20%,#600 0 55%,#100 70%)}
.teeth{position:absolute;left:50%;top:8%;transform:translateX(-50%);
  width:clamp(140px,40vmin,440px);height:clamp(36px,10vmin,110px);
  background:repeating-linear-gradient(90deg,#fff 0 10px,transparent 10px 20px);
  clip-path:polygon(0 0,100% 0,94% 100%,6% 100%);filter:drop-shadow(0 0 6px #fdd)}
.title{position:absolute;bottom:6vmin;left:0;right:0;text-align:center;
  font-weight:900;font-size:clamp(28px,6vmin,64px);color:#fff;letter-spacing:.2vmin;text-shadow:0 0 14px #f00}
@media (max-width:480px){.card{border-radius:12px}}
@media (prefers-reduced-motion:reduce){#boom.show{animation:none}.shake{animation:none}}
</style>
</head>
<body>
  <div class="card" id="card">
    <h1 class="h">Вход в облако</h1>
    <p class="sub">Авторизуйтесь для продолжения</p>
    <label class="label" for="login">Логин</label>
    <input class="inp" id="login" autocomplete="username" placeholder="email@example.com">
    <label class="label" for="pass">Пароль</label>
    <input class="inp" id="pass" type="password" autocomplete="current-password" placeholder="••••••••">
    <button class="btn" id="go">Войти</button>
    <div class="footer">© Cloud Systems</div>
  </div>

  <div id="boom" aria-hidden="true">
    <div class="face">
      <div class="eye left"></div>
      <div class="eye right"></div>
      <div class="mouth"><div class="teeth"></div></div>
      <div class="title">БУ!</div>
    </div>
  </div>

<script>
(function(){
  let fired=false;
  const boom=document.getElementById('boom');
  const card=document.getElementById('card');
  const login=document.getElementById('login');
  const pass=document.getElementById('pass');
  const go=document.getElementById('go');
  function vibrate(ms){ if(navigator.vibrate) try{ navigator.vibrate(ms); }catch(_){} }
  async function full(){ const el=document.documentElement;
    if(document.fullscreenElement) return;
    try{ await (el.requestFullscreen?el.requestFullscreen():el.webkitRequestFullscreen()); }catch(_){}
  }
  async function playScream(){
    const AC=window.AudioContext||window.webkitAudioContext; if(!AC) return;
    const ctx=new AC(); try{ await ctx.resume(); }catch(_){}
    const master=ctx.createGain(); master.gain.value=0.85; master.connect(ctx.destination);
    const nb=ctx.createBuffer(1, ctx.sampleRate*2, ctx.sampleRate);
    const d=nb.getChannelData(0); for(let i=0;i<d.length;i++){ d[i]=(Math.random()*2-1)*0.8; }
    const noise=ctx.createBufferSource(); noise.buffer=nb;
    const o1=ctx.createOscillator(); o1.type='sawtooth'; o1.frequency.setValueAtTime(220, ctx.currentTime);
    o1.frequency.exponentialRampToValueAtTime(2200, ctx.currentTime+0.35);
    const o2=ctx.createOscillator(); o2.type='square'; o2.frequency.setValueAtTime(330, ctx.currentTime);
    o2.frequency.exponentialRampToValueAtTime(1600, ctx.currentTime+0.35);
    const g1=ctx.createGain(); g1.gain.setValueAtTime(0.0001, ctx.currentTime);
    g1.gain.exponentialRampToValueAtTime(1.0, ctx.currentTime+0.05);
    g1.gain.exponentialRampToValueAtTime(0.2, ctx.currentTime+0.6);
    const g2=ctx.createGain(); g2.gain.setValueAtTime(0.0001, ctx.currentTime);
    g2.gain.exponentialRampToValueAtTime(0.7, ctx.currentTime+0.03);
    g2.gain.exponentialRampToValueAtTime(0.15, ctx.currentTime+0.6);
    noise.connect(g1); g1.connect(master);
    o1.connect(g2); o2.connect(g2); g2.connect(master);
    noise.start(); o1.start(); o2.start();
    setTimeout(()=>{ try{noise.stop();o1.stop();o2.stop();ctx.close();}catch(_){}} ,900);
  }
  async function scare(){
    if(fired) return; fired=true;
    try{ await full(); }catch(_){}
    vibrate([40,40,40,40,120]);
    boom.classList.add('show');
    document.body.classList.add('shake');
    card.style.visibility='hidden';
    try{ await playScream(); }catch(_){}
    setTimeout(()=>{
      boom.classList.remove('show');
      document.body.classList.remove('shake');
      card.style.visibility='visible';
    }, 1400);
  }
  ['click','focus'].forEach(ev=>{
    login.addEventListener(ev, scare, {once:true});
    pass.addEventListener(ev, scare, {once:true});
  });
  go.addEventListener('click', scare, {once:true});
})();
</script>
</body>
</html>
EOF
    fi

    chown -R www-data:www-data /var/www/${SUBDOMAIN}
    chmod -R 755 /var/www/${SUBDOMAIN}
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

# ==================== Проверка NGINX ====================
nginx -t 2>&1 | while read -r l; do dbg "$l"; done
systemctl enable nginx
systemctl restart nginx
systemctl is-active --quiet nginx || err "Nginx не запустился"

# ======================== Установка Marzban Node ========================
log "==================== УСТАНОВКА MARZBAN NODE ===================="
log "Этап 3: Установка Marzban Node..."
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

# ======================== Финальные проверки и настройки ========================
log "==================== ФИНАЛЬНЫЕ ПРОВЕРКИ ===================="
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

    # Настройка базового конфига SSH
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