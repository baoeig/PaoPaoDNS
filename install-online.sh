#!/bin/bash
# ===========================================
# PaoPaoDNS 一键安装脚本
# 项目主页: https://github.com/baoeig/PaoPaoDNS
# 用法: 
#   curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-online.sh | sudo bash
#   或
#   wget -qO- https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-online.sh | sudo bash
# ===========================================

set -e

# 版本信息
VERSION="1.0.0"
GITHUB_REPO="baoeig/PaoPaoDNS"
DOCKER_IMAGE="sliamb/paopaodns:latest"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[→]${NC} $1"
}

log_success() {
    echo -e "${CYAN}[★]${NC} $1"
}

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用root权限运行此脚本"
        echo ""
        echo "正确用法："
        echo "  curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/install-online.sh | sudo bash"
        exit 1
    fi
}

# 检测Linux发行版
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO=$ID
        VERSION_ID=$VERSION_ID
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        DISTRO=$DISTRIB_ID
        VERSION_ID=$DISTRIB_RELEASE
    else
        DISTRO=$(uname -s | tr '[:upper:]' '[:lower:]')
        VERSION_ID=$(uname -r)
    fi
    log_info "检测到系统: ${DISTRO} ${VERSION_ID}"
}

# 检测系统架构
detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7l|armhf)
            ARCH="armv7"
            ;;
        armv6l)
            ARCH="armv6"
            ;;
        i686|i386)
            ARCH="386"
            ;;
        *)
            log_error "不支持的架构: $ARCH"
            exit 1
            ;;
    esac
    log_info "系统架构: ${ARCH}"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# 检查网络连接
check_network() {
    log_step "检查网络连接..."
    if command_exists curl; then
        if curl -s --connect-timeout 5 https://www.baidu.com > /dev/null 2>&1; then
            log_info "网络连接正常"
            return 0
        fi
    elif command_exists wget; then
        if wget -q --spider --timeout=5 https://www.baidu.com > /dev/null 2>&1; then
            log_info "网络连接正常"
            return 0
        fi
    fi
    log_warn "网络连接异常，可能影响安装"
    return 1
}

# 安装基础依赖
install_base_deps() {
    log_step "安装基础依赖..."
    
    case $DISTRO in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq wget curl xz-utils ca-certificates
            ;;
        centos|rhel|fedora)
            if [ "$DISTRO" = "centos" ] || [ "$DISTRO" = "rhel" ]; then
                yum install -y -q epel-release
            fi
            yum install -y -q wget curl xz ca-certificates
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm wget curl xz ca-certificates
            ;;
        alpine)
            apk add --no-cache wget curl xz ca-certificates
            ;;
        *)
            log_warn "未知发行版，尝试通用安装..."
            ;;
    esac
    
    log_info "基础依赖安装完成"
}

# 安装系统依赖
install_system_deps() {
    log_step "安装系统依赖..."
    
    case $DISTRO in
        ubuntu|debian)
            apt-get install -y -qq libevent-dev libhiredis-dev libssl-dev libexpat1-dev \
                tzdata cron inotify-tools bind9-host
            ;;
        centos|rhel|fedora)
            yum install -y -q libevent-devel hiredis-devel openssl-devel expat-devel \
                tzdata cronie inotify-tools bind-utils
            ;;
        arch|manjaro)
            pacman -Sy --noconfirm libevent hiredis openssl expat \
                tzdata cronie inotify-tools bind
            ;;
        alpine)
            apk add --no-cache libevent hiredis openssl expat \
                tzdata dcron inotify-tools bind-tools
            ;;
        *)
            log_warn "请手动安装: libevent hiredis openssl expat"
            ;;
    esac
    
    log_info "系统依赖安装完成"
}

# 检查Docker
check_docker() {
    if command_exists docker; then
        DOCKER_AVAILABLE=1
        log_info "Docker已安装"
        return 0
    else
        DOCKER_AVAILABLE=0
        log_info "Docker未安装，将使用在线下载方式"
        return 1
    fi
}

