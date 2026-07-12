# PaoPaoDNS Alpine 原生部署

当前原生部署仅支持 Alpine Linux，不需要 Docker。

## 本地源码安装

在仓库根目录以 root 用户执行：

```sh
chmod +x install-alpine-native.sh
./install-alpine-native.sh
```

安装器会优先使用当前仓库的 `src/`，包括尚未提交的本地修改。

## 在线安装

```sh
curl -fsSL https://raw.githubusercontent.com/baoeig/PaoPaoDNS/main/install-alpine-native.sh | sh
```

## 卸载

默认保留 `/data`：

```sh
chmod +x uninstall-alpine-native.sh
./uninstall-alpine-native.sh
```

完整说明、系统要求和自定义分支安装方式见 [DEPLOY-ALPINE-NATIVE.md](DEPLOY-ALPINE-NATIVE.md)。
