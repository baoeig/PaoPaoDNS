#!/bin/bash
# ===========================================
# PaoPaoDNS 一键安装脚本 (纯在线版，无需Docker)
# 项目主页: https://github.com/baoeig/PaoPaoDNS
# 用法: 
#   curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-online.sh | sudo bash
# ===========================================

set -e

# 版本配置
VERSION="1.0.0"
GITHUB_REPO="baoeig/PaoPaoDNS"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }
log_step()    { echo -e "${BLUE}[→]${NC} $1"; }
log_success() { echo -e "${CYAN}[★]${NC} $1"; }

# 检查root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用root权限运行"
        echo "  curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install-online.sh | sudo bash"
        exit 1
    fi
}

# 检测系统
detect_system() {
    # 发行版
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
    else
        DISTRO=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi
    
    # 架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        armv7l|armhf)   ARCH="armv7" ;;
        armv6l)         ARCH="armv6" ;;
        i686|i386)      ARCH="386" ;;
        *)              log_error "不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    log_info "系统: ${DISTRO} ${ARCH}"
}

# 检查命令
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# 安装基础工具
install_base() {
    log_step "安装基础工具..."
    case $DISTRO in
        ubuntu|debian)        apt-get update -qq && apt-get install -y -qq wget curl xz-utils ca-certificates ;;
        centos|rhel|fedora)   yum install -y -q wget curl xz ca-certificates ;;
        arch|manjaro)         pacman -Sy --noconfirm wget curl xz ca-certificates ;;
        alpine)               apk add --no-cache wget curl xz ca-certificates ;;
    esac
}

# 安装系统依赖
install_deps() {
    log_step "安装系统依赖..."
    case $DISTRO in
        ubuntu|debian)
            apt-get install -y -qq libevent-dev libhiredis-dev libssl-dev libexpat1-dev \
                tzdata cron inotify-tools bind9-host
            ;;
        centos|rhel|fedora)
            [ "$DISTRO" != "fedora" ] && yum install -y -q epel-release
            yum install -y -q libevent-devel hiredis-devel openssl-devel expat-devel \
                tzdata cronie inotify-tools bind-utils
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm libevent hiredis openssl expat tzdata cronie inotify-tools bind
            ;;
        alpine)
            apk add --no-cache libevent hiredis openssl expat tzdata dcron inotify-tools bind-tools
            ;;
    esac
    log_info "依赖安装完成"
}

# 从GitHub下载预编译包
download_release() {
    log_step "下载PaoPaoDNS..."
    
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # 下载地址 (需要在GitHub上上传预编译包)
    RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/latest/download"
    PKG_NAME="paopaodns-linux-${ARCH}.tar.xz"
    
    log_info "下载 ${PKG_NAME}..."
    
    if has_cmd wget; then
        wget -q --show-progress "${RELEASE_URL}/${PKG_NAME}" -O "${PKG_NAME}" || {
            log_error "下载失败: ${RELEASE_URL}/${PKG_NAME}"
            log_error "请检查网络或手动下载"
            exit 1
        }
    elif has_cmd curl; then
        curl -fSL --progress-bar "${RELEASE_URL}/${PKG_NAME}" -o "${PKG_NAME}" || {
            log_error "下载失败"
            exit 1
        }
    else
        log_error "需要wget或curl"
        exit 1
    fi
    
    log_info "解压..."
    xz -d "${PKG_NAME}" 2>/dev/null || true
    tar xf "${PKG_NAME%.xz}" 2>/dev/null || tar xf "${PKG_NAME}" 2>/dev/null || true
    
    log_info "下载完成"
}

# 安装文件
install_files() {
    log_step "安装文件..."
    
    cd "$TEMP_DIR"
    
    # 创建目录
    mkdir -p /etc/unbound /etc/redis /etc/paopaodns /var/lib/paopaodns /var/log/paopaodns /var/run/redis
    
    # 二进制
    cp -f unbound unbound-checkconf mosdns redis-server redis-cli /usr/local/bin/ 2>/dev/null || {
        log_error "核心文件缺失，请检查下载包"
        exit 1
    }
    chmod +x /usr/local/bin/{unbound,unbound-checkconf,mosdns,redis-server,redis-cli}
    
    # 配置
    [ -f unbound.conf ] && cp -f unbound.conf /etc/unbound/
    [ -f unbound_custom.conf ] && cp -f unbound_custom.conf /etc/unbound/
    [ -f named.cache ] && cp -f named.cache /etc/unbound/
    [ -f redis.conf ] && cp -f redis.conf /etc/redis/
    [ -f mosdns.yaml ] && cp -f mosdns.yaml /etc/paopaodns/
    [ -f dnscrypt.toml ] && cp -f dnscrypt.toml /etc/paopaodns/
    [ -f custom_env.ini ] && cp -f custom_env.ini /etc/paopaodns/
    [ -f custom_mod.yaml ] && cp -f custom_mod.yaml /etc/paopaodns/
    [ -f force_recurse_list.txt ] && cp -f force_recurse_list.txt /etc/paopaodns/
    [ -f force_dnscrypt_list.txt ] && cp -f force_dnscrypt_list.txt /etc/paopaodns/
    [ -f force_forward_list.txt ] && cp -f force_forward_list.txt /etc/paopaodns/
    
    # 数据
    [ -f Country-only-cn-private.mmdb.xz ] && cp -f Country-only-cn-private.mmdb.xz /var/lib/paopaodns/
    [ -f global_mark.dat ] && cp -f global_mark.dat /var/lib/paopaodns/
    [ -f trackerslist.txt.xz ] && cp -f trackerslist.txt.xz /var/lib/paopaodns/
    [ -d dnscrypt-resolvers ] && cp -rf dnscrypt-resolvers /var/lib/paopaodns/
    
    # 解压数据
    cd /var/lib/paopaodns
    [ -f Country-only-cn-private.mmdb.xz ] && xz -d Country-only-cn-private.mmdb.xz
    [ -f trackerslist.txt.xz ] && xz -d trackerslist.txt.xz
    
    # 脚本
    for s in init.sh data_update.sh watch_list.sh test.sh debug.sh reload.sh; do
        [ -f "${TEMP_DIR}/${s}" ] && { cp -f "${TEMP_DIR}/${s}" /usr/local/bin/; chmod +x "/usr/local/bin/${s}"; }
    done
    
    log_info "文件安装完成"
}

