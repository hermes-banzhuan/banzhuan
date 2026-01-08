#!/bin/bash
set -e

SCRIPT_VERSION="1.0.0"
IMAGE_VERSION="latest"
INSTALL_DIR="/opt/banzhuan"
DOCKER_IMAGE="thomsonyang/banzhuan-server"
WATCHTOWER_IMAGE="nickfedor/watchtower"
NGINX_IMAGE="nginx:alpine"
ACME_IMAGE="neilpang/acme.sh"
DEFAULT_PORT=80
CONTAINER_NAME="banzhuan-server"
WATCHTOWER_NAME="banzhuan-watchtower"
NGINX_NAME="banzhuan-nginx"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;36m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[BANZHUAN]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[BANZHUAN]${NC} $1"
}

log_error() {
    echo -e "${RED}[BANZHUAN]${NC} $1"
}

show_banner() {
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║              🚀 Banzhuan 一键安装脚本 🚀                    ║"
    echo "║                      v${SCRIPT_VERSION}                               ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "此脚本需要 root 权限运行，请使用 sudo 执行"
        exit 1
    fi
}

check_update() {
    if [ ! -f "${INSTALL_DIR}/docker-compose.yml" ]; then
        return
    fi
    log_info "检测到配置文件: ${INSTALL_DIR}/docker-compose.yml"

    if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        log_warn "容器未运行，将重新安装"
        return
    fi
    log_info "容器运行中: ${CONTAINER_NAME}"

    log_info "获取本地镜像信息..."
    local_digest=$(docker inspect --format='{{index .RepoDigests 0}}' ${DOCKER_IMAGE}:${IMAGE_VERSION} 2>/dev/null | cut -d'@' -f2 || echo "")
    local_digest_short=$(echo "$local_digest" | cut -c8-19)
    if [ -n "$local_digest_short" ]; then
        log_info "本地版本: ${local_digest_short}"
    else
        log_warn "本地版本: 未知"
    fi

    log_info "获取远程镜像信息..."
    remote_digest=$(docker manifest inspect ${DOCKER_IMAGE}:${IMAGE_VERSION} 2>/dev/null | grep -o '"digest": "[^"]*"' | head -1 | cut -d'"' -f4 || echo "")
    remote_digest_short=$(echo "$remote_digest" | cut -c8-19)
    if [ -n "$remote_digest_short" ]; then
        log_info "远程版本: ${remote_digest_short}"
    else
        log_warn "远程版本: 获取失败"
    fi

    if [ -z "$remote_digest" ]; then
        log_error "无法获取远程版本，请检查网络连接"
        log_info "手动更新命令: cd ${INSTALL_DIR} && docker compose pull && docker compose up -d"
        exit 1
    fi

    echo ""
    if [ -n "$local_digest" ] && [ "$local_digest" = "$remote_digest" ]; then
        log_info "对比结果: 版本一致，无需更新"
        exit 0
    fi

    if [ -z "$local_digest" ]; then
        log_warn "对比结果: 本地镜像信息缺失"
    else
        log_info "对比结果: 发现新版本"
        log_info "版本变化: ${local_digest_short} -> ${remote_digest_short}"
    fi

    echo ""
    log_warn "更新操作说明:"
    log_warn "  1. 拉取最新镜像 (docker compose pull)"
    log_warn "  2. 停止旧容器并启动新容器 (docker compose up -d)"
    log_warn "  3. 服务在重启期间短暂不可用"

    echo ""
    if [ -e /dev/tty ]; then
        read -p "是否执行更新？（Enter 默认更新）[Y/n]: " confirm < /dev/tty
        if [ "$confirm" = "n" ] || [ "$confirm" = "N" ]; then
            log_info "已取消更新"
            exit 0
        fi
    fi

    echo ""
    cd "${INSTALL_DIR}"

    log_info "[1/3] 拉取最新镜像..."
    if ! docker compose pull; then
        log_error "拉取失败，请检查网络"
        exit 1
    fi

    log_info "[2/3] 重启容器..."
    docker compose up -d --remove-orphans

    log_info "[3/3] 验证启动..."
    sleep 3
    if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        log_info "应用容器启动成功 ✓"
    else
        log_error "应用容器启动失败"
        docker logs ${CONTAINER_NAME} 2>/dev/null || true
        exit 1
    fi
    if docker ps --format '{{.Names}}' | grep -qx "${NGINX_NAME}"; then
        log_info "nginx 容器启动成功 ✓"
    else
        log_warn "nginx 容器未运行（可能是旧版本安装）"
    fi
    log_info "更新完成"
    exit 0
}

