# 多地点 OpenClash 规则库改造设计

**日期**：2026-08-13
**仓库**：https://github.com/maelitoandres/rules （public）
**状态**：设计已确认，待实施

---

## 1. 背景与目标

现有规则库 fork 自 `Aethersailor/Custom_OpenClash_Rules`，其结构假设「用户在中国境内」这一单一场景。实际场景为三个固定办公地点，各有一台常驻 iStoreOS 路由器：🇨🇳 中国、🇺🇸 美国、🇨🇴 哥伦比亚。

**目标**：一套规则库同时服务三地，域名清单不重复维护，地点差异收敛到配置层。

---

## 2. 现状调研结论

### 2.1 链路架构

```
OpenClash → api.dler.io/sub ──拉取──→ cfg/Custom_Clash.ini（模板）
                             ──生成──→ 统一节点管理.yaml
                                         └─ 55 个 rule-provider
                                            全部形如 api.dler.io/getruleset?type=6&url=<base64>
```

- 路由器**从不直接访问 GitHub 拉规则**，全部经 `api.dler.io` 中转。
- 因此 `github_address_mod='https://testingcf.jsdelivr.net/'` 对这 55 个 provider **完全不生效**。
- `api.dler.io` 是三地共同的单点故障。

### 2.2 链路实测（自路由器，2026-08-13）

| 链路 | 结果 |
|---|---|
| `api.dler.io/getruleset` | HTTP 200，1.11 s |
| `testingcf.jsdelivr.net`（CDN） | HTTP 200，1.19 s |
| `raw.githubusercontent.com` | HTTP 200，3.36 s |

CDN 比直连快约 3 倍，但需先摆脱 dler.io 中转才能兑现。

### 2.3 规则文件使用状况

9 个 `.list` 中仅 4 个被 ini 以自有 URL 引用，其中 2 个因改名已断，**当前实际生效仅 2 个**：

| 文件 | 条数 | 状态 |
|---|---|---|
| `trabajo.list` | 45 | ✅ 在用（`:67` → 📺 国内媒体） |
| `Coin.list` | 17 | ✅ 在用（`:34` → 🪙 加密货币） |
| `USA_rule.list` | 1 | ⚠️ 已断：ini 仍引用旧名 `usa.list` |
| `CO_ISP_rule.list` | 62 | ⚠️ 已断：ini 仍引用旧名 `colombia.list` |
| `ChinaDomain.list` / `Custom_Direct.list` / `Custom_Proxy.list` / `Ozon.list` / `Steam_CDN.list` | — | ❌ 死文件：ini 引用的是上游 URL，本仓库副本从未被读取 |

### 2.4 节点资源与实测延迟

通过 Clash API 实测（`/proxies/{name}/delay`）：

| 节点 | 基准(gstatic) | 抖音 | Binance | 判定 |
|---|---|---|---|---|
| 🇨🇴 哥伦比亚-家里（BD ISP） | 350 ms | 896 ms | 611 ms | ✅ 可用 |
| 🇨🇴 哥伦比亚-公司（BD ISP） | 600 ms | **568 ms** | 596 ms | ✅ 中国方向最优 |
| 🇨🇴 FISH-哥伦比亚（LightNode VPS） | 260 ms | **1536 ms** | **296 ms** | ⚠️ 国际优、中国方向极差 |
| 🇺🇸 洛杉矶（JMS） | 169 ms | 691 ms | 181 ms | ✅ 可用 |
| 🇺🇸 迈阿密 | — | — | — | ❌ Clash 中不存在 |
| 🇺🇸 芝加哥 / 🇯🇵 日本 / 🇳🇱 荷兰 | — | — | — | ❌ 连接失败 |

**订阅套餐为 Just My Socks LA 1000，仅含洛杉矶节点**，故上述 4 个节点为旧套餐残留的死配置。

**出口 IP 归属实测：**

