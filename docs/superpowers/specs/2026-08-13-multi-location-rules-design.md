# 多地点 OpenClash 规则库改造设计

**日期**：2026-08-13（2026-08-14 更新阶段 2/3 验证结果）
**仓库**：https://github.com/maelitoandres/rules （public）
**状态**：阶段 1–3 已完成并验证，待清理 gist 后进入阶段 4 切换

---

## 1. 背景与目标

规则库 fork 自 `Aethersailor/Custom_OpenClash_Rules`，其结构假设「用户在中国境内」这一单一场景。实际场景为三个固定办公地点，各有一台常驻 iStoreOS 路由器：🇨🇳 中国、🇺🇸 美国、🇨🇴 哥伦比亚。

**目标**：一套规则库同时服务三地，域名清单不重复维护，地点差异收敛到配置层。

---

## 2. 需求模型

需求分为两类，**不能用同一套逻辑表达**：

- **A 类 · 地理分流**——「我人在哪，这个服务从哪出去」，策略是所在地与出口的函数。
- **B 类 · 运营绑定**——「该平台流量必须始终从固定住宅 IP 出去」，与所在地无关。

同一域名会同时命中两类（抖音按 A 类应在中国直连，按 B 类必须走 CO 住宅 IP），**B 类优先**。subconverter 按 ini 中 `ruleset=` 顺序生成规则，先匹配先生效，故 B 类必须排在所有 A 类之前。

### 三条出口，解决三个不同问题

| 出口 | 解决的问题 | 服务对象 |
|---|---|---|
| 🇨🇴 BD 住宅 IP `.55` | **身份**——住宅 IP 信誉，平台风控看 IP 稳不稳 | 抖音、微博、小红书、微信视频号、TikTok 运营 |
| 🇨🇴 BD 住宅 IP `.116` | **准入**——确保不是美国 IP | 加密货币平台 + 哥伦比亚出口的日常需求 |
| 🇺🇸 JMS 洛杉矶 | **常规**——美国出口 + socks5 桥接跳板 | Schwab、长桥、国际服务 |

社媒与其余 CO 需求**必须用不同 IP**：`.55` 严格专用于运营（IP 信誉最敏感），`.116` 承担加密货币与日常杂项。交易所风控或日常流量都不应波及运营账号。这是唯一需要隔离的边界——抖音/微博/小红书之间无需再分。

---

## 3. 目录结构

```
rules/
├── rule/
│   ├── CO/      🇨🇴 哥伦比亚出口
│   │   ├── CO_social_rule.list   → 🇨🇴 CO社媒运营   59 条
│   │   └── CO_crypto_rule.list   → 🇨🇴 CO冲浪快线   17 条
│   ├── US/      🇺🇸 美国出口
│   │   └── US_rule.list          → 🇺🇸 快线      4 条
│   ├── CN/      🇨🇳 中国出口
│   │   └── CN_rule.list          → 🇨🇳 中国出口     27 条
│   ├── GLOBAL/  🚀 通用代理
│   │   └── Global_rule.list      → 🇺🇸 冲浪快线     17 条
│   └── README.md                 语义约定
├── cfg/
│   ├── cn.ini · us.ini · co.ini
│   └── Custom_Clash.ini          （旧模板，切换后删除）
├── docs/  doc/  game_rule/
```

**核心约定**：目录名表示「流量从哪个国家出去」，**不是「我人在哪个国家」**。若被理解成使用地点，同一域名需在多目录重复（N 服务 × 3 地 = 3N 份）。旧的 `CO_ISP_rule.list` 正是反例——文件名是 CO，内容却是抖音域名。

全库 124 条，已校验无重复。

---

## 4. 策略组设计

三份 ini 的策略组**完全相同**，差异仅在 `ruleset` 映射：

```
custom_proxy_group=🇨🇴 CO社媒运营`select`(🇨🇴)
custom_proxy_group=🇨🇴 CO冲浪快线`select`(🇨🇴)
custom_proxy_group=🇺🇸 快线`select`(🇺🇸)
custom_proxy_group=🇺🇸 冲浪快线`select`(🇺🇸)
custom_proxy_group=🇨🇳 中国出口`select`[]DIRECT
custom_proxy_group=📢 谷歌FCM`select`[]DIRECT`[]🇺🇸 冲浪快线
custom_proxy_group=🎯 全球直连`select`[]DIRECT
custom_proxy_group=🐟 漏网之鱼`select`[]🇺🇸 冲浪快线`[]DIRECT
```

### 用正则而非写死节点名

`(🇨🇴)` 会把**所有**带该国旗的节点展开进组，因此：

