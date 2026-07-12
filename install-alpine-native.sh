#!/bin/sh

set -eu

PAOPAO_REPO="${PAOPAO_REPO:-baoeig/PaoPaoDNS}"
PAOPAO_REF="${PAOPAO_REF:-main}"
BUILD_ROOT="${BUILD_ROOT:-/var/tmp/paopaodns-build}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)

info() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请使用 root 用户执行"
[ -f /etc/alpine-release ] || die "此安装器仅支持 Alpine Linux"
command -v rc-service >/dev/null 2>&1 || die "当前 Alpine 未安装或未启用 OpenRC"

case "$(uname -m)" in
    x86_64|aarch64|armv7l|armv6l|i?86|ppc64le|s390x) ;;
    *) die "暂不支持的架构: $(uname -m)" ;;
esac

if ss -lntu 2>/dev/null | grep -Eq '(^|[.:])53[[:space:]]'; then
    warn "检测到 53 端口已被占用；安装后 PaoPaoDNS 可能无法启动"
    ss -lntup 2>/dev/null | grep -E '(^|[.:])53[[:space:]]' || true
fi

info "安装 Alpine 构建与运行依赖"
apk update
apk add --no-cache \
    alpine-sdk bash bc bind-tools byacc ca-certificates curl dcron dnscrypt-proxy \
    expat-dev flex git go hiredis hiredis-dev inotify-tools iproute2 libevent \
    libevent-dev libgcc linux-headers openssl-dev py3-flask py3-redis python3 \
    redis swig tzdata xz
apk fix redis >/dev/null

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT/repo" /src /data /etc/unbound

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install-alpine-native.sh" ] && [ -d "$SCRIPT_DIR/src" ]; then
    info "使用当前仓库的本地源码: $SCRIPT_DIR/src"
    cp -R "$SCRIPT_DIR/src/." "$BUILD_ROOT/repo/src/"
    [ -f "$SCRIPT_DIR/native/paopaodns.openrc" ] || die "本地仓库缺少 native/paopaodns.openrc"
    mkdir -p "$BUILD_ROOT/repo/native"
    cp "$SCRIPT_DIR/native/paopaodns.openrc" "$BUILD_ROOT/repo/native/"
else
    info "下载源码: $PAOPAO_REPO@$PAOPAO_REF"
    archive="$BUILD_ROOT/source.tar.gz"
    curl -fL --retry 3 \
        "https://github.com/${PAOPAO_REPO}/archive/${PAOPAO_REF}.tar.gz" \
        -o "$archive"
    tar -xzf "$archive" -C "$BUILD_ROOT/repo" --strip-components=1
fi

