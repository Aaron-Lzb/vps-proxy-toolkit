# VPN 维护与 Xray

Hysteria2 使用 UDP 443；独立安装的 Xray VLESS + REALITY 使用 TCP 443。TCP 与 UDP 是不同传输协议，因此可以共存。本项目安装 Hysteria2，不提供 Xray 安装；Xray 安装、凭据与客户端配置仍由部署者负责。

巡检支持 `hysteria-server.service`、`/usr/local/bin/hysteria`、`/etc/hysteria/config.yaml`，以及 `xray.service`、`/usr/local/bin/xray`、`/usr/local/etc/xray/config.json`。自定义 Xray 路径需要适配；标准文件验证通过不代表自定义服务正在使用它。REALITY 不使用 Hysteria2 的 Let's Encrypt 证书。

## 仅升级维护工具

在可信的仓库副本中执行，无需重新运行服务端安装器：

```bash
git pull --ff-only origin main
sudo install -m 0755 scripts/check-status.sh /usr/local/bin/hysteria-check
sudo install -m 0755 scripts/update-tools.sh /usr/local/bin/hysteria-update
sudo ln -sfn hysteria-check /usr/local/bin/vpn-check
sudo vpn-check
```

完成这次升级后，`sudo hysteria-update` 更新共享脚本并确保别名存在。它跟随 `main`，不是最新 Release。之后可以删除仓库副本。`hysteria-check [PUBLIC_IP]` 和仓库调用继续兼容；自动检测失败时使用 `vpn-check <PUBLIC_IP>`。

所有诊断均只读，包括 Xray `run -test`。不输出配置或日志原文。日志摘要统计最近 24 小时内可用的错误级别记录；历史保留不足不能证明期间没有错误。CPU 负载和运行时间仅供参考；内存达到 90% 警告，磁盘达到 80% 警告、90% 严重。权限不足或检查不可用会警告，不会误报通过。退出码 0 表示没有警告或严重问题，1 表示需要关注。颜色遵循 TTY、`NO_COLOR` 和 `TERM=dumb` 规则。

凭据须保留在 Git 之外。VLESS + REALITY 使用客户端 UUID、服务端私钥以及匹配的客户端公钥、服务器名称和 short ID。共享说明只能使用 `YOUR_UUID`、`YOUR_REALITY_PRIVATE_KEY`、`YOUR_REALITY_PUBLIC_KEY`、`YOUR_SERVER_NAME`、`YOUR_SHORT_ID` 等占位符，切勿复制真实配置到仓库。