# 从Docker镜像提取文件
extract_from_docker() {
    log_step "从Docker镜像提取二进制文件..."
    
    EXTRACT_DIR=$(mktemp -d)
    
    # 拉取镜像
    log_info "拉取PaoPaoDNS镜像..."
    docker pull ${DOCKER_IMAGE}
    
    # 创建临时容器
    log_info "创建临时容器..."
    CONTAINER_ID=$(docker create ${DOCKER_IMAGE})
    
    # 提取二进制文件
    log_info "提取核心组件..."
    docker cp "${CONTAINER_ID}":/usr/sbin/unbound "${EXTRACT_DIR}/"
    docker cp "${CONTAINER_ID}":/usr/sbin/unbound-checkconf "${EXTRACT_DIR}/"
    docker cp "${CONTAINER_ID}":/usr/sbin/mosdns "${EXTRACT_DIR}/"
    docker cp "${CONTAINER_ID}":/usr/sbin/redis-server "${EXTRACT_DIR}/"
    docker cp "${CONTAINER_ID}":/usr/sbin/redis-cli "${EXTRACT_DIR}/"
    
    # 提取配置文件
    log_info "提取配置文件..."
    for file in init.sh unbound.conf unbound_custom.conf redis.conf mosdns.yaml \
                dnscrypt.toml custom_env.ini custom_mod.yaml data_update.sh \
                watch_list.sh test.sh debug.sh reload.sh \
                force_recurse_list.txt force_dnscrypt_list.txt force_forward_list.txt; do
        docker cp "${CONTAINER_ID}:/usr/sbin/${file}" "${EXTRACT_DIR}/" 2>/dev/null || true
    done
    
    # 提取数据文件
    log_info "提取数据文件..."
    docker cp "${CONTAINER_ID}":/usr/sbin/Country-only-cn-private.mmdb.xz "${EXTRACT_DIR}/" 2>/dev/null || true
    docker cp "${CONTAINER_ID}":/usr/sbin/global_mark.dat "${EXTRACT_DIR}/" 2>/dev/null || true
    docker cp "${CONTAINER_ID}":/usr/sbin/named.cache "${EXTRACT_DIR}/" 2>/dev/null || true
    docker cp "${CONTAINER_ID}":/usr/sbin/trackerslist.txt.xz "${EXTRACT_DIR}/" 2>/dev/null || true
    docker cp "${CONTAINER_ID}":/usr/sbin/dnscrypt-resolvers "${EXTRACT_DIR}/" 2>/dev/null || true
    
    # 清理容器
    docker rm "${CONTAINER_ID}" > /dev/null 2>&1
    
    log_info "文件提取完成"
}

# 从GitHub下载预编译文件（备用方案）
download_from_github() {
    log_step "从GitHub下载预编译文件..."
    
    EXTRACT_DIR=$(mktemp -d)
    cd "${EXTRACT_DIR}"
    
    # 这里需要在GitHub上提供预编译的release包
    # 下载地址示例：
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/latest/download"
    
    # 下载主程序包
    log_info "下载PaoPaoDNS程序包..."
    if command_exists wget; then
        wget -q "${DOWNLOAD_URL}/paopaodns-linux-${ARCH}.tar.xz" -O paopaodns.tar.xz || {
            log_error "下载失败，请检查网络或手动下载"
            log_error "下载地址: ${DOWNLOAD_URL}/paopaodns-linux-${ARCH}.tar.xz"
            exit 1
        }
    elif command_exists curl; then
        curl -fsSL "${DOWNLOAD_URL}/paopaodns-linux-${ARCH}.tar.xz" -o paopaodns.tar.xz || {
            log_error "下载失败，请检查网络或手动下载"
            exit 1
        }
    fi
    
    # 解压
    log_info "解压文件..."
    xz -d paopaodns.tar.xz 2>/dev/null || true
    tar xf paopaodns.tar 2>/dev/null || true
    
    log_info "下载完成"
}

