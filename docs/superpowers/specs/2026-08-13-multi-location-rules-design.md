# 多地点 OpenClash 规则库改造设计

**日期**：2026-08-13
**仓库**：https://github.com/maelitoandres/rules （public）
**状态**：设计已确认，待实施

---

## 1. 背景与目标

现有规则库 fork 自 `Aethersailor/Custom_OpenClash_Rules`，其结构假设「用户在中国境内」这一单一场景。实际使用场景为三个固定办公地点，各有一台常驻 iStoreOS 路由器：

- 🇨🇳 中国办公室
- 🇺🇸 美国办公室
- 🇨🇴 哥伦比亚办公室

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

关键事实：

- 路由器**从不直接访问 GitHub 拉规则**，全部经 `api.dler.io` 中转。
- 因此 `github_address_mod='https://testingcf.jsdelivr.net/'`（jsDelivr 加速）**对这 55 个 provider 完全不生效**——URL 域名是 `api.dler.io`。
- `api.dler.io` 是三地共同的单点故障：它不可用时，三地规则同时停更。

### 2.2 链路实测（自路由器发起，2026-08-13）

| 链路 | 结果 |
|---|---|
| `api.dler.io/getruleset` | HTTP 200，1.11 s |
| `testingcf.jsdelivr.net`（CDN） | HTTP 200，1.19 s |
| `raw.githubusercontent.com`（直连） | HTTP 200，3.36 s |

CDN 比直连快约 3 倍——但只有在摆脱 dler.io 中转、由本地拉取规则后才能兑现。

### 2.3 规则文件使用状况

仓库内 9 个 `.list`，仅 4 个被 ini 以自有 URL 引用，其中 2 个因改名已断，**当前实际生效的只有 2 个**：

| 文件 | 条数 | 状态 |
|---|---|---|
| `trabajo.list` | 45 | ✅ 在用（`Custom_Clash.ini:67` → 📺 国内媒体） |
| `Coin.list` | 17 | ✅ 在用（`:34` → 🪙 加密货币） |
| `USA_rule.list` | 1 | ⚠️ **已断**：ini 仍引用旧名 `usa.list` |
| `CO_ISP_rule.list` | 62 | ⚠️ **已断**：ini 仍引用旧名 `colombia.list` |
| `ChinaDomain.list` | 564 | ❌ 死文件 |
| `Custom_Direct.list` | 48 | ❌ 死文件 |
| `Custom_Proxy.list` | 11 | ❌ 死文件 |
| `Ozon.list` | 2 | ❌ 死文件 |
| `Steam_CDN.list` | 23 | ❌ 死文件 |

「死文件」指 ini 引用的是 Aethersailor / ACL4SSR 的上游 URL，仓库内的副本从未被读取。

### 2.4 节点资源

| 节点 | 类型 | 服务器 | 性质 |
|---|---|---|---|
| 🇨🇴 哥伦比亚-家里 | socks5 | `brd.superproxy.io:22228` | Bright Data 住宅 ISP，固定出口 `185.177.78.55` |
| 🇨🇴 哥伦比亚-公司 | socks5 | `brd.superproxy.io:22228` | Bright Data 住宅 ISP，固定出口 `185.177.78.116` |
| 🇨🇴 FISH-哥伦比亚 | vmess | `net.fishcargo.co:443` | **自建办公节点** |
| 🇺🇸 洛杉矶 / 迈阿密 / 芝加哥 | ss / vmess | `portablesubmarines.com` | 商业机场 |
| 🇯🇵 日本 / 🇳🇱 荷兰 | vmess | `portablesubmarines.com` | 商业机场 |

**硬缺口：无中国落地节点。**

---

## 3. 设计模型

需求分为两类，**不能用同一套逻辑表达**：

### A 类 · 地理分流

「我人在哪，这个服务该从哪出去」。策略是所在地与服务归属地的函数，对角线直连。

### B 类 · 运营绑定

「这个平台的流量必须始终从固定住宅 IP 出去」，用于 TikTok CO 等账号运营，平台风控看的是 IP 稳定性。**与所在地无关**。

### 两类的冲突与优先级

同一域名会同时命中两类规则。以抖音为例：

- A 类判定：中国服务 → 在中国办公室应直连
- B 类判定：运营账号 → 必须走 CO 住宅 IP

**B 类必须优先。** subconverter 按 ini 中 `ruleset=` 的出现顺序生成规则，先匹配先生效，因此 B 类规则集必须排在所有 A 类之前。

---

## 4. 目录结构