| | BD ISP (`185.177.78.55/116`) | LightNode VPS (`149.104.75.106`) |
|---|---|---|
| 城市 | Bogotá | San Vicente del Caguán（偏远小镇） |
| ISP | WS Telecom Inc | Bedge CO Limited |
| org | （空） | **`Lightnode-CO`**（暴露云服务商） |
| ASN | AS213541 WS Telecom | AS154177 LIGHT NODE LIMITED |
| proxy / hosting | false / false | false / false |

**硬缺口：无中国落地节点。**

---

## 3. 设计模型

需求分为两类，**不能用同一套逻辑表达**：

- **A 类 · 地理分流**——「我人在哪，这个服务从哪出去」，策略是所在地与出口的函数。
- **B 类 · 运营绑定**——「该平台流量必须始终从固定住宅 IP 出去」，与所在地无关。

同一域名会同时命中两类（抖音按 A 类应在中国直连，按 B 类必须走 CO 住宅 IP），**B 类优先**。subconverter 按 ini 中 `ruleset=` 顺序生成规则，先匹配先生效，故 B 类必须排在所有 A 类之前。

### 三种出口，解决三个不同问题

| 出口 | 解决的问题 | 服务对象 | 依据 |
|---|---|---|---|
| 🇨🇴 BD 住宅-家里 | **身份**——住宅 IP 信誉 | TikTok CO 运营、社媒 | org 为空、Bogotá、中国方向 568 ms |
| 🇨🇴 BD 住宅-公司 | **准入**——确保非美国 IP | 加密货币平台 | 非美国即满足；零边际成本 |
| 🇺🇸 JMS 洛杉矶 | **常规**——美国出口 + 桥接跳板 | Schwab、美股、socks5 桥接 | CN2 GIA，169 ms |

---

## 4. 目录结构

```
rules/
├── rule/
│   ├── CO/                        🇨🇴 哥伦比亚出口
│   │   ├── CO_ISP_social.list       → CO住宅-家里（抖音·微博·小红书·视频号·TikTok运营）
│   │   └── CO_ISP_crypto.list       → CO住宅-公司（加密货币平台）
│   ├── US/                        🇺🇸 美国出口
│   │   └── US_rule.list             → Schwab、美股
│   ├── CN/                        🇨🇳 中国出口
│   │   └── CN_rule.list             → 国内媒体、中国船公司、企查查
│   ├── GLOBAL/                    🚀 通用代理
│   │   └── Global_rule.list         → Google、AI、Figma、国际船公司
│   └── README.md                  ★ 语义约定，见 §4.1
├── cfg/
│   ├── cn.ini   中国办公室路由器
│   ├── us.ini   美国办公室路由器
│   └── co.ini   哥伦比亚办公室路由器
├── docs/                          本设计文档
├── doc/                           （上游遗留教程，保留原样）
└── game_rule/                     （上游遗留，未引用，保留）
```

### 4.1 目录语义约定（必须写入 `rule/README.md`）

> **目录名表示「流量从哪个国家出去」，不是「我人在哪个国家」。**

这是整个结构的地基。若被误解为使用地点，则同一域名需在多个目录重复（N 服务 × 3 地 = 3N 份），改一处要追三个文件，必然遗漏。

现有 `CO_ISP_rule.list` 正是反例：文件名是 CO，内容却是抖音域名（中国服务），因为它混入了「我人在哪」这一维度。

**文件命名**：`{出口国}_{出口类型}_{用途}.list`，每个文件一一对应一个策略组。

### 4.2 策略映射矩阵

| 规则文件 → 策略组 | 🇨🇳 中国办公室 | 🇺🇸 美国办公室 | 🇨🇴 哥伦比亚办公室 |
|---|---|---|---|
| `CO_ISP_social` → 🇨🇴 CO住宅-家里 | 哥伦比亚-家里 | 哥伦比亚-家里 | 哥伦比亚-家里 |
| `CO_ISP_crypto` → 🇨🇴 CO住宅-公司 | 哥伦比亚-公司 | 哥伦比亚-公司 | 哥伦比亚-公司 |
| `US_rule` → 🇺🇸 美国出口 | 洛杉矶 | **DIRECT** | 洛杉矶 |
| `CN_rule` → 🇨🇳 中国出口 | **DIRECT** | 回国节点 ⚠️ | 回国节点 ⚠️ |
| `Global_rule` → 🚀 通用代理 | 洛杉矶 | **DIRECT** | **DIRECT** |

