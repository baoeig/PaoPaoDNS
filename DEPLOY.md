# PaoPaoDNS 在线一键部署

## 快速安装

### 方式一：curl 安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-online.sh | sudo bash
```

### 方式二：wget 安装

```bash
wget -qO- https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-online.sh | sudo bash
```

### 方式三：下载后执行

```bash
# 下载脚本
wget https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-online.sh

# 添加执行权限
chmod +x install-online.sh

# 执行安装
sudo ./install-online.sh
```

## 系统要求

- **操作系统**: Linux (Ubuntu/Debian/CentOS/RHEL/Fedora/Arch/Alpine)
- **架构**: x86_64/amd64, arm64/aarch64, armv7, armv6, i686
- **权限**: root 或 sudo
- **内存**: 最低 256MB，推荐 1GB+
- **磁盘**: 至少 1GB 可用空间
- **网络**: 需要互联网连接

## 安装过程

脚本会自动完成以下操作：

1. ✓ 检测系统发行版和架构
2. ✓ 安装基础依赖
3. ✓ 尝试从 Docker 镜像提取文件（如已安装 Docker）
4. ✓ 或从 GitHub 下载预编译文件（如无 Docker）
5. ✓ 安装系统依赖库
6. ✓ 配置 Redis 缓存
7. ✓ 创建 systemd 服务
8. ✓ 配置防火墙规则
9. ✓ 启动并验证服务

## 安装后验证

```bash
# 检查服务状态
sudo systemctl status paopaodns

# 测试 DNS 解析
nslookup -type=TXT whoami.ds.akahelp.net 127.0.0.1

# 运行完整测试
sudo /usr/local/bin/test.sh
```

## 卸载

```bash
curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/uninstall.sh | sudo bash
```

## 常见问题

### Q: 没有 Docker 怎么办？
A: 脚本会自动从 GitHub 下载预编译文件，无需手动安装 Docker。

### Q: 安装失败怎么办？
A: 检查网络连接，确保可以访问 GitHub。也可以手动下载安装：
```bash
# 手动下载脚本
wget https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-online.sh

# 查看脚本内容
cat install-online.sh

# 手动执行
sudo bash install-online.sh
```

### Q: 如何修改 DNS 端口？
A: 编辑配置文件后重新加载：
```bash
sudo nano /etc/paopaodns/mosdns.yaml
sudo /usr/local/bin/reload.sh
```

### Q: 如何更新 IP 库？
A: 数据会定期自动更新，也可手动触发：
```bash
sudo /usr/local/bin/data_update.sh
```

## 文件位置

| 类型 | 路径 |
|------|------|
| 主配置 | `/etc/paopaodns/` |
| Unbound 配置 | `/etc/unbound/` |
| Redis 配置 | `/etc/redis/` |
| 数据文件 | `/var/lib/paopaodns/` |
| 日志文件 | `/var/log/paopaodns/` |
| 程序文件 | `/usr/local/bin/` |

## 服务管理

```bash
# 启动
sudo systemctl start paopaodns

# 停止
sudo systemctl stop paopaodns

# 重启
sudo systemctl restart paopaodns

# 查看状态
sudo systemctl status paopaodns

# 查看日志
sudo journalctl -u paopaodns -f

# 开机自启
sudo systemctl enable paopaodns

# 取消自启
sudo systemctl disable paopaodns
```

## 更多信息

- [项目主页](https://github.com/baoeig/PaoPaoDNS)
- [问题反馈](https://github.com/baoeig/PaoPaoDNS/issues)
- [详细文档](README.md)

## 许可证

本脚本遵循原项目许可证。