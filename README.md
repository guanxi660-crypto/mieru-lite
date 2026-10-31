# mieru-lite

> 版本：v1.2.1
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
- 端口可选：单个端口或一整段端口（客户端随机挑），协议可选仅 TCP / TCP+UDP 同号；单端口默认随机空闲端口，也可手动指定
- MTU 1280-1400、多路复用 LOW / MIDDLE / HIGH / OFF 均可调
- 服务端对外地址可选 **IPv4 / IPv6**（双栈机器询问，单栈机器自动采用）
- 输出：`mierus://` 链接 + mihomo/Clash Meta 配置 + base64 `list.txt`
- 支持 systemd / OpenRC / 无 init 直跑三种模式
- 可选开 BBR（菜单 10）

## 节点和用户是两回事

mieru 的结构和常见协议不一样，一次说清：

| 概念 | 是什么 | 谁来管 | 数量 |
|---|---|---|---|
| **节点** | 服务端的监听面：对外 IP + 端口（或端口段）+ 传输（TCP / UDP） | 菜单 3 / 菜单 13，`mr setport` / `mr hop` | 全局一份 |
| **用户** | 账号：用户名 + 密码，客户端密钥由「用户名 + 密码 + 系统时间」派生 | 菜单 1，`mr adduser` | 任意多个，共用上面那个节点 |

所以在 mieru 里**没有「加节点」这个动作** —— 端口定好之后你加的都是用户。每个用户拿到一条独立的 `mierus://` 链接（同一个 IP:端口，不同账号），加人不用动端口，也不用重启到换配置之外的任何东西。

> 「节点」这个词只在**客户端**才有意义：mihomo 配置文件里每个 `type: mieru` 条目是一个节点，所以 N 个用户 × (TCP/UDP) 会生成 2N 条客户端节点。删用户时客户端那边记得同步删。

## 菜单

```
 1. 添加用户（共用服务端节点，每人一条链接）
 2. 查看用户链接（mieru / mihomo）
 3. 修改监听端口（或端口段）/ MTU / 多路复用 / IP 版本
 4. 删除用户
 5. 重启服务
 6. 停止服务
 7. 查看运行状态
 8. 查看实时日志
 9. 查看当前连接与用户列表
10. 开启 BBR
11. 安装 / 更新 mita 内核
12. 更新脚本 (mr)
13. 端口跳跃（只改端口段，客户端随机挑）
14. 卸载
```

## 快捷命令（非交互）

```bash
mr install               # 安装 / 更新内核并注册服务
mr setport 25443         # 改监听端口（仅 TCP）
mr setport 25443 udp     # 改监听端口（TCP + UDP 同号）
mr setport 30000-30999 udp   # 直接改端口段（等同 mr hop）
mr adduser               # 加一个用户（要求端口已设置）
mr hop 30000-30999       # 端口跳跃：服务端监听整段（仅 TCP）
mr hop 30000-30999 udp   # 端口跳跃：TCP + UDP 同段
mr links                 # 打印并落盘所有用户链接
mr status                # 一行式状态
mr version               # 脚本版本
```

## 端口跳跃

服务端在**整段端口**上监听，客户端每次连接在段内随机挑一个口，用来对抗单端口被针对性阻断/QoS。

```bash
mr hop 30000-30999        # 仅 TCP，1000 个端口
mr hop 30000-30999 udp    # TCP + UDP 同段
```

原理是 mieru 原生能力：服务端 `portBindings` 支持 `portRange`（mita 会给段内每个端口各开一个监听），
客户端 `portBindings` 也支持 `portRange`，选端口在 `pkg/protocol/mux.go` 的 `newUnderlay()` 里——
每条新连接 `mrand.Intn(len(m.endpoints))` 均匀随机。

### 代价（实测，不是估的）

| 端口数 | 内存增量 | fd |
|---|---|---|
| 1（基线） | — | 7 |
| 1000 TCP | ≈ +11 MB | 1006 |
| 3000 TCP | ≈ +42 MB | — |
| 5000 TCP | ≈ +57 MB | — |
| 1000 UDP | ≈ +16 MB | 1006 |

也就是 **约 11-14KB 内存 + 1 个 fd 一个端口**，因此脚本默认上限 **2000 个**（`MAX_HOP_PORTS=2000`）。
要更大就 `MAX_HOP_PORTS=5000 mr hop ...`，但记得同时确认 `LimitNOFILE`（脚本的 systemd 单元已经设成 65535）。

