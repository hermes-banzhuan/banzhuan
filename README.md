# Banzhuan 安装脚本文档

## 一、概述

### 1.1 支持的功能

| 功能 | 说明 |
|------|------|
| 一键安装 | 自动安装 Docker、拉取镜像、启动服务 |
| 一键更新 | 再次执行脚本自动检测并更新到最新版本 |
| nginx 反向代理 | 内置 nginx，支持 WebSocket 长连接 |
| 自动 HTTPS | 域名模式自动申请 Let's Encrypt 证书 |
| 自动更新 | 可选启用 Watchtower 自动更新镜像 |
| 幂等执行 | 多次执行结果一致，安全可靠 |

### 1.2 部署模式

| 模式 | 说明 | 适用场景 |
|------|------|------|
| IP 模式 | 通过 IP:端口 访问 | 服务器无域名，或已有 Web 服务 |
| 域名模式 | 自动配置 nginx + HTTPS | 服务器无其他 Web 服务占用 80/443 |

### 1.3 使用方式

```bash
curl -fsSL https://your-domain.com/install.sh | sudo bash
```

### 1.4 设计原则

| 原则 | 说明 |
|------|------|
| 幂等性 | 多次执行结果一致，已安装则检查更新 |
| 兼容性 | 支持 Ubuntu/Debian/CentOS/Fedora |
| 可维护性 | 模块化函数，单一职责 |
| 用户友好 | 彩色输出、进度提示、错误信息清晰 |

---

## 二、架构说明

### 2.1 容器架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Docker Network                         │
│                    (banzhuan-network)                       │
│                                                             │
│  ┌─────────────────┐    ┌─────────────────────────────────┐ │
│  │  banzhuan-nginx │    │      banzhuan-server            │ │
│  │  (nginx:alpine) │───▶│  (thomsonyang/banzhuan-server)  │ │
│  │                 │    │                                 │ │
│  │  Port: 80/443   │    │  Port: 3006 (internal)          │ │
│  └─────────────────┘    └─────────────────────────────────┘ │
│           │                                                 │
│           │              ┌────────────────────────────────┐ │
│           │              │    banzhuan-watchtower         │ │
│           │              │    (可选，自动更新)              │ │
│           │              └────────────────────────────────┘ │
└───────────┼─────────────────────────────────────────────────┘
            │
            ▼
      宿主机端口 (80/443 或自定义)
```

### 2.2 目录结构

```
/opt/banzhuan/
├── .env                    # 环境变量
├── docker-compose.yml      # Docker Compose 配置
└── nginx/
    ├── nginx.conf          # nginx 主配置
    ├── conf.d/
    │   └── default.conf    # nginx 站点配置
    ├── ssl/
    │   ├── fullchain.pem   # SSL 证书（域名模式）
    │   └── privkey.pem     # SSL 私钥（域名模式）
    ├── html/               # 静态文件目录
    └── acme/               # acme.sh 数据目录
```

---

## 三、执行流程

### 3.1 首次安装流程

```
1. show_banner        - 显示 Banner
2. check_root         - 检查 root 权限
3. check_update       - 检查更新（配置文件不存在则跳过）
4. check_arch         - 检查 CPU 架构
5. check_os           - 检查操作系统
6. check_docker       - 检查/安装 Docker
7. detect_ip          - 获取服务器 IP
8. configure_options  - 交互配置（域名、端口、自动更新）
9. setup_config       - 生成配置文件
10. deploy            - 部署容器
11. show_result       - 显示安装结果
```

### 3.2 更新流程（再次执行脚本）

```
1. show_banner        - 显示 Banner
2. check_root         - 检查 root 权限
3. check_update       - 检查更新
   ├─ 配置文件不存在 → 继续安装流程
   ├─ 容器未运行 → 继续安装流程
   ├─ 获取本地/远程版本
   ├─ 版本一致 → 退出
   └─ 版本不同 → 执行更新
      ├─ [1/3] 拉取最新镜像
      ├─ [2/3] 重启容器
      └─ [3/3] 验证启动
