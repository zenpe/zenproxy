# ZenProxy

ZenProxy 是面向个人服务器的中文一键代理运维工具。它只部署三条互补线路：

- VLESS WebSocket：经 Cloudflare Tunnel 的默认主线路
- Hysteria2：Xray UDP 直连备用
- VLESS REALITY：Xray TCP 直连备用

默认采用网站共存端口模型：

| 端口 | 用途 |
|---|---|
| `8443/TCP` | VLESS REALITY |
| `443/UDP` | Hysteria2 |
| `127.0.0.1:17122/TCP` | Cloudflare Tunnel 回源 |

ZenProxy 默认不占用 TCP `80/443`，可继续部署 Nginx、Caddy 或其他 Web 服务。若 Web 服务启用 HTTP/3 并占用 UDP `443`，安装时使用 `--hy2-port 8443`。

## 系统要求

- Debian 12+ 或 Ubuntu 22.04+
- systemd
- amd64 或 arm64
- 一个托管在 Cloudflare 的域名
- 一个准备给 Tunnel 使用的子域名

HY2直接使用VPS公网IP和本机自签证书，节点通过证书SHA-256指纹或内嵌证书固定身份，不需要直连域名、邮箱、Cloudflare API Token或TCP 80。Cloudflare Tunnel在安装时通过浏览器授权创建；安装完成后会删除账户级浏览器授权证书，只保留当前Tunnel的运行凭据。

Cloudflare 会终止客户端外层 TLS，VLESS WebSocket 因此需要信任 Cloudflare。WebSocket 是当前默认方案，优先考虑客户端兼容性和维护稳定性；后续可在客户端生态成熟后迁移到 XHTTP。

## 安装

```bash
chmod +x zenproxy
sudo ./zenproxy
```

远程一键安装（跟随 main 稳定分支）：

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/zenpe/zenproxy/main/install.sh) \
  install --tunnel-domain cf.example.com
```

不带 `install` 参数会进入中文菜单。安装时会打开 Cloudflare 浏览器授权，不需要预先创建 DNS 记录或提供 Tunnel Token。

需要固定历史版本时，可将地址中的 `main` 替换为对应的 Git tag，例如 `v0.4.2`。

也可以先预演：

```bash
./zenproxy install \
  --tunnel-domain cf.example.com \
  --dry-run
```

安装完成后可使用完整命令或简写：

```bash
sudo zenproxy
sudo zp status
```

## 常用命令

```bash
sudo zp status
sudo zp check
sudo zp info
sudo zp info --show-secrets
sudo zp info --clash
sudo zp export
sudo zp restart
sudo zp logs hy2
sudo zp update
sudo zp uninstall
```

`zp status` 展示本地进程和监听状态；`zp check` 会通过公网域名执行 WebSocket 握手，并在本机实际测试 REALITY 和 HY2 协议。云厂商安全组仍需确认放行直连使用的 TCP 和 UDP 端口。

`zp export` 会生成权限为 `0600` 的以下文件：

- `nodes.txt`
- `mihomo.yaml`
- `sing-box-outbounds.json`

ZenProxy 不启动公网订阅服务器。

Mihomo配置使用服务端证书指纹固定，sing-box配置内嵌HY2自签证书，不会关闭TLS证书校验。

导出目录必须是一个尚不存在的新目录，ZenProxy 不会覆盖或修改已有目录内容。

## 文件布局

```text
/etc/zenproxy/                 服务配置和凭据
/var/lib/zenproxy/             安装状态
/usr/local/lib/zenproxy/       固定版本核心程序
/usr/local/sbin/zenproxy       主命令
/usr/local/sbin/zp             简写命令
```

ZenProxy只有两个常驻服务：

- `zenproxy-xray`
- `zenproxy-cloudflared`

Xray在同一个经过启动前配置校验的进程中承载HY2、VLESS REALITY和VLESS WebSocket三个入站，减少二进制、服务和更新链路。Xray重启时三条代理入口会同时短暂中断，systemd会自动拉起。

## IP 与 IPv6

安装器会分别保存公网IPv4和IPv6。双栈VPS会为HY2和REALITY各输出IPv4、IPv6节点；纯单栈VPS只输出可用地址族。IPv6分享链接会自动添加方括号，Xray在双栈系统上同时监听IPv4和IPv6。

Tunnel域名由 `cloudflared tunnel route dns` 自动创建。

每台独立安装的VPS必须使用不同的Tunnel子域名，例如`cf-us.example.com`和`cf-jp.example.com`。安装器默认拒绝覆盖已有DNS记录；只有确认需要接管旧域名时才使用`--force-domain`。

公网IP默认自动检测并严格校验。开启WARP、VPN或特殊NAT时，可以手动指定直连地址：

```bash
sudo ./zenproxy install \
  --tunnel-domain cf.example.com \
  --direct-ipv4 203.0.113.10 \
  --direct-ipv6 2001:db8::10
```

## 更新与卸载

核心版本固定在 ZenProxy 发布版本中。更新从官方 GitHub Release 下载，并强制校验 GitHub 提供的 SHA256 digest。下载后会先验证当前配置；文件替换、服务重启或健康检查任一步失败，两个核心程序都会恢复到更新前版本。联合更新管理器时，会直接采用新管理器声明的核心版本，一次更新即可完成版本切换。

在正式发布渠道接入前，可使用经过独立渠道确认的 SHA256 摘要更新 ZenProxy 管理器本身：

```bash
EXPECTED_SHA256='从发布页独立核对的64位SHA256摘要'
sudo zp update \
  --manager-file ./zenproxy-new \
  --manager-sha256 "$EXPECTED_SHA256"
```

卸载会删除本机ZenProxy服务、配置、节点密钥、状态、二进制和专用用户，不清空防火墙、NAT、crontab或系统DNS。Cloudflare Tunnel默认保留；明确使用以下命令才会删除Tunnel：

```bash
sudo zp uninstall --delete-tunnel
```

使用`--delete-tunnel`时会临时要求一次Cloudflare浏览器授权，授权材料用完即删。Cloudflare DNS记录仍需在控制台确认和清理。
