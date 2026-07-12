#!/bin/sh

set -eu

info() { printf '\033[32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请使用 root 用户执行"
[ -f /etc/alpine-release ] || die "此卸载器仅支持 Alpine Linux"

if [ -x /etc/init.d/paopaodns ]; then
    rc-service paopaodns stop || true
    rc-update del paopaodns default >/dev/null 2>&1 || true
fi

rm -f /etc/init.d/paopaodns /etc/conf.d/paopaodns /run/paopaodns.pid

for path in \
    /usr/sbin/Country.mmdb /usr/sbin/admin.html /usr/sbin/admin_server.py \
    /usr/sbin/custom_env.ini /usr/sbin/custom_mod.yaml /usr/sbin/data_update.sh \
    /usr/sbin/debug.sh /usr/sbin/dnscrypt.toml /usr/sbin/force_dnscrypt_list.txt \
    /usr/sbin/force_forward_list.txt /usr/sbin/force_recurse_list.txt \
    /usr/sbin/global_mark.dat /usr/sbin/init.sh /usr/sbin/mosdns \
    /usr/sbin/mosdns.yaml /usr/sbin/named.cache /usr/sbin/redis.conf \
    /usr/sbin/redis-cli /usr/sbin/redis-server /usr/sbin/repositories \
    /usr/sbin/regen_mosdns.sh /usr/sbin/reload.sh /usr/sbin/test.sh \
    /usr/sbin/trackerslist.txt.xz /usr/sbin/ub_trace.sh \
    /usr/sbin/unbound /usr/sbin/unbound-checkconf /usr/sbin/unbound.conf \
    /usr/sbin/unbound_custom.conf \
    /usr/sbin/watch_list.sh; do
    rm -f "$path"
done
rm -rf /usr/sbin/dnscrypt-resolvers

apk fix redis unbound >/dev/null 2>&1 || true
rm -f /tmp/redis.sock /tmp/redis-server.pid /tmp/unbound.pid

if [ "${PURGE_DATA:-no}" = yes ]; then
    rm -rf /data
    info "已删除 /data"
else
    info "已保留 /data；如需删除，使用 PURGE_DATA=yes 重新执行"
fi

info "PaoPaoDNS 原生服务已卸载"