# 创建用户
create_users() {
    id -u unbound >/dev/null 2>&1 || useradd -r -s /bin/false unbound 2>/dev/null || true
    id -u redis >/dev/null 2>&1 || useradd -r -s /bin/false redis 2>/dev/null || true
    chown -R redis:redis /var/lib/redis /var/run/redis 2>/dev/null || true
}

# 配置Redis
setup_redis() {
    log_step "配置Redis..."
    cat > /etc/redis/redis-paopaodns.conf << 'EOF'
daemonize yes
pidfile /var/run/redis/redis-server.pid
logfile /var/log/redis/redis-server.log
dir /var/lib/redis
dbfilename redis_dns_v2.rdb
save 900 1
save 300 10
save 60 10000
maxmemory 256mb
maxmemory-policy allkeys-lru
bind 127.0.0.1
port 6379
EOF
}

# 创建服务
create_services() {
    log_step "创建系统服务..."
    
    cat > /etc/systemd/system/redis-paopaodns.service << 'EOF'
[Unit]
Description=Redis for PaoPaoDNS
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/redis-server /etc/redis/redis-paopaodns.conf
ExecStop=/usr/local/bin/redis-cli shutdown
Restart=always
RestartSec=3
PIDFile=/var/run/redis/redis-server.pid

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/paopaodns.service << 'EOF'
[Unit]
Description=PaoPaoDNS Service
After=network.target redis-paopaodns.service
Requires=redis-paopaodns.service

[Service]
Type=forking
ExecStart=/usr/local/bin/init.sh
ExecStop=/usr/local/bin/reload.sh stop
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# 防火墙
setup_firewall() {
    log_step "配置防火墙..."
    if command -v firewall-cmd >/dev/null; then
        firewall-cmd --permanent --add-port=53/{tcp,udp} 2>/dev/null
        firewall-cmd --reload 2>/dev/null
    elif command -v ufw >/dev/null; then
        ufw allow 53/{tcp,udp} 2>/dev/null
    elif command -v iptables >/dev/null; then
        iptables -A INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null
        iptables -A INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null
    fi
}

# 启动
start_services() {
    log_step "启动服务..."
    systemctl start redis-paopaodns && systemctl enable redis-paopaodns
    sleep 2
    systemctl start paopaodns && systemctl enable paopaodns
}

# 验证
verify() {
    log_step "验证..."
    sleep 5
    systemctl is-active --quiet redis-paopaodns && log_info "Redis: 运行中" || log_error "Redis: 未运行"
    systemctl is-active --quiet paopaodns && log_info "PaoPaoDNS: 运行中" || log_error "PaoPaoDNS: 未运行"
}

# 清理
cleanup() { rm -rf "$TEMP_DIR" 2>/dev/null; }

# 完成
done_msg() {
    echo ""
    echo "============================================"
    echo ""
    echo -e "${GREEN}    ★ 安装完成! ★${NC}"
    echo ""
    echo "  管理命令:"
    echo "    sudo systemctl start|stop|restart|status paopaodns"
    echo ""
    echo "  测试:"
    echo "    sudo /usr/local/bin/test.sh"
    echo "    nslookup -type=TXT whoami.ds.akahelp.net 127.0.0.1"
    echo ""
    echo "  配置: /etc/paopaodns/"
    echo "  数据: /var/lib/paopaodns/"
    echo ""
    echo "  卸载:"
    echo "    curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/uninstall-online.sh | sudo bash"
    echo ""
    echo "============================================"
}

# 主流程
main() {
    echo ""
    echo "============================================"
    echo "  PaoPaoDNS 一键安装 v${VERSION}"
    echo "============================================"
    echo ""
    
    check_root
    detect_system
    install_base
    install_deps
    download_release
    install_files
    create_users
    setup_redis
    create_services
    setup_firewall
    start_services
    verify
    cleanup
    done_msg
}

trap 'log_error "安装失败"; cleanup; exit 1' ERR
main "$@"