运营类（前两行）三地一致，因为它们与所在地无关。⚠️ 见 §8.1。

**维护流程**：新增域名时只问「它该从哪出去」，放入对应文件，三地自动生效，ini 无需改动。

---

## 5. 文件迁移映射

### 5.1 `trabajo.list` 拆分（当前最大问题）

该文件挂在「📺 国内媒体」组，而该组仅有 `DIRECT` 选项（`Custom_Clash.ini:99`），导致 45 条域名**全部强制直连**，其中混有大量国际站点。在中国办公室，`figma.com` 强制直连基本不可用，各船公司官网直连亦极慢。

**→ `CN/CN_rule.list`（中国出口／在华直连）：**

```
hgj.com, nextsls.com, healthoo.com, qishui.com, logwingbooking.com, weiyun001.com,
zimchina.com, matson.com.cn, msccargo.cn, coscoshipping.com, sinotrans.com,
sino56.com, pingpongx.com, quickconnect.cn, vcaveman.com, qcc.com, hgmsds.com,
gov.cn, hllep.com, accountboy.com, snssdk.com,
51touxiang.com, volceapplog.com, volces.com,
mihoyo.com, miyoushe.com, kunluncan.com, tcsdzz.com
```

**→ `GLOBAL/Global_rule.list`：**

```
zim.com, matson.com, maersk.com, cma-cgm.com, hapag-lloyd.com, one-line.com,
evergreen-marine.com, hmm21.com, yangming.com, wanhai.com, pilship.com, oocl.com,
fedex.com, dhl.com, figma.com, coreldraw.com, cloudflare.com
```

> **待确认**：`hgj.com`、`nextsls.com`、`healthoo.com`、`logwingbooking.com`、`hllep.com`、`accountboy.com`、`kunluncan.com`、`tcsdzz.com` 归属无法从域名判定，实施时需逐个确认。

### 5.2 其余文件

| 现文件 | 去向 |
|---|---|
| `CO_ISP_rule.list` | `CO/CO_ISP_social.list` |
| `Coin.list` | `CO/CO_ISP_crypto.list` |
| `USA_rule.list` | `US/US_rule.list` |
| `ChinaDomain.list` / `Custom_Direct.list` / `Custom_Proxy.list` / `Ozon.list` / `Steam_CDN.list` | 删除（死文件） |
| `game_rule/` | 保留 |

### 5.3 新增

- **微信视频号规则** → `CO/CO_ISP_social.list`（当前 ini 完全缺失）
- TikTok CO 运营域名 → `CO/CO_ISP_social.list`

---

## 6. 架构改造：本地 subconverter

### 动机

1. **凭证外泄**：全部节点凭证随每次订阅更新完整发送给 `api.dler.io`。
2. **单点故障**：三地共同依赖一个第三方服务。
3. **CDN 失效**：经 dler.io 中转导致 jsDelivr 加速无法生效。
4. **静默丢字段**：`dialer-proxy` 被吞掉（见 §7.1）。

### 方案对比

| 方案 | 需公网 IP | 单点故障 | 凭证暴露给 |
|---|---|---|---|
| 现状 api.dler.io | 否 | 有 | 第三方 |
| 群晖 NAS 集中部署 | **是**（或穿透组网） | 有 | 不出自有网络 |
| **每路由器本地部署** | 否 | **无** | **不出本机** |

**采用每路由器本地部署。**

路由器环境：iStoreOS 24.10.8 / x86_64 / 4 核 / 16 GB 内存（空闲 15.2 GB）/ Docker 27.3.1 已装 / Docker 根目录可用 1.8 GB。

```bash
docker run -d --name subconverter --restart always \
  -p 127.0.0.1:25500:25500 tindy2013/subconverter:latest
```