- 两个 CO 业务组各自持有独立选择状态 → **隔离成立**；
- 新增任何 `🇨🇴 xxx` 节点自动出现在相关组中，ini 无需改动。

**命名规范**：`🇨🇴 {用途}` / `🇺🇸 {用途}`。

> ⚠️ 不要引入「国家级中间组」（如 `🇨🇴 哥伦比亚` 再被业务组引用）。Clash 的 `select` 组任一时刻只能选中一个节点，多个业务组指向同一中间组即等于共用 IP，隔离静默失效。`load-balance` 更不可用——它会让运营流量在 IP 间跳变。

### 四条铁律

1. **一律 `select`，禁止 `url-test`**——节点固定；且运营账号最怕 IP 自动切换。
2. **CO 组不含 `DIRECT`**——误选会让运营流量暴露本地真实 IP。
3. **🇺🇸 快线不含 `DIRECT`**——它被 socks5 的 `dialer-proxy` 引用，选中 DIRECT 会让桥接**静默退化为明文直连**。
4. **漏网之鱼绝不含 🇨🇴 节点**——未匹配流量（广告追踪、软件更新、app 心跳）会迅速污染运营 IP 信誉。

### 三地映射

| ruleset | cn.ini | us.ini | co.ini |
|---|---|---|---|
| `CO_social` / `CO_crypto` | CO 住宅 IP | CO 住宅 IP | CO 住宅 IP |
| `US_rule` | 🇺🇸 快线 | **DIRECT** | 🇺🇸 快线 |
| `CN_rule` | **DIRECT** | 🇨🇳 中国出口 ⚠️ | 🇨🇳 中国出口 ⚠️ |
| 国际服务 | 🇺🇸 冲浪快线 | **DIRECT** | **DIRECT** |
| 漏网之鱼默认 | 冲浪快线 | DIRECT | DIRECT |

⚠️ 无中国落地节点，该组暂为 DIRECT，见 §8.1。

---

## 5. 节点资源

### JMS（Just My Socks LA 1000）

官方说明：**5 个 IP 全部在洛杉矶**，仅回程路由不同。原 gist 中「迈阿密/芝加哥/日本/荷兰」的命名是错误的。

| 节点 | 协议 | 实测 RTT | 丢包 | JMS 路由 | 处置 |
|---|---|---|---|---|---|
| c55s4 | VLESS Reality | **77.4 ms** | 0% | 大阪 Softbank POP | → `🇺🇸 日本中转` |
| c55s3 | VLESS Reality | 164.6 ms | 0% | **CN2 GIA** | → `🇺🇸 CN2GIA` |
| c55s2 | SS | 171.3 ms | 0% | 三网直连 | → `🇺🇸 直连备用` |
| c55s1 | SS | 168.3 ms | **12%** | 三网直连 | **排除** |
| c55s5 | VLESS Reality | 192.2 ms | 0% | 荷兰 POP | **排除**（不可用） |
| c55s801 | VLESS Reality | 167.0 ms | **12%** | — | **排除**（10 倍率） |

**分组按用途而非快慢**：c55s4 赢在入口延迟（日常冲浪），c55s3 赢在路径直达（BD 网关在加州，走 CN2 GIA 是直线；c55s4 需绕日本折回美国）。

### Bright Data（$35/月固定，非按量）

| | `<BD-OLD-01>` | `<BD-OLD-02>` |
|---|---|---|
| 命名 | `🇨🇴 社媒` | `🇨🇴 加密` |
| 城市 / ISP | Bogotá / WS Telecom Inc | 同左 |
| org | **（空）** | （空） |
| proxy / hosting 标记 | **false / false** | false / false |

### 已退役

- **LightNode VPS**（`net.fishcargo.co`，$17.7/月）——退租。org 字段为 `Lightnode-CO` 暴露云服务商身份，且到中国方向 1536 ms 几乎不可用。加密货币改走 BD `.116`（仅需非美国 IP，零边际成本）。

**月支出**：$62.58 → **$44.88**（年省约 $212）。

---

## 6. 架构改造：本地 subconverter

### 动机

1. **凭证外泄**——全部节点凭证随每次订阅更新完整发送给 `api.dler.io`；
2. **单点故障**——三地共同依赖一个第三方服务；
3. **静默丢字段**——见下。

### ⚠️ 关键：必须使用 fork 版镜像

实测对比（2026-08-14）：

| 镜像 | 版本 | VLESS Reality | `dialer-proxy` |
|---|---|---|---|
| `tindy2013/subconverter`（官方） | v0.9.0 | ❌ **4 个节点全部丢弃** | — |
| **`asdlokj1qpi23/subconverter`** | **v0.9.9** | ✅ 完整保留 | ✅ 完整保留 |
| `api.dler.io`（现网） | 未知 | 未测 | ❌ **静默丢弃** |