# 安装文件
install_files() {
    log_step "安装PaoPaoDNS..."
    
    cd "${EXTRACT_DIR}"
    
    # 创建目录
    mkdir -p /etc/unbound
    mkdir -p /etc/redis
    mkdir -p /etc/paopaodns
    mkdir -p /var/lib/paopaodns
    mkdir -p /var/log/paopaodns
    mkdir -p /var/run/redis
    
    # 安装二进制文件
    if [ -f unbound ] && [ -f mosdns ] && [ -f redis-server ]; then
        cp -f unbound unbound-checkconf mosdns redis-server redis-cli /usr/local/bin/
        chmod +x /usr/local/bin/unbound /usr/local/bin/unbound-checkconf /usr/local/bin/mosdns \
            /usr/local/bin/redis-server /usr/local/bin/redis-cli
    else
        log_error "核心二进制文件缺失"
        exit 1
    fi
    
    # 安装配置文件
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
    
    # 安装数据文件
    [ -f Country-only-cn-private.mmdb.xz ] && cp -f Country-only-cn-private.mmdb.xz /var/lib/paopaodns/
    [ -f global_mark.dat ] && cp -f global_mark.dat /var/lib/paopaodns/
    [ -f named.cache ] && cp -f named.cache /var/lib/paopaodns/
    [ -f trackerslist.txt.xz ] && cp -f trackerslist.txt.xz /var/lib/paopaodns/
    [ -d dnscrypt-resolvers ] && cp -rf dnscrypt-resolvers /var/lib/paopaodns/
    
    # 解压数据文件
    cd /var/lib/paopaodns
    [ -f Country-only-cn-private.mmdb.xz ] && xz -d Country-only-cn-private.mmdb.xz 2>/dev/null || true
    [ -f trackerslist.txt.xz ] && xz -d trackerslist.txt.xz 2>/dev/null || true
    
    # 安装脚本
    for script in init.sh data_update.sh watch_list.sh test.sh debug.sh reload.sh; do
        if [ -f "${EXTRACT_DIR}/${script}" ]; then
            cp -f "${EXTRACT_DIR}/${script}" /usr/local/bin/
            chmod +x "/usr/local/bin/${script}"
        fi
    done
    
    log_info "文件安装完成"
}

# 创建用户
create_users() {
    log_step "创建系统用户..."
    
    if ! id -u unbound > /dev/null 2>&1; then
        useradd -r -s /bin/false -d /etc/unbound unbound 2>/dev/null || true
    fi
    
    if ! id -u redis > /dev/null 2>&1; then
        useradd -r -s /bin/false -d /var/lib/redis redis 2>/dev/null || true
    fi
    
    chown -R redis:redis /var/lib/redis 2>/dev/null || true
    chown -R redis:redis /var/run/redis 2>/dev/null || true
    
    log_info "用户创建完成"
}

# 配置Redis
configure_redis() {
    log_step "配置Redis..."
    
    if [ ! -f /etc/redis/redis-paopaodns.conf ] || [ "${FORCE_INSTALL}" = "1" ]; then
        cat > /etc/redis/redis-paopaodns.conf << 'EOF'
# PaoPaoDNS Redis配置
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
tcp-backlog 511
timeout 0
tcp-keepalive 300
loglevel notice
databases 16
EOF
    fi
    
    log_info "Redis配置完成"
}

# 创建systemd服务
create_services() {
    log_step "创建系统服务..."
    
    # Redis服务
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

    # PaoPaoDNS主服务
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
Environment=DATA_DIR=/var/lib/paopaodns
Environment=CONFIG_DIR=/etc/paopaodns

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    
    log_info "服务创建完成"
}

# 配置防火墙
configure_firewall() {
    log_step "配置防火墙..."
    
    if command_exists firewall-cmd; then
        firewall-cmd --permanent --add-port=53/tcp 2>/dev/null || true
        firewall-cmd --permanent --add-port=53/udp 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        log_info "firewalld配置完成"
    elif command_exists ufw; then
        ufw allow 53/tcp 2>/dev/null || true
        ufw allow 53/udp 2>/dev/null || true
        log_info "ufw配置完成"
    elif command_exists iptables; then
        iptables -A INPUT -p tcp --dport 53 -j ACCEPT 2>/dev/null || true
        iptables -A INPUT -p udp --dport 53 -j ACCEPT 2>/dev/null || true
        log_info "iptables配置完成"
    else
        log_warn "未检测到防火墙，请手动开放53端口"
    fi
}

