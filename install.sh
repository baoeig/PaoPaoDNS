#!/bin/sh
# ===========================================
# PaoPaoDNS Alpine 宿主机部署脚本
# 和 Docker 镜像环境完全一致，直接复用
# 用法：wget -qO- https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install.sh | sh
# ===========================================

set -e

REPO_RAW="https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main"

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { printf "${GREEN}[✓]${NC} %s\n" "$1"; }
log_error() { printf "${RED}[✗]${NC} %s\n" "$1"; }
log_step()  { printf "${BLUE}[→]${NC} %s\n" "$1"; }

[ "$(id -u)" -eq 0 ] || { log_error "请用 root 执行"; exit 1; }

# 下载
dl() {
    curl -4sLo "$2" "$1" 2>/dev/null || wget -qO "$2" "$1" 2>/dev/null
    [ -f "$2" ] && [ -s "$2" ] || { log_error "下载失败: $1"; return 1; }
}

# ===========================================
# 1. 安装依赖（和 Dockerfile 一致）
# ===========================================
install_deps() {
    log_step "安装依赖..."
    apk update
    apk upgrade --no-cache
    apk add --no-cache \
        ca-certificates dcron tzdata hiredis libevent \
        dnscrypt-proxy inotify-tools bind-tools libgcc xz \
        curl git redis unbound
    log_info "依赖安装完成"
}

# ===========================================
# 2. 下载配置和数据（对应 build.sh 的步骤）
# ===========================================
download_all() {
    log_step "下载配置和数据..."
    
    mkdir -p /src /data /etc/unbound
    
    # --- named.cache (来自 internic.net) ---
    dl "https://www.internic.net/domain/named.cache" /src/named.cache
    cp /src/named.cache /etc/unbound/named.cache
    cp /src/named.cache /data/named.cache
    
    # --- mmdb (来自 kkkgo/Country-only-cn-private.mmdb) ---
    dl "https://github.com/kkkgo/Country-only-cn-private.mmdb/raw/main/Country-only-cn-private.mmdb.xz" \
       /src/Country-only-cn-private.mmdb.xz
    
    # --- global_mark.dat (来自 kkkgo/PaoPao-Pref) ---
    dl "https://github.com/kkkgo/PaoPao-Pref/raw/main/global_mark.dat" \
       /src/global_mark.dat
    
    # --- trackerslist (来自 kkkgo/all-tracker-list) ---
    dl "https://github.com/kkkgo/all-tracker-list/raw/main/trackerslist.txt.xz" \
       /src/trackerslist.txt.xz
    
    # --- dnscrypt-resolvers ---
    mkdir -p /src/dnscrypt-resolvers
    dl "https://github.com/DNSCrypt/dnscrypt-resolvers/raw/master/v3/public-resolvers.md" \
       /src/dnscrypt-resolvers/public-resolvers.md
    dl "https://github.com/DNSCrypt/dnscrypt-resolvers/raw/master/v3/public-resolvers.md.minisig" \
       /src/dnscrypt-resolvers/public-resolvers.md.minisig
    dl "https://github.com/DNSCrypt/dnscrypt-resolvers/raw/master/v3/relays.md" \
       /src/dnscrypt-resolvers/relays.md
    dl "https://github.com/DNSCrypt/dnscrypt-resolvers/raw/master/v3/relays.md.minisig" \
       /src/dnscrypt-resolvers/relays.md.minisig
    
    log_info "数据下载完成"
}

