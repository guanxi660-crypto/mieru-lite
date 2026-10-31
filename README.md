# mieru-lite

> 版本：v1.0.0
>
> **⚠️ 测试阶段（BETA）**：功能与配置格式可能随时调整，请勿用于生产环境。

[mieru](https://github.com/enfein/mieru)（mita）服务端一键管理脚本，交互风格与 [mihomo-lite](https://github.com/guanxi660-crypto/mihomo-lite) / singbox-lite 一致。

**不需要域名、不需要 TLS 证书、不需要 Argo 隧道** —— 一个端口就是全部。

## 🚀 一键安装

```bash
(curl -LfsS https://raw.githubusercontent.com/guanxi660-crypto/mieru-lite/main/mieru-lite.sh -o /usr/local/bin/mr || wget -q https://raw.githubusercontent.com/guanxi660-crypto/mieru-lite/main/mieru-lite.sh -O /usr/local/bin/mr) && chmod +x /usr/local/bin/mr && mr
```

脚本拉取不畅时用镜像（把前缀换掉即可）：

```bash
(curl -LfsS https://gh-proxy.com/https://raw.githubusercontent.com/guanxi660-crypto/mieru-lite/main/mieru-lite.sh -o /usr/local/bin/mr || wget -q https://gh-proxy.com/https://raw.githubusercontent.com/guanxi660-crypto/mieru-lite/main/mieru-lite.sh -O /usr/local/bin/mr) && chmod +x /usr/local/bin/mr && mr
```

安装后随时以 root 运行 **`mr`** 进入管理菜单；脚本自身更新用菜单 **【12 更新脚本】**。内核下载失败时可用 `GH_PROXY=镜像前缀 mr` 重试（如 `GH_PROXY=https://ghfast.top/ mr`）。

## 为什么用它

| | mieru / mita | sing-box + Argo | VLESS + TLS |
|---|---|---|---|
| 域名 | **不需要** | 需要（或用临时隧道） | 需要 |
| 证书 | **不需要** | reality 自签或域名 | 需要 |
| 常驻隧道进程 | **没有** | cloudflared | 无 |
| 抗主动探测 | 随机 padding + 重放检测，无 TLS 指纹 | 取决于协议 | 取决于伪装 |
| 监听端口 | 一个（可 TCP+UDP 同号） | 多个 | 一个 |

客户端的 mieru 密钥由「用户名 + 密码 + 系统时间」派生，**服务器时间必须是准的**（脚本不装 NTP，VPS 镜像一般已自带 timesyncd/chrony）。

## 支持

- 协议：mieru 自研 TCP / UDP 加密传输（XChaCha20-Poly1305 + 随机填充 + 重放攻击检测）
- 多用户共用一个端口，每人一条独立链接
- 端口可选：仅 TCP / TCP+UDP 同号；端口默认随机空闲端口，也可手动指定
- MTU 1280-1400、多路复用 LOW / MIDDLE / HIGH / OFF 均可调
- 节点对外可选 **IPv4 / IPv6**（双栈机器询问，单栈机器自动采用）
- 输出：`mierus://` 链接 + mihomo/Clash Meta 配置 + base64 `list.txt`
- 支持 systemd / OpenRC / 无 init 直跑三种模式
- 可选开 BBR（菜单 10）

## 菜单

```
 1. 添加节点（用户，含端口选择）
 2. 查看节点链接（mieru / mihomo）
 3. 修改监听端口 / MTU / 多路复用 / IP 版本
 4. 删除节点
 5. 重启服务
 6. 停止服务
 7. 查看运行状态
 8. 查看实时日志
 9. 查看当前连接与用户流量
10. 开启 BBR
11. 安装 / 更新 mita 内核
12. 更新脚本 (mr)
13. 卸载
```

## 快捷命令（非交互）

```bash
mr install               # 安装 / 更新内核并注册服务
mr setport 25443         # 改监听端口（仅 TCP）
mr setport 25443 udp     # 改监听端口（TCP + UDP 同号）
mr adduser               # 加一个用户（要求端口已设置）
mr links                 # 打印并落盘所有节点链接
mr status                # 一行式状态
mr version               # 脚本版本
```

## 文件位置

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/mita` | 内核 |
| `/usr/local/bin/mr` | 本脚本 |
| `/etc/mieru-lite/server.json` | mita 服务端配置（内核直接读这一份） |
| `/etc/mieru-lite/metadata.json` | 脚本自己的状态（端口、用户、IP 版本） |
| `/etc/mieru-lite/sub/links.txt` | `mierus://` 链接 |
| `/etc/mieru-lite/sub/clash.yaml` | mihomo / Clash Meta 可用配置 |
| `/etc/mieru-lite/sub/list.txt` | 上面两者合并后的 base64 大块 |

## 客户端兼容

- ✅ **mihomo / Clash Meta 系**：Clash Verge Rev、OpenClash、ClashMi、Karing、Shadowrocket、husi + mieru plugin
- ✅ mieru 官方客户端（Windows / macOS / Linux / Android）
- ❌ sing-box 原版不支持 mieru 协议，需要 [enfein/mbox](https://github.com/enfein/mbox) 这个 fork

订阅里用的是 mihomo 的 `type: mieru` 字段（`transport` / `udp` / `multiplexing` / `handshake-mode` 均按官方 wiki 核实过）。

## 常见问题

**端口连不上？** 先确认 VPS 安全组 / 防火墙放行了该端口（UDP 模式还要单独放行 UDP），然后 `mr status` 看代理是否为 `RUNNING`。

**为什么刚设完端口没有监听？** mita 的规则是「没有用户就不启动代理服务」，加完第一个节点后才会开始监听，这是正常行为。

**加了 UDP 之后端口还是不通？** UDP 与 TCP 同号是两个独立监听（`ss -lnu` 可见），两者都要放行。

**想换内核版本？** `MIERU_VERSION=v3.40.0 mr install`；想要最新版用 `MIERU_VERSION=latest mr install`。默认固定 v3.39.0（v3.36.0 之前的版本有多用户并发内存泄漏问题，别往回装）。

**卸载**：菜单 13，内核 / 服务 / 配置 / 运行时全部清掉。

## 关于订阅

本脚本**不开放 HTTP 订阅端口**：节点机上多开一个端口既占资源又容易被扫描器探到。需要在线订阅、节点管理请用 [SubPilot](https://github.com/guanxi660-crypto/SubPilot)；`list.txt` 就是这个项目要吃的 base64 格式。

## 免责声明

仅供学习了解，非盈利目的。使用本程序须遵守部署服务器所在地及所在国家法律法规，作者不对任何不当行为负责。