check_arch() {
    log_info "检查 CPU 架构..."
    local arch=$(uname -m)
    case $arch in
        x86_64|aarch64)
            log_info "CPU 架构: $arch ✓"
            ;;
        *)
            log_error "不支持的 CPU 架构: $arch"
            exit 1
            ;;
    esac
}

check_os() {
    log_info "检查操作系统..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "操作系统: $NAME $VERSION_ID"
    else
        log_error "无法识别操作系统"
        exit 1
    fi
}

install_docker() {
    log_info "开始安装 Docker..."

    if command -v apt-get &> /dev/null; then
        apt-get update || { log_error "apt-get update 失败"; exit 1; }
        apt-get install -y curl || { log_error "安装 curl 失败"; exit 1; }
        curl -fsSL https://get.docker.com | sh || { log_error "Docker 安装脚本执行失败"; exit 1; }
    elif command -v yum &> /dev/null; then
        yum install -y curl || { log_error "安装 curl 失败"; exit 1; }
        curl -fsSL https://get.docker.com | sh || { log_error "Docker 安装脚本执行失败"; exit 1; }
    elif command -v dnf &> /dev/null; then
        dnf install -y curl || { log_error "安装 curl 失败"; exit 1; }
        curl -fsSL https://get.docker.com | sh || { log_error "Docker 安装脚本执行失败"; exit 1; }
    else
        log_error "不支持的包管理器，请手动安装 Docker"
        exit 1
    fi

    if ! command -v docker &> /dev/null; then
        log_error "Docker 安装失败"
        exit 1
    fi

    if ! systemctl start docker; then
        log_error "启动 Docker 服务失败"
        exit 1
    fi
    systemctl enable docker

    log_info "Docker 安装完成 ✓"
}

check_docker() {
    log_info "检查 Docker 安装状态..."

    if command -v docker &> /dev/null; then
        log_info "Docker 已安装 ✓"

        if systemctl is-active --quiet docker; then
            log_info "Docker 服务运行中 ✓"
        else
            log_info "启动 Docker 服务..."
            if ! systemctl start docker; then
                log_error "启动 Docker 服务失败"
                exit 1
            fi
            systemctl enable docker
        fi
    else
        log_warn "Docker 未安装，开始安装..."
        install_docker
    fi

    local available_space=$(df -m / | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 1024 ]; then
        log_error "磁盘空间不足（当前: ${available_space}MB）"
        exit 1
    fi
}

detect_ip() {
    log_info "获取服务器 IP..."

    if ! command -v curl &> /dev/null; then
        log_info "安装 curl..."
        if command -v apt-get &> /dev/null; then
            apt-get install -y curl > /dev/null
        elif command -v yum &> /dev/null; then
            yum install -y curl > /dev/null
        elif command -v dnf &> /dev/null; then
            dnf install -y curl > /dev/null
        fi
    fi

    local auto_ip=""
    local ip_regex='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
    local ipv6_regex='^[0-9a-fA-F:]+$'

    for api in "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        auto_ip=$(curl -4 -s --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]' || true)
        if echo "$auto_ip" | grep -qE "$ip_regex"; then
            break
        fi
        auto_ip=""
    done

    if [ -z "$auto_ip" ]; then
        for api in "https://api64.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
            auto_ip=$(curl -6 -s --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]' || true)
            if echo "$auto_ip" | grep -qE "$ipv6_regex"; then
                break
            fi
            auto_ip=""
        done
    fi

    if [ -n "$auto_ip" ]; then
        log_info "检测到公网 IP: $auto_ip"
        if [ -e /dev/tty ]; then
            read -p "使用此 IP？（Enter 默认使用）[Y/n]: " confirm < /dev/tty
            if [ -z "$confirm" ] || [ "$confirm" = "Y" ] || [ "$confirm" = "y" ]; then
                SERVER_IP="$auto_ip"
                return
            fi
        else
            SERVER_IP="$auto_ip"
            return
        fi
    fi

    if [ -e /dev/tty ]; then
        while true; do
            read -p "请输入服务器 IP: " SERVER_IP < /dev/tty
            if [ -n "$SERVER_IP" ]; then
                break
            fi
            log_warn "IP 不能为空，请重新输入"
        done
    else
        log_error "无法获取服务器 IP，请在交互模式下运行脚本"
        exit 1
    fi
}

