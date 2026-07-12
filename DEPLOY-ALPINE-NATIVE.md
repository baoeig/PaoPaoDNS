# Alpine 原生一键部署

该方式不使用 Docker。安装后的运行路径与 Docker 镜像保持一致：程序位于
`/usr/sbin`，配置和持久化数据位于 `/data`，服务由 OpenRC 管理。

## 系统要求

- Alpine Linux 3.20 或更新版本
- OpenRC
- root 权限
- 至少 1 GB 可用磁盘；源码编译期间建议 2 GB 以上内存
- TCP/UDP 53 端口未被其他服务占用
- 能够访问 Alpine 软件源、GitHub、Go 模块源和 Internic

支持的架构包括 `x86_64`、`aarch64`、`armv7l`、`armv6l`、x86、
`ppc64le` 和 `s390x`。实际可用性还取决于相应架构的 Alpine 和上游 Go 模块支持。

## 使用当前本地源码安装

在仓库根目录执行：

```sh
chmod +x install-alpine-native.sh
doas ./install-alpine-native.sh
```

root 用户直接执行：

```sh
./install-alpine-native.sh
```

安装器检测到旁边的 `src/` 和 `native/` 后，会优先使用本地文件，因此你的未提交
修改也会进入安装结果。Shell 文件使用 CRLF 行尾时会在安装过程中自动转换。

## 在线一键安装

脚本合并并推送到 GitHub 后，可执行：

```sh
curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-alpine-native.sh | sh
```

安装其他仓库或分支：

```sh
curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-alpine-native.sh | \
  PAOPAO_REPO=owner/repository PAOPAO_REF=branch sh
```

在线模式会下载所指定仓库与分支的完整源码。该分支必须包含
`native/paopaodns.openrc`。

## 配置和管理

环境变量配置位于 `/etc/conf.d/paopaodns`。首次安装会创建默认配置，重复安装不会
覆盖该文件。项目的运行时配置、规则和缓存位于 `/data`，重复安装也会保留它们。

```sh
rc-service paopaodns status
rc-service paopaodns restart
tail -f /var/log/paopaodns.log
/usr/sbin/test.sh
```

管理后台默认监听 `8080`，没有内置登录鉴权，不应直接暴露到公网。

## 安装内容

安装器会执行以下操作：

1. 安装 Alpine 构建和运行依赖。
2. 从源码编译带 hiredis 缓存支持的 Unbound。
3. 从源码编译项目使用的定制 MosDNS。
4. 生成 DNSCrypt 配置、GeoIP 和规则数据。
5. 将程序安装到 `/usr/sbin`，保留 `/data`。
6. 创建并启用单一 `paopaodns` OpenRC 服务。
7. 检查 Redis、Unbound、MosDNS、DNSCrypt、DNS 查询和管理后台。

公网劫持检查依赖当前运营商网络。若内置 `test.sh` 仅报告
`[DNS hijack]127.0.0.1`，但安装器的确定性组件检查通过，安装会以警告完成。

## 卸载

默认卸载服务和程序，但保留 `/data`：

```sh
chmod +x uninstall-alpine-native.sh
./uninstall-alpine-native.sh
```

同时删除 `/data`：

```sh
PURGE_DATA=yes ./uninstall-alpine-native.sh
```