# 启动服务
start_services() {
    log_step "启动服务..."
    
    systemctl start redis-paopaodns
    systemctl enable redis-paopaodns
    log_info "Redis服务已启动"
    
    sleep 2
    
    systemctl start paopaodns
    systemctl enable paopaodns
    log_info "PaoPaoDNS服务已启动"
}

# 验证安装
verify_installation() {
    log_step "验证安装..."
    
    sleep 5
    
    local status=0
    
    if systemctl is-active --quiet redis-paopaodns; then
        log_info "Redis服务: 运行中"
    else
        log_error "Redis服务: 未运行"
        status=1
    fi
    
    if systemctl is-active --quiet paopaodns; then
        log_info "PaoPaoDNS服务: 运行中"
    else
        log_error "PaoPaoDNS服务: 未运行"
        status=1
    fi
    
    # 测试DNS
    if command_exists nslookup; then
        if nslookup -type=TXT whoami.ds.akahelp.net 127.0.0.1 > /dev/null 2>&1; then
            log_info "DNS解析测试: 成功"
        else
            log_warn "DNS解析测试: 等待启动..."
        fi
    fi
    
    return $status
}

# 清理
cleanup() {
    if [ -d "${EXTRACT_DIR}" ]; then
        rm -rf "${EXTRACT_DIR}"
    fi
}

# 打印安装摘要
print_summary() {
    echo ""
    echo "============================================"
    echo ""
    echo -e "${GREEN}    ★ PaoPaoDNS 安装完成! ★${NC}"
    echo ""
    echo "============================================"
    echo ""
    echo "  服务管理:"
    echo "    启动: sudo systemctl start paopaodns"
    echo "    停止: sudo systemctl stop paopaodns"
    echo "    状态: sudo systemctl status paopaodns"
    echo "    日志: sudo journalctl -u paopaodns -f"
    echo ""
    echo "  配置目录: /etc/paopaodns/"
    echo "  数据目录: /var/lib/paopaodns/"
    echo "  日志目录: /var/log/paopaodns/"
    echo ""
    echo "  测试命令:"
    echo "    sudo /usr/local/bin/test.sh"
    echo "    nslookup -type=TXT whoami.ds.akahelp.net 127.0.0.1"
    echo ""
    echo "  卸载命令:"
    echo "    curl -fsSL https://raw.githubusercontent.com/${GITHUB_REPO}/main/uninstall.sh | sudo bash"
    echo ""
    echo "============================================"
}

# 主函数
main() {
    echo ""
    echo "============================================"
    echo "  PaoPaoDNS 一键安装脚本 v${VERSION}"
    echo "  https://github.com/${GITHUB_REPO}"
    echo "============================================"
    echo ""
    
    # 检查root
    check_root
    
    # 检测系统
    detect_distro
    detect_arch
    
    # 检查网络
    check_network
    
    # 安装基础依赖
    install_base_deps
    
    # 检查Docker
    check_docker
    
    # 获取文件
    if [ "${DOCKER_AVAILABLE}" = "1" ]; then
        extract_from_docker
    else
        download_from_github
    fi
    
    # 安装系统依赖
    install_system_deps
    
    # 安装文件
    install_files
    
    # 创建用户
    create_users
    
    # 配置
    configure_redis
    create_services
    configure_firewall
    
    # 启动服务
    start_services
    
    # 验证
    if verify_installation; then
        log_success "安装成功！"
    else
        log_warn "服务可能需要更多时间启动"
    fi
    
    # 清理
    cleanup
    
    # 打印摘要
    print_summary
}

# 错误处理
trap 'log_error "安装过程中出现错误，请检查上方日志"; cleanup; exit 1' ERR

# 运行
main "$@"