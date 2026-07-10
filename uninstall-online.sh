#!/bin/bash
# ===========================================
# PaoPaoDNS 卸载脚本
# 用法: 
#   curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/uninstall.sh | sudo bash
# ===========================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用root权限运行此脚本"
    echo "用法: curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/uninstall.sh | sudo bash"
    exit 1
fi

echo ""
echo "============================================"
echo "  PaoPaoDNS 卸载脚本"
echo "============================================"
echo ""

# 确认卸载
read -p "确定要卸载PaoPaoDNS吗？(y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "取消卸载"
    exit 0
fi

log_warn "开始卸载PaoPaoDNS..."

# 停止服务
log_step "停止服务..."
systemctl stop paopaodns 2>/dev/null || true
systemctl stop redis-paopaodns 2>/dev/null || true
systemctl disable paopaodns 2>/dev/null || true
systemctl disable redis-paopaodns 2>/dev/null || true
log_info "服务已停止"

# 删除systemd服务
log_step "删除系统服务..."
rm -f /etc/systemd/system/paopaodns.service
rm -f /etc/systemd/system/redis-paopaodns.service
systemctl daemon-reload
log_info "服务文件已删除"

# 删除二进制文件
log_step "删除程序文件..."
rm -f /usr/local/bin/unbound
rm -f /usr/local/bin/unbound-checkconf
rm -f /usr/local/bin/mosdns
rm -f /usr/local/bin/redis-server
rm -f /usr/local/bin/redis-cli
rm -f /usr/local/bin/init.sh
rm -f /usr/local/bin/data_update.sh
rm -f /usr/local/bin/watch_list.sh
rm -f /usr/local/bin/test.sh
rm -f /usr/local/bin/debug.sh
rm -f /usr/local/bin/reload.sh
log_info "程序文件已删除"

# 备份配置文件
log_step "备份配置文件..."
BACKUP_DIR="/etc/paopaodns.backup.$(date +%Y%m%d%H%M%S)"

if [ -d /etc/paopaodns ]; then
    cp -r /etc/paopaodns "${BACKUP_DIR}"
    rm -rf /etc/paopaodns
    log_info "配置已备份到: ${BACKUP_DIR}"
fi

if [ -f /etc/redis/redis-paopaodns.conf ]; then
    rm -f /etc/redis/redis-paopaodns.conf
fi

# 询问是否删除数据
echo ""
read -p "是否删除数据目录(/var/lib/paopaodns)？(y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ -d /var/lib/paopaodns ]; then
        rm -rf /var/lib/paopaodns
        log_info "数据目录已删除"
    fi
else
    log_info "数据目录保留: /var/lib/paopaodns"
fi

# 删除日志
if [ -d /var/log/paopaodns ]; then
    rm -rf /var/log/paopaodns
fi

# 询问是否删除用户
echo ""
read -p "是否删除系统用户(unbound, redis)？(y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    userdel unbound 2>/dev/null || true
    userdel redis 2>/dev/null || true
    log_info "系统用户已删除"
fi

echo ""
echo "============================================"
echo ""
echo -e "${GREEN}    PaoPaoDNS 卸载完成！${NC}"
echo ""
echo "============================================"
echo ""
echo "  配置备份: ${BACKUP_DIR}"
echo ""
echo "  如需重新安装，请运行："
echo "    curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-online.sh | sudo bash"
echo ""
echo "============================================"