官方版转换后只剩 2 个 SS 节点，且**面板上不会有任何报错**。若未经阶段 3 验证直接切换，结果是 4 个 VLESS 节点凭空消失 + 桥接完全失效。

### 部署

```bash
docker run -d --name subconverter --restart always \
  --dns 223.5.5.5 --dns 119.29.29.29 \
  -p 127.0.0.1:25500:25500 asdlokj1qpi23/subconverter:latest
```

**`--dns` 参数不可省略**——Docker 默认网桥不继承宿主机 DNS，缺失会导致 `Could not resolve host`，转换返回 `No nodes were found!`。

路由器环境：iStoreOS 24.10.8 / x86_64 / 4 核 / 16 GB 内存 / Docker 27.3.1。镜像 20.7 MB。

### 订阅源合并

OpenClash 订阅地址栏填入（`|` 分隔，三地相同）：

```
<JMS Mihomo/Clash.Meta YAML 订阅>|<仅含 BD 两节点的 gist raw>
```

- JMS 节点由官方订阅提供，参数正确且自动跟进；
- BD 不提供 Clash 订阅，只能手写，但仅 2 个节点，出错面小。

**订阅类型必须选 Mihomo / Clash.Meta YAML**——Standard subscription 返回 base64 URI 列表，需多一层解析，Reality 参数有丢失风险。

---

## 7. 安全约束

### 7.1 socks5 必须走加密桥接（强制）

BD 节点使用 socks5，该协议**无加密**，且用户名密码认证为**明文传输**（RFC 1929）。从中国直连 `brd.superproxy.io:22228` 会导致 socks5 握手特征被 GFW 识别、**BD 凭证在链路上明文暴露**。

gist 中已配 `dialer-proxy`，但被 api.dler.io 静默丢弃（已在实际运行配置中复验），**桥接从未生效**。

**桥接只有中国办公室需要**——美国/哥伦比亚无 GFW，直连即可。但 `dialer-proxy` 是节点级字段、三地共用 gist，故三地统一桥接；美国办公室经 JMS 洛杉矶再到 BD 加州网关，同在美国境内，代价极小。

### 7.2 桥接失败必须断开，禁止降级（强制）

见 §4 铁律三。宁可出口不通，也不能在故障时暴露凭证。

### 7.3 桥接的流量成本

TikTok 运营在**中国办事处**进行，故运营流量全部经 JMS 桥接，计入其 1000 GB 月配额。按刷 TikTok 约 1–2 GB/小时估算，日均 2 小时即 60–120 GB/月。

当前实测基线：Clash 累计流量 676 MB / 2h06m ≈ 7.7 GB/天（含直连），距天花板尚远。**决策：先用 1000 GB 观察，不足再扩容。**

扩容时**加购第二个 LA 1000 套餐（~$19.76）优于升级到 5000（~$29.88）**——便宜约 $10，且第二个实例提供独立服务器，顺带解决桥接单点。

### 7.4 已发现的 IP 保护漏洞（切换时一并修复）

| # | 问题 | 后果 |
|---|---|---|
| 1 | `external-controller: 0.0.0.0:9090`，secret 为 `123456` | **局域网任何设备可完全控制 Clash**——包括把漏网之鱼切到运营 IP。此项让其余保护全部失效 |
| 2 | 「🐟 漏网之鱼」组含哥伦比亚节点 | 误选即污染运营 IP |
| 3 | `fake-ip-filter` 含 `"+.qq.com"` | 微信视频号走中国 DNS 解析到中国 CDN，再从哥伦比亚 IP 访问，形成**地理矛盾**风控信号 |

抖音/小红书/微博/TikTok **不在** filter 中，走 fake-ip，DNS 由出口端解析，IP 与 DNS 一致 ✅。

**修复**：#1 改回 `127.0.0.1:9090` 并换强密码；#2 新 ini 已移除；#3 需从 fake-ip-filter 中排除视频号域名。

### 7.5 凭证轮换（切换前完成）

secret gist 的 raw URL **无需认证即可读取全文**（已实测），且该 URL 每次订阅更新都发送给 `api.dler.io`。泄露内容含 BD customer ID/zone/出口 IP、JMS 凭证、fishcargo uuid。

**处置**：① 重置 BD zone 密码；② JMS 后台重置 UUID/port；③ LightNode 退租后 uuid 自然失效。

> JMS 改 UUID/port 后**必须立即手动更新订阅**——OpenClash 定时任务为每天 10:00（实测 `auto_update_time='10'`），否则节点会失效至次日。

---

## 8. 已知缺口