setup_nginx_config() {
    log_info "生成 nginx 配置..."

    mkdir -p "${INSTALL_DIR}/nginx/conf.d"
    mkdir -p "${INSTALL_DIR}/nginx/ssl"
    mkdir -p "${INSTALL_DIR}/nginx/html"
    mkdir -p "${INSTALL_DIR}/nginx/acme"

    cat > "${INSTALL_DIR}/nginx/nginx.conf" << 'NGINX_MAIN_EOF'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    client_max_body_size 100m;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/json application/xml;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        '' close;
    }

    include /etc/nginx/conf.d/*.conf;
}
NGINX_MAIN_EOF

    if [ "$USE_DOMAIN" = "true" ]; then
        cat > "${INSTALL_DIR}/nginx/conf.d/default.conf" << NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://banzhuan-server:3006;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
}
NGINX_EOF

        cat > "${INSTALL_DIR}/nginx/conf.d/ssl.conf.disabled" << NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        proxy_pass http://banzhuan-server:3006;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
}
NGINX_EOF
    else
        cat > "${INSTALL_DIR}/nginx/conf.d/default.conf" << 'NGINX_EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://banzhuan-server:3006;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
}
NGINX_EOF
    fi

    log_info "nginx 配置已生成 ✓"
}

setup_config() {
    log_info "生成配置文件..."

    if ! mkdir -p "${INSTALL_DIR}"; then
        log_error "创建安装目录失败: ${INSTALL_DIR}"
        exit 1
    fi

    if ! cat > "${INSTALL_DIR}/.env" << EOF
VERSION=${IMAGE_VERSION}
PORT=${PORT}
SERVER_IP=${SERVER_IP}
AUTO_UPDATE=${AUTO_UPDATE}
USE_DOMAIN=${USE_DOMAIN}
DOMAIN=${DOMAIN:-}
UPDATE_INTERVAL=86400
EOF
    then
        log_error "生成 .env 文件失败"
        exit 1
    fi

    chmod 600 "${INSTALL_DIR}/.env"

    setup_nginx_config

    if ! cat > "${INSTALL_DIR}/docker-compose.yml" << 'COMPOSE_EOF'
version: '3.8'

services:
  banzhuan-server:
    image: thomsonyang/banzhuan-server:${VERSION:-latest}
    container_name: banzhuan-server
    restart: always
    expose:
      - "3006"
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  banzhuan-nginx:
    image: nginx:alpine
    container_name: banzhuan-nginx
    restart: always
    ports:
      - "${PORT:-80}:80"
COMPOSE_EOF
    then
        log_error "生成 docker-compose.yml 文件失败"
        exit 1
    fi

    if [ "$USE_DOMAIN" = "true" ]; then
        cat >> "${INSTALL_DIR}/docker-compose.yml" << 'COMPOSE_EOF'
      - "443:443"
COMPOSE_EOF
    fi

    cat >> "${INSTALL_DIR}/docker-compose.yml" << 'COMPOSE_EOF'
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
      - ./nginx/html:/var/www/html
    depends_on:
      - banzhuan-server
COMPOSE_EOF

    if [ "$AUTO_UPDATE" = "true" ]; then
        cat >> "${INSTALL_DIR}/docker-compose.yml" << 'COMPOSE_EOF'

  banzhuan-watchtower:
    image: nickfedor/watchtower
    container_name: banzhuan-watchtower
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_POLL_INTERVAL=${UPDATE_INTERVAL:-86400}
      - WATCHTOWER_LABEL_ENABLE=true
COMPOSE_EOF
    fi

    cat >> "${INSTALL_DIR}/docker-compose.yml" << 'COMPOSE_EOF'

networks:
  default:
    name: banzhuan-network
COMPOSE_EOF

    log_info "配置文件已生成 ✓"
}

deploy() {
    log_info "开始部署..."

    log_info "清理旧容器..."
    docker stop ${CONTAINER_NAME} 2>/dev/null || true
    docker rm ${CONTAINER_NAME} 2>/dev/null || true
    docker stop ${NGINX_NAME} 2>/dev/null || true
    docker rm ${NGINX_NAME} 2>/dev/null || true
    docker stop ${WATCHTOWER_NAME} 2>/dev/null || true
    docker rm ${WATCHTOWER_NAME} 2>/dev/null || true

    log_info "拉取镜像..."
    if ! docker pull ${DOCKER_IMAGE}:${IMAGE_VERSION}; then
        log_error "拉取应用镜像失败，请检查网络连接"
        exit 1
    fi

    if ! docker pull ${NGINX_IMAGE}; then
        log_error "拉取 nginx 镜像失败，请检查网络连接"
        exit 1
    fi

    if [ "$AUTO_UPDATE" = "true" ]; then
        if ! docker pull ${WATCHTOWER_IMAGE}; then
            log_error "拉取 Watchtower 镜像失败，请检查网络连接"
            exit 1
        fi
    fi

    log_info "启动容器..."
    cd "${INSTALL_DIR}"

    if ! docker compose up -d; then
        log_error "启动容器失败"
        exit 1
    fi

    log_info "等待服务启动..."
    sleep 5

    if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
        log_info "应用容器启动成功 ✓"
    else
        log_error "应用容器启动失败"
        docker logs ${CONTAINER_NAME} 2>/dev/null || true
        exit 1
    fi

    if docker ps --format '{{.Names}}' | grep -qx "${NGINX_NAME}"; then
        log_info "nginx 容器启动成功 ✓"
    else
        log_error "nginx 容器启动失败"
        docker logs ${NGINX_NAME} 2>/dev/null || true
        exit 1
    fi

    SSL_ENABLED="false"

    if [ "$USE_DOMAIN" = "true" ]; then
        setup_ssl
    fi
}

setup_ssl() {
    log_info "申请 SSL 证书..."

    if ! docker run --rm \
        -v "${INSTALL_DIR}/nginx/acme:/acme.sh" \
        -v "${INSTALL_DIR}/nginx/html:/webroot" \
        ${ACME_IMAGE} --issue -d ${DOMAIN} -w /webroot --server letsencrypt --home /acme.sh; then
        log_warn "SSL 证书申请失败，将使用 HTTP 模式"
        log_warn "请确保域名 ${DOMAIN} 已正确解析到此服务器"
        log_warn "稍后可手动执行证书申请"
        return
    fi

    log_info "安装 SSL 证书..."
    if ! docker run --rm \
        -v "${INSTALL_DIR}/nginx/acme:/acme.sh" \
        -v "${INSTALL_DIR}/nginx/ssl:/ssl-out" \
        ${ACME_IMAGE} --install-cert -d ${DOMAIN} \
        --key-file /ssl-out/privkey.pem \
        --fullchain-file /ssl-out/fullchain.pem \
        --home /acme.sh; then
        log_warn "SSL 证书安装失败"
        return
    fi

    if [ ! -f "${INSTALL_DIR}/nginx/ssl/fullchain.pem" ] || [ ! -f "${INSTALL_DIR}/nginx/ssl/privkey.pem" ]; then
        log_warn "证书文件未生成"
        return
    fi

    rm -f "${INSTALL_DIR}/nginx/conf.d/default.conf"
    mv "${INSTALL_DIR}/nginx/conf.d/ssl.conf.disabled" "${INSTALL_DIR}/nginx/conf.d/default.conf"

    log_info "重启 nginx 以启用 HTTPS..."
    docker restart ${NGINX_NAME}
    sleep 3

    if docker ps --format '{{.Names}}' | grep -qx "${NGINX_NAME}"; then
        log_info "HTTPS 已启用 ✓"
        SSL_ENABLED="true"
    else
        log_warn "nginx 重启失败，回滚到 HTTP 模式"
        cat > "${INSTALL_DIR}/nginx/conf.d/default.conf" << NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://banzhuan-server:3006;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 3600s;
        proxy_buffering off;
    }
}
NGINX_EOF
        docker restart ${NGINX_NAME}
    fi
}

show_result() {
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    🎉 安装完成！🎉                          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "📋 安装信息:"
    if [ "$USE_DOMAIN" = "true" ]; then
        if [ "$SSL_ENABLED" = "true" ]; then
            echo -e "   🌐 访问地址: ${GREEN}https://${DOMAIN}${NC}"
            echo -e "   🔒 HTTPS: ${GREEN}已启用${NC}"
        else
            echo -e "   🌐 访问地址: ${GREEN}http://${DOMAIN}${NC}"
            echo -e "   🔒 HTTPS: ${YELLOW}未启用（证书申请失败）${NC}"
        fi
    else
        echo -e "   🌐 访问地址: ${GREEN}http://${SERVER_IP}:${PORT}${NC}"
    fi
    echo -e "   📁 配置目录: ${GREEN}${INSTALL_DIR}${NC}"
    if [ "$AUTO_UPDATE" = "true" ]; then
        echo -e "   🔄 自动更新: ${GREEN}已启用${NC}"
    fi
    echo ""

    log_info "安装完成！"
}

configure_options() {
    if [ -e /dev/tty ]; then
        echo ""
        log_info "是否配置域名？（配置域名将启用 HTTPS）"
        read -p "输入域名（Enter 跳过，使用 IP 访问）: " DOMAIN < /dev/tty

        if [ -n "$DOMAIN" ]; then
            if ! echo "$DOMAIN" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$'; then
                log_error "域名格式不正确: ${DOMAIN}"
                exit 1
            fi
            USE_DOMAIN="true"
            PORT=80
            if ss -tuln | grep -qE '(:80\s|:80$)'; then
                log_warn "端口 80 已被占用"
                log_warn "检测到服务器已有 Web 服务运行（如 nginx/OpenResty/Apache）"
                echo ""
                log_info "推荐操作："
                log_info "  1. 选择 IP 模式安装，使用其他端口（如 3006）"
                log_info "  2. 在现有 Web 服务中配置反向代理到 http://127.0.0.1:3006"
                log_info "  3. 通过现有 Web 服务申请 SSL 证书"
                echo ""
                log_error "无法使用域名模式，请重新运行脚本选择 IP 模式"
                exit 1
            fi
            if ss -tuln | grep -qE '(:443\s|:443$)'; then
                log_warn "端口 443 已被占用"
                log_warn "检测到服务器已有 Web 服务运行（如 nginx/OpenResty/Apache）"
                echo ""
                log_info "推荐操作："
                log_info "  1. 选择 IP 模式安装，使用其他端口（如 3006）"
                log_info "  2. 在现有 Web 服务中配置反向代理到 http://127.0.0.1:3006"
                log_info "  3. 通过现有 Web 服务申请 SSL 证书"
                echo ""
                log_error "无法使用域名模式，请重新运行脚本选择 IP 模式"
                exit 1
            fi
            log_info "域名: ${DOMAIN}"
            log_info "将启用 nginx 反向代理 + Let's Encrypt 自动 HTTPS"
        else
            USE_DOMAIN="false"
            while true; do
                read -p "服务端口（Enter 默认 ${DEFAULT_PORT}）: " PORT < /dev/tty
                PORT=${PORT:-${DEFAULT_PORT}}
                if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                    log_warn "端口必须是 1-65535 之间的数字"
                    continue
                fi
                if ss -tuln | grep -qE "(:${PORT}\s|:${PORT}$)"; then
                    log_warn "端口 ${PORT} 已被占用，请选择其他端口"
                    continue
                fi
                break
            done
        fi

        echo ""
        log_warn "自动更新可能在服务运行时重启容器，建议手动更新"
        read -p "启用自动更新？（Enter 默认不启用）[y/N]: " ans < /dev/tty
        if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
            AUTO_UPDATE="true"
        else
            AUTO_UPDATE="false"
        fi
    else
        PORT=${DEFAULT_PORT}
        AUTO_UPDATE="false"
        USE_DOMAIN="false"
        log_info "非交互模式，使用默认端口: ${PORT}"
        log_info "非交互模式，自动更新: 未启用"
    fi
}

main() {
    show_banner

    check_root

    check_update

    log_info "开始安装 Banzhuan..."

    check_arch
    check_os
    check_docker

    detect_ip

    configure_options

    setup_config

    deploy

    show_result
}

main "$@"