### 四个必须知道的点

1. **防火墙/安全组要把整段放行**，TCP 和 UDP 分别放；漏一个口只表现为偶发连不上。
2. **客户端节点里 `port` 和 `port-range` 只能写一个**。只写 `port-range` 是正确写法，同时写两个 mihomo 会直接报
   `port and port-range cannot be set at the same time`（`adapter/outbound/mieru.go` 的 `validateMieruOption` 里两条卡：
   都空报 `either port or port-range must be set`，都写就报上面那条）。脚本的 metadata 只存一种形态，生成的
   配置也就只有一种，样式切换（单端口 ↔ 端口段）时旧字段会被整体覆盖，不会残留。
3. **`transport` 必填**（`TCP` 或 `UDP`），跟端口形态无关 —— 校验是 `if option.Transport != "TCP" && option.Transport != "UDP"`，
   空值一样报错。TCP+UDP 同号时客户端会被拆成两条节点（`xxx.TCP` / `xxx.UDP`），一个 mihomo 节点只能承载一个 transport。
4. **OpenClash 能用，但要走配置文件**：它的节点编辑界面只收单个数字端口，`port-range` 得通过订阅/自定义
   Clash 配置喂进去。mihomo 自 2024-12-09 支持 mieru 起就带 `port-range` 字段，所以只要内核能跑 `type: mieru`，
   就支持端口跳跃（节点里写 `port-range: "30000-30999"`，不写 `port`）。另外 mihomo 的连接列表里会显示段首端口
   （`NewMieru` 拿 `beginPort` 当展示地址），实际拨号是 mieru 客户端在整段里随机挑，别被那个数字误导。

### 官方示例里的 `2012-2022` 是什么

那是 **文档示例值，不是推荐值也不是保留端口**。mieru 代码里没有任何默认端口 —— `ValidateFullServerConfig` 只要求
`portBindings` 非空，不填直接报 `server port binding is not set`；`2012-2022` 只出现在 `docs/` 的示例 JSON 里
（server-install / client-install / traffic-pattern 三处共用一个片段，旁边还搭了个额外的单端口 `2027`）。

它示范的是思路而不是数字：**监听一小段连续端口、客户端随机挑**，让针对单个端口的阻断/QoS 失效。段多大自己定：

| 方案 | 监听/代价 | 抗封锁表现 |
|---|---|---|
| 单个随机端口（脚本默认） | 1 个 socket、7 fd | 那个口被针对性阻断就整条链路死，得手动换 |
| 官方示例 11 个口（2012-2022 那种） | 11 个 socket、≈150KB、11 fd | 单口被阻断还剩 10 个口可用，安全组也好放行 |
| 大段（脚本默认上限 2000 个） | 约 12KB + 1 fd 每端口，2000 个 ≈ 25MB | 探测方要扫全段才可能封死，代价是资源和防火墙规则 |

一句话：**单口 = 最省资源但最脆弱，小段 = 用极小代价买到抗单点阻断，大段 = 抗整段扫描**。三种都是同一个 mieru
能力的不同参数，不是两套实现。

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

**为什么刚设完端口没有监听？** mita 的规则是「没有用户就不启动代理服务」，加完第一个用户后才会开始监听，这是正常行为。

**加了 UDP 之后端口还是不通？** UDP 与 TCP 同号是两个独立监听（`ss -lnu` 可见），两者都要放行。

**想换内核版本？** `MIERU_VERSION=v3.40.0 mr install`；想要最新版用 `MIERU_VERSION=latest mr install`。默认固定 v3.39.0（v3.36.0 之前的版本有多用户并发内存泄漏问题，别往回装）。

**卸载**：菜单 13，内核 / 服务 / 配置 / 运行时全部清掉。

## 关于订阅

本脚本**不开放 HTTP 订阅端口**：节点机上多开一个端口既占资源又容易被扫描器探到。需要在线订阅、节点管理请用 [SubPilot](https://github.com/guanxi660-crypto/SubPilot)；`list.txt` 就是这个项目要吃的 base64 格式。

## 免责声明

仅供学习了解，非盈利目的。使用本程序须遵守部署服务器所在地及所在国家法律法规，作者不对任何不当行为负责。