### 8.1 无中国落地节点

在美国/哥伦比亚办公室时，`CN_rule` 层没有回国出口。结构已预留 `🇨🇳 中国出口` 组，补入回国专线后在 ini 填一行即可生效。不阻塞其余部分。

### 8.2 桥接单点

JMS 仅洛杉矶一组节点。缓解见 §4 铁律三 + §7.3 加购方案。

### 8.3 旧仓库删除时机

`maelitoandres/Custom_OpenClash_Rules` **暂不可删**——当前 `custom_template_url` 指向该仓库的 `cfg/Custom_Clash.ini`，删除将导致整份配置生成失败。须在阶段 4 验证通过后再删。

---

## 9. 实施进度

| 阶段 | 内容 | 状态 |
|---|---|---|
| **1** | 目录重构、规则迁移、三份 ini | ✅ 完成（124 条校验无重复） |
| **2** | 路由器部署本地 subconverter | ✅ 完成（fork 版 v0.9.9 运行中） |
| **3** | 离线生成验证 | ✅ 通过（见下） |
| **4** | OpenClash 切换订阅 + 模板 | ⏸ 待 gist 清理后执行 |

**阶段 3 验证结果**（`cn.ini` + JMS 订阅 + gist，HTTP 200 / 2.37 s）：

```
策略组         8 个        ✅ 符合设计
节点重命名     已生效      ✅ c55s2 → 🇺🇸 直连备用
exclude        已生效      ✅ c55s1/s5/s801 已排除
VLESS Reality  保留        ✅
dialer-proxy   保留        ✅
规则总数       17257 条
```

**待办**：gist 需清理为仅含 BD 两节点（旧 JMS 节点名带 `🇺🇸`，会被正则误收进美国组）。目标内容：

```yaml
proxies:
  - {name: 🇨🇴 社媒, server: brd.superproxy.io, port: 22228, type: socks5,
     username: <...-ip-<BD-OLD-01>>, password: <...>, udp: true,
     dialer-proxy: "🇺🇸 快线"}
  - {name: 🇨🇴 加密, server: brd.superproxy.io, port: 22228, type: socks5,
     username: <...-ip-<BD-OLD-02>>, password: <...>, udp: true,
     dialer-proxy: "🇺🇸 快线"}
```

### 切换顺序（阶段 4）

1. 修复 §7.4 的 external-controller 与 fake-ip-filter；
2. OpenClash 订阅地址改为 `<JMS订阅>|<新 gist>`；
3. 转换地址改为 `http://127.0.0.1:25500/sub`；
4. 模板地址改为 `.../cfg/cn.ini`；
5. 更新订阅并验证；
6. 端到端实测确定桥接走 CN2GIA 还是日本中转；
7. LightNode 退租；
8. 另两地部署；
9. 删除旧仓库。

---

## 10. 不做的事（YAGNI）

- 不扩容路由器磁盘分区（NVMe 119 GB 仅划 1.9 GB，与本设计无关）。
- 不迁移 `doc/` 下的上游教程。
- 不引入 Tailscale / Cloudflare Tunnel——本地部署后无跨地点组网需求。
- 不为「设备跟人移动」做可切换配置——三地均为固定路由器。
- 不购买额外地区节点——加密货币仅需非美国 IP，BD 已满足。

---

## 附录 · 调研中被实测推翻的判断

| 初始判断 | 实测结果 |
|---|---|
| 私有仓库无法被 subconverter 读取 | **可读**，URL 内嵌 token 即可。改公开的真实理由是 token 会暴露给第三方转换服务 |
| 保持私有会堵死 CDN 加速 | 当前架构下 CDN 本就不生效（provider 走 dler.io），该论据不成立 |
| BD 按流量计费，url-test 探测在烧钱 | **固定 $35/月**，探测不产生额外成本。改 `select` 的理由仅为语义正确 |
| BD 的 IP 未必被认作住宅 ISP（据 whois 推断） | **实测 proxy/hosting 均为 false**。whois 反映所有权链条，风控看 ASN 用途分类，两者不等价 |
| LightNode VPS 线路质量根本不行 | **国际方向优秀**（Binance 296 ms 全场最佳），仅中国方向极差（1536 ms） |
| fishcargo uuid 泄露可导致内网横向渗透 | 该节点托管于 LightNode 云端，**不在办公室网络内** |
| JMS 4 个节点连不上是套餐不含 | **配置写错**：协议应为 vless 而非 vmess、端口应为 443 而非 19863、`servername` 是占位符 `example.com` |
| JMS 节点分布在迈阿密/芝加哥/日本/荷兰 | **5 个 IP 全在洛杉矶**，仅回程路由不同 |