```

---

## 四、常量定义

按脚本中定义顺序：

| 常量 | 值 | 说明 |
|------|------|------|
| SCRIPT_VERSION | "1.0.0" | 脚本版本号 |
| IMAGE_VERSION | "latest" | Docker 镜像版本 |
| INSTALL_DIR | "/opt/banzhuan" | 安装目录 |
| DOCKER_IMAGE | "thomsonyang/banzhuan-server" | 应用镜像 |
| WATCHTOWER_IMAGE | "nickfedor/watchtower" | 自动更新镜像 |
| NGINX_IMAGE | "nginx:alpine" | nginx 镜像 |
| ACME_IMAGE | "neilpang/acme.sh" | SSL 证书工具镜像 |
| DEFAULT_PORT | 80 | 默认端口 |
| CONTAINER_NAME | "banzhuan-server" | 应用容器名 |
| WATCHTOWER_NAME | "banzhuan-watchtower" | 自动更新容器名 |
| NGINX_NAME | "banzhuan-nginx" | nginx 容器名 |

### 颜色常量

| 常量 | 值 | 用途 |
|------|------|------|
| RED | '\033[0;31m' | 错误信息 |
| GREEN | '\033[0;32m' | 正常信息 |
| YELLOW | '\033[1;33m' | 警告信息 |
| BLUE | '\033[1;36m' | Banner |
| NC | '\033[0m' | 重置颜色 |

---

## 五、函数说明

按脚本中定义顺序：

### 5.1 log_info()

输出绿色正常信息。

```bash
log_info() {
    echo -e "${GREEN}[BANZHUAN]${NC} $1"
}
```

### 5.2 log_warn()

输出黄色警告信息。

```bash
log_warn() {
    echo -e "${YELLOW}[BANZHUAN]${NC} $1"
}
```

### 5.3 log_error()

输出红色错误信息。

```bash
log_error() {
    echo -e "${RED}[BANZHUAN]${NC} $1"
}
```

### 5.4 show_banner()

显示脚本 Banner，包含版本号。

### 5.5 check_root()

检查是否以 root 权限运行，非 root 则退出。

### 5.6 check_update()

检查更新的核心函数，逻辑如下：

1. 配置文件不存在 → return（继续安装）
2. 容器未运行 → return（重新安装）
3. 获取本地镜像版本（docker inspect）
4. 获取远程镜像版本（docker manifest inspect）
5. 远程版本获取失败 → exit 1
6. 版本一致 → exit 0（无需更新）
7. 版本不同 → 显示更新说明，询问确认
8. 执行更新：
   - [1/3] 拉取最新镜像
   - [2/3] 重启容器
   - [3/3] 验证启动

### 5.7 check_arch()

检查 CPU 架构，支持 x86_64 和 aarch64。

### 5.8 check_os()

检查操作系统，读取 /etc/os-release。

### 5.9 install_docker()

安装 Docker，支持 apt-get/yum/dnf 包管理器。

### 5.10 check_docker()

检查 Docker 安装状态：
- 已安装：检查服务是否运行
- 未安装：调用 install_docker()
- 检查磁盘空间（最少 1024MB）

### 5.11 detect_ip()

获取服务器公网 IP：
- 优先 IPv4（api.ipify.org, ifconfig.me, icanhazip.com）
- 备选 IPv6（api64.ipify.org）
- 自动检测失败则手动输入

### 5.12 setup_nginx_config()

生成 nginx 配置文件：
- 创建目录：nginx/conf.d, nginx/ssl, nginx/html, nginx/acme
- 生成 nginx.conf 主配置
- 域名模式：生成 default.conf + ssl.conf.disabled
- IP 模式：生成 default.conf

### 5.13 setup_config()

生成配置文件：
- 创建安装目录
- 生成 .env 文件
- 调用 setup_nginx_config()
- 生成 docker-compose.yml

### 5.14 deploy()

部署容器：
- 清理旧容器
- 拉取镜像（应用、nginx、watchtower）
- 启动容器（docker compose up -d）
- 验证启动状态
- 域名模式调用 setup_ssl()

### 5.15 setup_ssl()

申请 SSL 证书（仅域名模式）：
- 使用 acme.sh 申请 Let's Encrypt 证书
- 安装证书到 nginx/ssl 目录
- 替换 nginx 配置启用 HTTPS
- 重启 nginx

### 5.16 show_result()

显示安装结果：
- 访问地址（HTTP/HTTPS）
- 配置目录
- 自动更新状态

### 5.17 configure_options()

交互配置：
- 域名配置（输入域名启用 HTTPS）
- 端口配置（IP 模式）
- 端口占用检查（ss -tuln）
- 自动更新配置

### 5.18 main()

主函数，按顺序调用：

```bash
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
```

---

## 六、配置文件

### 6.1 .env 文件

```bash
VERSION=latest
PORT=80
SERVER_IP=1.2.3.4
AUTO_UPDATE=false
USE_DOMAIN=true
DOMAIN=example.com
UPDATE_INTERVAL=86400
```

| 变量 | 说明 |
|------|------|
| VERSION | 镜像版本 |
| PORT | 服务端口 |
| SERVER_IP | 服务器 IP |
| AUTO_UPDATE | 是否启用自动更新 |
| USE_DOMAIN | 是否使用域名模式 |
| DOMAIN | 域名（域名模式） |
| UPDATE_INTERVAL | 自动更新间隔（秒） |

### 6.2 docker-compose.yml（IP 模式）

```yaml
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
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
      - ./nginx/html:/var/www/html
    depends_on:
      - banzhuan-server

  # 可选：自动更新服务
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

networks:
  default:
    name: banzhuan-network
```

### 6.3 docker-compose.yml（域名模式）

域名模式额外暴露 443 端口：

```yaml
  banzhuan-nginx:
    ports:
      - "${PORT:-80}:80"
      - "443:443"
```

### 6.4 nginx 配置（IP 模式）

```nginx
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
```

### 6.5 nginx 配置（域名 HTTPS 模式）

```nginx
server {
    listen 80;
    server_name example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    http2 on;
    server_name example.com;

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
```

---

## 七、端口占用处理

### 7.1 域名模式端口检查

当用户选择域名模式时，脚本会检查 80/443 端口：

```bash
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
```

### 7.2 已有 Web 服务的反向代理配置

如果服务器已有 nginx/OpenResty，可手动配置反向代理：

```nginx
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://127.0.0.1:3006;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
    }
}
```

---

## 八、常用命令

```bash
# 手动更新
cd /opt/banzhuan && docker compose pull && docker compose up -d

# 查看日志
docker logs -f banzhuan-server
docker logs -f banzhuan-nginx

# 重启服务
cd /opt/banzhuan && docker compose restart

# 停止服务
cd /opt/banzhuan && docker compose down

# 查看状态
docker ps | grep banzhuan

# 完全删除
docker stop banzhuan-server banzhuan-nginx banzhuan-watchtower 2>/dev/null
docker rm banzhuan-server banzhuan-nginx banzhuan-watchtower 2>/dev/null
rm -rf /opt/banzhuan
```