OpenClash 转换地址由 `https://api.dler.io/sub` 改为 `http://127.0.0.1:25500/sub`。

> NVMe 总容量 119.2 GB，分区仅划 1.9 GB，约 117 GB 未分配。subconverter 无需扩容即可运行；扩容不属本设计范围。

---

## 7. 安全约束

### 7.1 socks5 必须走加密桥接（强制）

BD 节点使用 socks5，该协议**无加密**，且其用户名密码认证为**明文传输**（RFC 1929）。从中国直连 `brd.superproxy.io:22228` 会导致：

- socks5 握手特征明显，GFW 可识别为代理流量；
- **BD 凭证在链路上明文暴露**；
- 非标准端口 `22228` 与知名代理域名均为显著特征。

gist 中已配 `dialer-proxy: "美国-自动"`，但 **api.dler.io 转换时静默丢弃该字段**，实际运行配置中不存在，故桥接从未生效——当前为明文直连。

**验证方法**：部署本地 subconverter 后，检查生成配置中是否保留 `dialer-proxy`。若 subconverter 版本仍不支持，则节点部分不经 subconverter，改为手写完整配置，仅规则走远程引用。

### 7.2 桥接失败必须断开，禁止降级（强制）

JMS LA 1000 仅含洛杉矶单节点，桥接为单点。**绝不可配置为「桥接失败后自动直连 BD」**——那等于在故障时暴露凭证。正确行为是桥接不可用即出口不通，令故障立即可见。

### 7.3 桥接的流量成本

`dialer-proxy` 生效后，全部 TikTok 运营流量将先经 JMS 洛杉矶，**同时计入 JMS 的 1000 GB 月配额**。按刷 TikTok 约 1–2 GB/小时估算，每日运营 2 小时即 60–120 GB/月，叠加视频上传与常规美国出口用量，1000 GB 未必宽裕。

**决策**：先启用桥接并观察一个月用量，不足则升级套餐。凭证明文暴露的代价高于套餐差价。

### 7.4 凭证已泄露，须先于改造处理

节点订阅存放于 secret gist。**secret gist 不等于私密**——其 raw URL 无需认证即可读取全文（已实测，1756 字节完整返回），且该 URL 每次订阅更新都作为参数发送给 `api.dler.io`。

泄露内容：`password` ×4、`uuid` ×4、`username` ×2，含 BD customer ID / zone / 出口 IP，以及 `net.fishcargo.co` 的 vmess uuid。

**处置顺序：**

1. 重置 Bright Data zone 密码；
2. 重置 JustMySocks 订阅链接；
3. LightNode VPS 退租后其 uuid 自然失效，无需单独处理。

> 该 VPS 托管于 LightNode 云端而非办公室网络，**不存在内网横向风险**。

---

## 8. 成本优化

```
🇺🇸 JMS LA 1000     → 美国出口 + socks5 桥接跳板
🇨🇴 BD 哥伦比亚-家里 → TikTok / 社媒运营
🇨🇴 BD 哥伦比亚-公司 → 加密货币平台
❌ LightNode VPS     → 退租
```

| | 现状 | 优化后 |
|---|---|---|
| JMS LA 1000 | ~$9.88 | ~$9.88 |
| Bright Data ISP | $35.00 | $35.00 |
| LightNode VPS | **$17.70** | **$0** |
| **合计/月** | **~$62.58** | **~$44.88** |

**每月省 $17.70（年约 $212）**，同时业务隔离度提升（运营与交易分用两个 IP）。

**依据**：加密货币平台仅要求非美国 IP，BD 哥伦比亚出口天然满足，且为固定月费、零边际成本。代价是 Binance 延迟由 296 ms 增至 596 ms，对低频查询场景无实质影响。

---

## 9. 现有配置缺陷修复