# ===========================================
# 3. 下载仓库源码配置
# ===========================================
download_src() {
    log_step "下载配置文件..."
    
    # 从仓库 src/ 目录下载
    for f in init.sh unbound.conf unbound_custom.conf redis.conf mosdns.yaml \
             dnscrypt.toml custom_env.ini custom_mod.yaml data_update.sh \
             watch_list.sh test.sh debug.sh reload.sh ub_trace.sh \
             force_recurse_list.txt force_dnscrypt_list.txt force_forward_list.txt; do
        dl "${REPO_RAW}/src/${f}" "/src/${f}"
        chmod +x "/src/${f}" 2>/dev/null
    done
    
    # 替换构建时间
    bt=$(date +"%Y-%m-%d %H:%M:%S %Z")
    sed -i "s/{bulidtime}/$bt/g" /src/init.sh 2>/dev/null
    sed -i "s/{bulidtime}/$bt/g" /src/debug.sh 2>/dev/null
    sed -i "s/{bulidtime}/$bt/g" /src/test.sh 2>/dev/null
    sed -i "s/{bulidtime}/$bt/g" /src/ub_trace.sh 2>/dev/null
    
    chmod +x /src/*.sh
    
    log_info "配置文件下载完成"
}

# ===========================================
# 4. 安装 mosdns（需要从 Release 下载）
# ===========================================
install_mosdns() {
    log_step "安装 mosdns..."
    
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  MOSDNS_ARCH="linux_amd64";;
        aarch64) MOSDNS_ARCH="linux_arm64";;
        armv7l)  MOSDNS_ARCH="linux_armv7";;
        *)       log_error "不支持的架构: $ARCH"; exit 1;;
    esac
    
    # 尝试从 GitHub 下载
    MOSDNS_URL="https://github.com/kkkgo/mosdns/releases/latest/download/mosdns-${MOSDNS_ARCH}.zip"
    dl "$MOSDNS_URL" /tmp/mosdns.zip && {
        cd /tmp
        unzip -o mosdns.zip mosdns 2>/dev/null || true
        [ -f mosdns ] && {
            mv mosdns /src/mosdns
            chmod +x /src/mosdns
            log_info "mosdns 安装完成"
            return 0
        }
    }
    
    log_error "mosdns 下载失败，请手动放置 /src/mosdns"
    log_error "或从 Docker 镜像提取: docker cp \$(docker create sliamb/paopaodns):/usr/sbin/mosdns /src/"
}

# ===========================================
# 5. 复制文件到运行位置（和 Dockerfile 一致）
# ===========================================
install_files() {
    log_step "安装文件..."
    
    # 复制到 /usr/sbin/（和 Docker 镜像一致）
    cp -f /src/* /usr/sbin/ 2>/dev/null
    cp -rf /src/dnscrypt-resolvers /usr/sbin/ 2>/dev/null
    chmod +x /usr/sbin/*.sh 2>/dev/null
    
    # unbound 配置
    mkdir -p /etc/unbound
    cp -f /usr/sbin/named.cache /etc/unbound/named.cache
    cp -f /usr/sbin/unbound.conf /etc/unbound/
    cp -f /usr/sbin/unbound_custom.conf /etc/unbound/
    
    # 数据目录（/data 对应 docker -v /home/mydata:/data）
    mkdir -p /data
    cp -f /usr/sbin/redis.conf /data/ 2>/dev/null
    cp -f /usr/sbin/unbound.conf /data/ 2>/dev/null
    cp -f /usr/sbin/mosdns.yaml /data/ 2>/dev/null
    cp -f /usr/sbin/dnscrypt.toml /data/ 2>/dev/null
    cp -f /usr/sbin/*.sh /data/ 2>/dev/null
    cp -f /usr/sbin/*.ini /data/ 2>/dev/null
    cp -f /usr/sbin/force_*.txt /data/ 2>/dev/null
    cp -rf /usr/sbin/dnscrypt-resolvers /data/ 2>/dev/null
    
    # 解压数据
    cd /data
    [ -f /src/Country-only-cn-private.mmdb.xz ] && {
        cp /src/Country-only-cn-private.mmdb.xz /data/
        xz -d /data/Country-only-cn-private.mmdb.xz
    }
    [ -f /src/global_mark.dat ] && cp /src/global_mark.dat /data/
    [ -f /src/trackerslist.txt.xz ] && {
        cp /src/trackerslist.txt.xz /data/
        xz -d /data/trackerslist.txt.xz
    }
    cp -rf /src/dnscrypt-resolvers /data/ 2>/dev/null
    
    # redis 数据目录
    mkdir -p /data/redis /var/log/redis
    chown -R redis:redis /data/redis 2>/dev/null || true
    
    log_info "文件安装完成"
}

# ===========================================
# 6. 添加用户（和 Dockerfile 一致）
# ===========================================
create_user() {
    id -u unbound >/dev/null 2>&1 || adduser -D -H unbound
}

# ===========================================
# 7. 创建 OpenRC 服务（Alpine 用 OpenRC）
# ===========================================
create_service() {
    log_step "创建系统服务..."
    
    # Redis 服务
    cat > /etc/init.d/paopaodns-redis << 'EOF'
#!/sbin/openrc-run

name="PaoPaoDNS Redis"
command="/usr/sbin/redis-server"
command_args="/data/redis.conf"
command_background=true
pidfile="/run/paopaodns-redis.pid"
output_log="/var/log/redis/redis.log"
error_log="/var/log/redis/redis.log"

depend() {
    need net
    after firewall
}

start_pre() {
    mkdir -p /data/redis /var/log/redis
    [ -f /data/redis.conf ] || cp /etc/redis/redis.conf /data/redis.conf
}
EOF
    chmod +x /etc/init.d/paopaodns-redis

    # PaoPaoDNS 主服务
    cat > /etc/init.d/paopaodns << 'EOF'
#!/sbin/openrc-run

name="PaoPaoDNS"
command="/usr/sbin/init.sh"
command_background=true
pidfile="/run/paopaodns.pid"
output_log="/var/log/paopaodns.log"
error_log="/var/log/paopaodns.log"

depend() {
    need net
    after paopaodns-redis
    after firewall
}

start_pre() {
    mkdir -p /data /var/log
    chmod +x /data/*.sh 2>/dev/null
}
EOF
    chmod +x /etc/init.d/paopaodns

    # 开机启动
    rc-update add paopaodns-redis default
    rc-update add paopaodns default
    
    log_info "服务创建完成"
}

# ===========================================
# 8. 启动
# ===========================================
start_services() {
    log_step "启动服务..."
    
    rc-service paopaodns-redis start
    sleep 2
    rc-service paopaodns start
    sleep 5
    
    if rc-service paopaodns status >/dev/null 2>&1; then
        log_info "PaoPaoDNS 已启动"
    else
        log_info "启动中，请稍后验证"
    fi
}

# ===========================================
# 完成
# ===========================================
done_msg() {
    echo ""
    echo "=========================================="
    printf "${GREEN}  PaoPaoDNS 部署完成！${NC}\n"
    echo "=========================================="
    echo ""
    echo "  验证:   /data/test.sh"
    echo "  状态:   rc-service paopaodns status"
    echo "  日志:   tail -f /var/log/paopaodns.log"
    echo "  配置:   /data/"
    echo ""
    echo "  和 Docker 完全一致:"
    echo "    /data/    ← 对应 docker -v /home/mydata:/data"
    echo "    /usr/sbin/ ← 程序位置"
    echo ""
    echo "=========================================="
}

# ===========================================
# 主流程（对应 Dockerfile 的构建步骤）
# ===========================================
main() {
    echo ""
    echo "=========================================="
    echo "  PaoPaoDNS Alpine 宿主机部署"
    echo "=========================================="
    echo ""
    
    # 1. apk add ... (对应 Dockerfile RUN apk add)
    install_deps
    
    # 2. git clone 各种数据 (对应 build.sh)
    download_all
    
    # 3. COPY src/ (对应 Dockerfile COPY src/ /src/)
    download_src
    
    # 4. mosdns (对应 prebuild-paopaodns)
    install_mosdns
    
    # 5. COPY --from=builder /src/ /usr/sbin/ (对应 Dockerfile)
    install_files
    
    # 6. adduser (对应 Dockerfile)
    create_user
    
    # 7. 创建服务 (替代 CMD init.sh)
    create_service
    
    # 8. 启动 (替代 docker run)
    start_services
    
    done_msg
}

main "$@"