[ -f "$BUILD_ROOT/repo/src/init.sh" ] || die "源码中缺少 src/init.sh"
[ -f "$BUILD_ROOT/repo/src/build.sh" ] || die "源码中缺少 src/build.sh"
rm -rf /src/*
cp -R "$BUILD_ROOT/repo/src/." /src/
find /src -type f -name '*.sh' -exec sed -i 's/\r$//' {} +

info "编译带 hiredis 缓存支持的 Unbound"
git clone --depth 1 https://github.com/NLnetLabs/unbound.git "$BUILD_ROOT/unbound"
(
    cd "$BUILD_ROOT/unbound"
    export CFLAGS="-O3"
    ./configure --with-libevent --with-pthreads --with-libhiredis --enable-cachedb \
        --disable-rpath --without-pythonmodule --disable-documentation \
        --disable-flto --disable-maintainer-mode --disable-option-checking \
        --with-pidfile=/tmp/unbound.pid --prefix=/usr --sysconfdir=/etc \
        --localstatedir=/tmp --with-username=root --with-chroot-dir=""
    make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    make DESTDIR="$BUILD_ROOT/unbound-stage" install
    cp "$BUILD_ROOT/unbound-stage/usr/sbin/unbound" /src/unbound
    cp "$BUILD_ROOT/unbound-stage/usr/sbin/unbound-checkconf" /src/unbound-checkconf
)

info "编译项目定制 MosDNS"
git clone --depth 1 https://github.com/kkkgo/mosdns "$BUILD_ROOT/mosdns"
(
    cd "$BUILD_ROOT/mosdns"
    GOTOOLCHAIN=auto go build -ldflags "-s -w" -trimpath -o /src/mosdns
)

info "生成运行配置和规则数据"
rm -rf /PaoPao-Pref /dnscrypt-proxy /dnscrypt /all-tracker-list
sed -i \
    -e '/^apk update$/d' \
    -e '/^apk upgrade$/d' \
    -e '/^apk add curl redis git$/d' \
    -e '/^rm -rf \/usr\/bin\/redis-benchmark$/d' \
    -e 's#^mv /usr/bin/redis\* /src/$#cp /usr/bin/redis-server /usr/bin/redis-cli /src/#' \
    -e 's#curl -sLo#curl -4fLsS --retry 4 --retry-delay 2 -o#g' \
    -e 's#curl -4Ls#curl -4fLsS --retry 4 --retry-delay 2#g' \
    /src/build.sh
sh /src/build.sh
rm -rf /PaoPao-Pref /dnscrypt-proxy /dnscrypt /all-tracker-list

[ -x /src/unbound ] || die "Unbound 构建失败"
[ -x /src/mosdns ] || die "MosDNS 构建失败"
[ -x /src/redis-server ] || die "Redis 文件准备失败"
[ -f /src/Country.mmdb ] || die "GeoIP 数据准备失败"
[ -f /src/dnscrypt.toml ] || die "DNSCrypt 配置准备失败"

info "安装文件到与 Docker 镜像一致的位置"
if rc-service paopaodns status >/dev/null 2>&1; then
    rc-service paopaodns stop || true
fi
cp -R /src/. /usr/sbin/
chmod +x /usr/sbin/*.sh /usr/sbin/mosdns /usr/sbin/unbound \
    /usr/sbin/unbound-checkconf /usr/sbin/redis-server /usr/sbin/redis-cli
cp /usr/sbin/named.cache /etc/unbound/named.cache
id unbound >/dev/null 2>&1 || adduser -D -H unbound

if [ ! -f /etc/conf.d/paopaodns ]; then
    cat > /etc/conf.d/paopaodns <<'EOF'
export TZ="Asia/Shanghai"
export UPDATE="weekly"
export DNS_SERVERNAME="PaoPaoDNS,blog.03k.org"
export DNSPORT="53"
export CNAUTO="yes"
export CNFALL="yes"
export CN_RECURSE="yes"
export CNFALL_QTIME="3"
export CN_TRACKER="yes"
export USE_HOSTS="no"
export IPV6="no"
export SOCKS5="IP:PORT"
export SERVER_IP="auto"
export CUSTOM_FORWARD="IP:PORT"
export CUSTOM_FORWARD_TTL="0"
export AUTO_FORWARD="no"
export AUTO_FORWARD_CHECK="yes"
export ROUTE_MODE="cn_first"
export USE_MARK_DATA="yes"
export RULES_TTL="0"
export HTTP_FILE="no"
export QUERY_TIME="2000ms"
export QUERY_LOG_MAX_MB="10"
export QUERY_LOG_CLEAN_INTERVAL="600"
export QUERY_ANSWER_LOG_MAX_LINES="5000"
export ADDINFO="no"
export SHUFFLE="no"
export EXPIRED_FLUSH="yes"
export SAFEMODE="no"
export ADMIN_PANEL="yes"
EOF
fi

cp "$BUILD_ROOT/repo/native/paopaodns.openrc" /etc/init.d/paopaodns
chmod +x /etc/init.d/paopaodns
rc-update add paopaodns default >/dev/null 2>&1 || true

info "启动 PaoPaoDNS"
rc-service paopaodns start

ready=no
attempt=0
while [ "$attempt" -lt 60 ]; do
    if nslookup baidu.com 127.0.0.1 >/dev/null 2>&1; then
        ready=yes
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done

if [ "$ready" != yes ]; then
    tail -n 200 /var/log/paopaodns.log 2>/dev/null || true
    die "DNS 服务未能在 60 秒内通过解析测试"
fi

info "运行确定性组件自检"
redis-cli -s /tmp/redis.sock ping | grep -qx PONG || die "Redis 自检失败"
pgrep -f 'mosdns start' >/dev/null || die "MosDNS 未运行"
pgrep dnscrypt-proxy >/dev/null || die "DNSCrypt 未运行"
[ "$(pgrep -x unbound | wc -l)" -ge 2 ] || die "Unbound 实例数量不足"
dig +time=5 +tries=1 @127.0.0.1 -p 53 baidu.com A +short | grep -Eq '^[0-9]+\.' || die "DNS 53 国内解析失败"
dig +time=5 +tries=1 @127.0.0.1 -p 53 google.com A +short | grep -Eq '^[0-9]+\.' || die "DNS 53 国外解析失败"
dig +time=5 +tries=1 @127.0.0.1 -p 5301 baidu.com A +short | grep -Eq '^[0-9]+\.' || die "Unbound 5301 解析失败"
dig +time=10 +tries=1 @127.0.0.1 -p 5302 google.com A +short | grep -Eq '^[0-9]+\.' || die "DNSCrypt 5302 解析失败"

if grep -q '^export ADMIN_PANEL="yes"' /etc/conf.d/paopaodns; then
    wget -qO- http://127.0.0.1:8080/api/status | grep -q '"mosdns":true' || die "管理后台自检失败"
fi

test_output=$(/usr/sbin/test.sh 2>&1 || true)
printf '%s\n' "$test_output"
if ! printf '%s\n' "$test_output" | grep -q 'ALL TEST PASS'; then
    warn "公网劫持检测未全部通过；本地组件和解析自检已通过"
fi

rm -rf "$BUILD_ROOT"
info "安装完成"
printf '%s\n' \
    "状态: rc-service paopaodns status" \
    "日志: tail -f /var/log/paopaodns.log" \
    "配置和数据: /data" \
    "管理后台: http://本机IP:8080"