| # | 位置 | 问题 | 修复 |
|---|---|---|---|
| 1 | `:113-119` | 全部策略组使用 `url-test` | **统一改 `select`**：节点固定、不依赖机场订阅，无测速择优需求 |
| 2 | `:107` | `🎮 游戏平台` 写成 `select`select`` | 去重 |
| 3 | `:116` | `南美-自动` 声明 `select` 却带 url-test 参数 | 二选一 |
| 4 | `:32,34,65,67` | 四条自有规则 URL 需重写 | 统一指向 `maelitoandres/rules` 新路径 |
| 5 | `:89` | 「🪙 加密货币」组无哥伦比亚选项，仅 `南美-自动` 可间接命中，会漂移到秘鲁/墨西哥/巴西 | 改为直接指向 `哥伦比亚-公司` |
| 6 | ini 全局 | 缺微信视频号规则 | 补入 `CO/CO_ISP_social.list` |
| 7 | gist | 迈阿密/芝加哥/日本/荷兰为死节点 | 删除 |

---

## 10. 已知缺口

### 10.1 无中国落地节点（阻塞项，不阻塞其余部分）

矩阵中 ⚠️ 两格无法兑现：在美国/哥伦比亚办公室时，`CN_rule` 层没有回国出口。结构预留该策略组，待补入回国专线后在 ini 填一行即可生效。

### 10.2 桥接单点

JMS 仅洛杉矶一个节点。缓解措施见 §7.2（失败即断开）。彻底解决需加购节点或自建备用跳板；后者须注意线路质量，廉价国际线路做桥接会显著拖慢（参照 LightNode 到中国方向 1536 ms）。

### 10.3 旧仓库删除时机

`maelitoandres/Custom_OpenClash_Rules` **暂不可删**。当前 `custom_template_url` 指向该仓库的 `cfg/Custom_Clash.ini`，删除将导致模板拉取失败、**整份配置生成失败**。须在新链路验证通过后再删。

---

## 11. 不做的事（YAGNI）

- 不扩容路由器磁盘分区。
- 不迁移 `doc/` 下的上游教程。
- 不引入 Tailscale / Cloudflare Tunnel——本地部署后无跨地点组网需求。
- 不为「一台设备跟人移动」做可切换配置——三地均为固定路由器。
- 不购买额外地区节点——加密货币仅需非美国 IP，现有 BD 出口已满足。

---

## 12. 实施顺序

1. 凭证轮换（§7.4）
2. 目录结构与规则文件迁移（§4、§5）
3. `rule/README.md` 重构，写入语义约定（§4.1）
4. 三份 ini 生成（§4.2 矩阵）
5. 缺陷修复（§9）
6. 本地 subconverter 部署（§6）
7. **验证 `dialer-proxy` 是否保留**（§7.1）——决定是否改用手写配置
8. 中国办公室路由器切换验证
9. LightNode 退租（§8）
10. 另两地路由器部署
11. 验证通过后删除旧仓库（§10.3）

---

## 附录 · 调研过程中被修正的判断

以下结论在调研中被实测推翻，记录以免重蹈：

| 初始判断 | 实测结果 |
|---|---|
| 私有仓库无法被 subconverter 读取 | **可读**，URL 内嵌 token 即可（HTTP 200）。改公开的真实理由是 token 会暴露给第三方转换服务 |
| 保持私有会堵死 CDN 加速 | 当前架构下 CDN 本就不生效（provider 走 dler.io），该论据不成立 |
| BD 按流量计费，url-test 探测在烧钱 | **固定 $35/月**，探测不产生额外成本。改 `select` 的理由仅为语义正确 |
| BD 的 IP 未必被认作住宅 ISP（据 whois 推断） | **实测 proxy/hosting 均为 false**，Bogotá + 电信 ASN。whois 反映所有权链条，风控看的是 ASN 用途分类，两者不等价 |
| LightNode VPS 线路质量根本不行 | **国际方向优秀**（基准 260 ms、Binance 296 ms 全场最佳），仅中国方向极差（1536 ms） |
| fishcargo uuid 泄露可能导致办公室内网横向渗透 | 该节点托管于 LightNode 云端，**不在办公室网络内**，无内网风险 |