```
rules/
├── rule/
│   ├── ops/          ★ 运营绑定层 · 优先级最高 · 与所在地无关
│   │   ├── co-tiktok.list        TikTok CO 运营
│   │   └── co-cn-social.list     抖音·微博·小红书·微信视频号 → CO 住宅 IP
│   ├── cn/           中国的服务
│   ├── us/           美国的服务
│   ├── co/           哥伦比亚的服务
│   └── global/       无地域归属
├── cfg/
│   ├── cn.ini        中国办公室路由器
│   ├── us.ini        美国办公室路由器
│   └── co.ini        哥伦比亚办公室路由器
├── docs/             本设计文档所在
├── doc/              （上游遗留教程，保留原样）
└── game_rule/        （上游遗留，未引用，保留）
```

**命名语义**：`rule/cn/` 表示「**中国的服务**」，不是「中国用的规则」。这一区分是整个设计的核心——按使用地点分目录会导致同一域名在多个目录重复（N 个服务 × 3 地 = 3N 份），改一处要追三个文件。

### 策略映射矩阵

| 层 | 🇨🇳 中国办公室 | 🇺🇸 美国办公室 | 🇨🇴 哥伦比亚办公室 |
|---|---|---|---|
| **ops/** | CO 住宅 IP | CO 住宅 IP | CO 住宅 IP |
| `cn/` | 直连 | 回国节点 ⚠️ | 回国节点 ⚠️ |
| `us/` | 美国节点 | 直连 | 美国节点 |
| `co/` | CO 节点 | CO 节点 | 直连 |
| `global/` | 代理 | 直连 | 直连 |

⚠️ = 依赖尚不存在的中国落地节点，见 §8。

**维护规则**：新增域名时只需判断「这是运营用的，还是哪国的服务」，放入对应目录即可，三地策略自动生效，ini 无需改动。

---

## 5. 文件迁移映射

### 5.1 `trabajo.list` 拆分（当前最大问题）

该文件挂在「📺 国内媒体」组，而该组仅有 `DIRECT` 选项（`Custom_Clash.ini:99`），导致 45 条域名**全部强制直连**——其中混有大量国际站点。在中国办公室，`figma.com` 强制直连基本不可用，各大船公司官网直连亦极慢。

**拆分为 `cn/work.list`（直连）：**

```
hgj.com, nextsls.com, healthoo.com, qishui.com, logwingbooking.com, weiyun001.com,
zimchina.com, matson.com.cn, msccargo.cn, coscoshipping.com, sinotrans.com,
sino56.com, pingpongx.com, quickconnect.cn, vcaveman.com, qcc.com, hgmsds.com,
gov.cn, hllep.com, accountboy.com, snssdk.com,
51touxiang.com, volceapplog.com, volces.com,
mihoyo.com, miyoushe.com, kunluncan.com, tcsdzz.com
```

**拆分为 `global/work-shipping.list`（按地点走代理或直连）：**

```
zim.com, matson.com, maersk.com, cma-cgm.com, hapag-lloyd.com, one-line.com,
evergreen-marine.com, hmm21.com, yangming.com, wanhai.com, pilship.com, oocl.com,
fedex.com, dhl.com
```

**拆分为 `global/tools.list`：**

```
figma.com, coreldraw.com, cloudflare.com
```

> **待确认**：`hgj.com`、`nextsls.com`、`healthoo.com`、`logwingbooking.com`、`hllep.com`、`accountboy.com`、`kunluncan.com`、`tcsdzz.com` 归属未能从域名判定，实施时需逐个确认应归 `cn/` 还是 `global/`。

### 5.2 其余文件

| 现文件 | 去向 | 说明 |
|---|---|---|
| `CO_ISP_rule.list` | `ops/co-cn-social.list` | 语义即「须走 CO 住宅 IP 的中国社媒」 |
| `USA_rule.list` | `us/finance.list` | 目前仅 `schwab.com` 1 条 |
| `Coin.list` | `global/crypto.list` | |
| `ChinaDomain.list` | 删除 | 死文件，ACL4SSR 上游已覆盖 |
| `Custom_Direct.list` | 删除 | 死文件，引用的是上游 URL |
| `Custom_Proxy.list` | 删除 | 死文件 |
| `Ozon.list` | 删除 | 死文件，引用的是上游 URL |
| `Steam_CDN.list` | 删除 | 死文件，引用的是上游 URL |
| `game_rule/` | 保留 | 上游遗留，未引用但无害 |

### 5.3 新增

- `ops/co-tiktok.list` — TikTok CO 运营域名
- **微信视频号规则** — 当前 ini 完全缺失，需补入 `ops/co-cn-social.list`

---

## 6. 架构改造：本地 subconverter

### 动机

1. **凭证外泄**：当前全部节点凭证（含 Bright Data 商业账号、自建办公节点 uuid）随每次订阅更新完整发送给 `api.dler.io`。
2. **单点故障**：三地共同依赖一个第三方服务。
3. **CDN 失效**：经 dler.io 中转导致 jsDelivr 加速无法生效。

### 方案对比

| 方案 | 需公网 IP | 单点故障 | 凭证暴露给 | 跨国依赖 |
|---|---|---|---|---|
| 现状 api.dler.io | 否 | 有 | 第三方 | 有 |
| 群晖 NAS 集中部署 | **是**（或穿透组网） | 有 | 不出自有网络 | 有 |
| **每路由器本地部署** | 否 | **无** | **不出本机** | 无 |

**采用每路由器本地部署。**

### 部署

路由器实测环境：iStoreOS 24.10.8 / x86_64 / 4 核 / 16 GB 内存（空闲 15.2 GB）/ Docker 27.3.1 + docker-compose 已装 / Docker 根目录 `/overlay/upper/opt/docker` 可用 1.8 GB。

```bash
docker run -d --name subconverter --restart always \
  -p 127.0.0.1:25500:25500 tindy2013/subconverter:latest
```

OpenClash 中将转换地址由 `https://api.dler.io/sub` 改为 `http://127.0.0.1:25500/sub`。

副作用（正面）：rule-provider URL 不再经 dler.io，直接指向 GitHub，jsDelivr 加速随之生效。

> 注：NVMe 总容量 119.2 GB，分区仅划 1.9 GB，约 117 GB 未分配。subconverter 无需扩容即可运行；扩容不属本设计范围。

---

## 7. 现有配置缺陷修复

| # | 位置 | 问题 | 修复 |
|---|---|---|---|
| 1 | `Custom_Clash.ini:114-115` | `哥伦比亚-家里`/`公司` 组内仅单节点却用 `url-test`，每 60 秒探测一次住宅代理，约 2880 次/天，持续消耗按 GB 计费的 Bright Data 流量；且运营场景本就不应自动切换 | 改为 `select` |
| 2 | `Custom_Clash.ini:107` | `🎮 游戏平台` 写成 `select`select`，语法重复 | 去重 |
| 3 | `Custom_Clash.ini:116` | `南美-自动` 声明为 `select` 却携带 url-test 测试参数 | 二选一 |
| 4 | `Custom_Clash.ini:32,34,65,67` | 四条自有规则 URL 全部需重写：目录结构变更后路径改变，且 `usa.list` / `colombia.list` 已因改名失效、`:32` `:65` 两条当前已断 | 生成三份新 ini 时统一指向 `maelitoandres/rules` 的新路径 |
| 5 | ini 全局 | 缺微信视频号规则 | 补入 `ops/` |

---

## 8. 已知缺口与风险

### 8.1 无中国落地节点（阻塞项）

矩阵中 ⚠️ 两格无法兑现：在美国 / 哥伦比亚办公室时，`cn/` 层（国内媒体、中国船公司站点）没有回国出口。

**处理**：结构预留该策略组，待补入回国专线后在 ini 中填一行即可生效。不阻塞本次改造的其余部分。

### 8.2 凭证已泄露（须先于改造处理）

节点订阅存放于 secret gist。**secret gist 不等于私密**——其 raw URL 无需任何认证即可读取全文（已实测，1756 字节完整返回），且该 URL 每次订阅更新都作为参数发送给 `api.dler.io`。

泄露内容：`password` ×4、`uuid` ×4、`username` ×2，含 Bright Data customer ID / zone / 住宅出口 IP，以及自建办公节点 `net.fishcargo.co` 的 vmess uuid。

**风险分级**：

1. **自建办公节点**（最高）——他人可用其从办公室 IP 出网，行为归属到本人；若服务端未限制私有网段，可进一步探测办公室内网。
2. **Bright Data**——按流量计费的商业账号，凭证被用即产生实际账单。
3. **商业机场**——可后台重置订阅，损失可控。

**处置顺序（先于架构改造执行）**：

1. 轮换 `net.fishcargo.co` 的 vmess uuid；
2. 在该节点服务端加出站规则，禁止访问 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`；
3. 重置 Bright Data zone 密码；
4. 重置机场订阅链接。

### 8.3 旧仓库删除时机

`maelitoandres/Custom_OpenClash_Rules` **暂不可删**。当前 `custom_template_url` 直接指向该仓库的 `cfg/Custom_Clash.ini`，删除将导致模板拉取失败、**整份配置生成失败**（非「少几条规则」）。须在新链路验证通过后再删。

---

## 9. 不做的事（YAGNI）

- 不扩容路由器磁盘分区——与本设计无关。
- 不迁移 `doc/` 下的上游教程——保留原样。
- 不引入 Tailscale / Cloudflare Tunnel——本地部署 subconverter 后无跨地点组网需求。
- 不为「一台设备跟人移动」的场景做可切换配置——已确认三地各为固定路由器。

---

## 10. 实施顺序

1. 凭证轮换（§8.2）
2. 目录结构与规则文件迁移（§4、§5）
3. 三份 ini 生成（§4 矩阵）
4. 缺陷修复（§7）
5. 本地 subconverter 部署（§6）
6. 中国办公室路由器切换验证
7. 另两地路由器部署
8. 验证通过后删除旧仓库（§8.3）
