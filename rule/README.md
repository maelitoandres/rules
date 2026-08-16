# 规则目录说明

## ⚠️ 最重要的约定

> **目录名表示「流量从哪个国家出去」，不是「我人在哪个国家」。**

这是整个结构的地基。一旦被理解成"使用地点"，同一个域名就得在多个目录里重复——`schwab.com` 要走美国出口，无论你人在中国还是哥伦比亚，它都只属于 `US/`，只写一次。

反例（改造前的真实情况）：旧的 `CO_ISP_rule.list` 文件名是 CO，内容却是抖音域名（中国服务）。因为它混进了"我人在哥伦比亚"这个维度，结果是文件名和内容对不上，扩展到三地时必然重复维护。

---

## 目录结构与策略组对应

```
rule/
├── CO/      🇨🇴 哥伦比亚出口（Decodo 住宅 IP）
│   ├── CO_douyin_rule.yaml   → 🎶 抖音         33 条   ★ 与上游 DouYin 同组
│   ├── CO_weibo_rule.yaml    → 📕 微博         26 条   ★ 与上游 Weibo 同组
│   ├── CO_xhs_rule.yaml      → 📕 小红书        6 条   ★ 与上游 XiaoHongShu 同组
│   ├── CO_wechat_rule.yaml   → 💬 微信运营     11 条
│   ├── CO_crypto_rule.yaml   → 🪙 加密货币     17 条   ⚠️ 现走 🇯🇵 日本，见下
│   └── CO_social_rule.yaml   → 🇨🇴 CO补充       1 条   跨 app 通用域名
├── US/      🇺🇸 美国出口
│   └── US_rule.yaml          → 🇺🇸 美国服务     4 条
├── CN/      🇨🇳 中国出口
│   ├── CN_rule.yaml          → 🇨🇳 中国出口    26 条
│   └── CN_sdk_rule.yaml      → 🎯 全球直连     20 条   国内SDK/统计/授时/群晖
└── GLOBAL/  🚀 通用
    ├── Global_rule.yaml      → 🌎 国外媒体     16 条
    └── Apple_rule.yaml       → 🍎 苹果服务      1 条   ★ 补上游 Apple.yaml 的遗漏
```

**一个文件 = 一个策略组。** 全库 161 条。

> ⚠️ `CO_crypto_rule.yaml` 是唯一出口与目录名不一致的文件：Decodo 按类目封锁
> 金融/加密站点（实测币安/OKX/Coinbase/CoinGecko/Chase 全部不可达），
> 该组已改走「🇯🇵 日本」。交易所看的是国际 IP 库，本就不需要住宅 IP。

### ★ 补充规则必须与 app 主规则同组

`CO_douyin_rule` / `CO_weibo_rule` / `CO_xhs_rule` 指向的是 **app 自己的策略组**
（🎶 抖音 / 📕 微博 / 📕 小红书），不是独立的补充组。

**原因**：补充规则若走独立的组，在面板切换该 app 的出口时不会跟着切，
**同一个 app 的流量会从两个不同 IP 出去**——对运营账号而言，这比 IP 不对
更容易触发风控。2026-08-16 实测撞到过：`🇨🇴 CO补充` 与微博组被重置到了
两个不同的出口节点，微博流量因此分走两个 IP。

**ini 里的位置**：补充规则必须紧跟在对应上游规则集之后。

```ini
ruleset=🎶 抖音,clash-classic:.../Clash/DouYin/DouYin.yaml       # 上游 13 条
ruleset=🎶 抖音,clash-classic:.../CO/CO_douyin_rule.yaml         # 自建补充 32 条
```

> **格式必须是 `payload:` 结构的 `.yaml`**，不能是裸 `.list`——ini 里用 `clash-classic:`
> 前缀让 provider 直连时，subconverter 不输出 `format:` 字段，mihomo 默认按 yaml 解析。
> 详见 [`docs/troubleshooting.md` §1](../docs/troubleshooting.md)。
>
> `CN_sdk_rule.yaml` 是唯一出口为「直连」的规则集——收录国内推送/统计 SDK（jpush、getui、
> 厂商服务、NTP），这些服务器都在国内，绕代理既慢又暴露。

> `CO_crypto_rule.yaml` 对应的组叫「CO冲浪快线」而非「CO加密货币」——该组职责已扩展为「哥伦比亚出口的通用需求」，加密货币只是其中之一。文件名保留 `crypto` 是因为当前内容确实是加密货币域名。

---

## 节点与出口

| 节点 | 实体 | 桥接（`dialer-proxy`） | 服务对象 |
|---|---|---|---|
| `🇨🇴 运营01` | Decodo `23.27.43.108` | → `🇺🇸 CN2GIA快线` | 运营设备（10.1.2.33）的全部社媒 |
| `🇨🇴 运营02` | Decodo `23.27.41.10` | → `🇺🇸 CN2GIA快线` | 预留给第二台运营设备 |
| `🇨🇴 运营03` | Decodo `136.0.47.9` | → `🇺🇸 CN2GIA快线` | 备用 / 故障切换 |
| `🇺🇸 CN2GIA` | JMS c55s3 · 洛杉矶 167ms | — | 桥接主力，美国服务首选 |
| `🇯🇵 日本` | JMS c55s4 · 大阪 **65ms** | — | 入口延迟最低，桥接降级目标 |
| `🇺🇸 直连备用` | JMS c55s2 · 洛杉矶 168ms | — | 故障顶替 |

**一台设备一个 IP。** 运营节点只由 AND 规则引用，不应出现在任何策略组的当前选择里 ——
别的设备蹭同一个 IP 会污染行为画像。

> `🇯🇵 日本` 曾被命名为「🇺🇸 日本中转」，导致它被 `(🇺🇸)` 正则误收进美国桥接池。
> 实体在大阪，2026-08-17 正名。

### ⚠️ 已知未解决：小红书属地

Decodo 三个 IP 的 ASN 都是 AS14080 Telmex Colombia、实体在波哥大，
但**段本身注册在 ARIN（北美）**。国内 IP 库分两派：

- 精细库（微博 / B站 / 抖音 / 微信）跟踪 BGP + ASN → 判哥伦比亚 ✅
- 粗粒度库（小红书）按 RIR 分配判定 → ARIN = 北美 = 美国 ❌

三个 IP 全试过，包括不同 /8 的 `136.0.47.9`，结果一致。
**要根治只能换 LACNIC 注册的段（190/191/200/201 开头）。**
详见 [`troubleshooting.md` §7](../docs/troubleshooting.md)。

---

## 🔒 策略组的四条铁律

### 1. 出口组一律 `select`，桥接组自动切换

判断标准只有一条：**这个组的节点变化，会不会改变最终出口 IP？**

**出口组必须 `select`**（各 app 组）。节点是固定的自建/ISP 出口，不是机场那种几十个节点需要测速择优。更关键的是：自动切换意味着 IP 变动，而运营账号最怕的正是这个——平台风控看的就是 IP 稳不稳。

> 更进一步：**运营出口根本不该依赖策略组**。策略组的选择会在改名时被重置，
> 应当用自定义规则里的 AND 规则直接指向节点名（见 deployment-guide §4.1）。

**桥接组自动切换**（🇺🇸 CN2GIA快线、🇺🇸 冲浪快线）。它们是运营节点 `dialer-proxy` 的目标，**换桥接节点不改变最终出口 IP**——流量仍从住宅 IP 出去，平台看不到任何变动。而线路质量会随时间劣化（2026-08-15 实测：同一出口节点，桥接经 CN2GIA 到抖音 1315ms、经日本 469ms，裸延迟却只差 105ms），靠人工发现再手工切换太被动。

**用 `url-test` 还是 `fallback`，取决于有没有明确的主备偏好**：

| | 切换到谁 | 适用 | 本库用例 |
|---|---|---|---|
| `url-test` | 次快的成员 | 「我只要快」 | 🇺🇸 冲浪快线（日常浏览） |
| `fallback` | 顺序上的下一个 | 「我有指定的主节点」 | 🇺🇸 CN2GIA快线（桥接） |

两者都会剔除测速失败的成员自动切换，区别只在切给谁。
**指定了主节点就必须用 `fallback`**——`url-test` 会让快的成员永远胜出，
日本 65ms 压过 CN2GIA 167ms，等于指定无效。

> `url-test` 测的是**节点裸延迟**，不是「桥接节点 → 出口节点」那一段的路径质量。多数情况下两者方向一致，但理论上可能选中裸延迟低、到出口却绕路的节点。属已知残余风险。
>
> `load-balance` 在两类组里都不要用：出口组会让 IP 跳变，桥接组会让连接在不同路径间分散，TCP 稳定性受损。

### 2. CO 组不含 `DIRECT`

误选会让运营流量直接从本地真实 IP 出去。宁可不通，不可裸奔。

### 3. 桥接组不含 `DIRECT`

`🇺🇸 CN2GIA快线` 与 `🇺🇸 冲浪快线` 被 socks5 节点的 `dialer-proxy` 引用。一旦选中 DIRECT，桥接会**静默退化为明文直连代理服务商**——socks5 凭证明文暴露给 GFW，而面板上看起来一切正常。

### 4. 「🐟 漏网之鱼」绝不含 🇨🇴 节点

该组接的是所有未匹配流量。一旦被切过去，广告追踪、软件更新、各类 app 心跳都会从运营 IP 出去，污染极快且难以察觉。

### 用正则而非写死节点名

```
custom_proxy_group=🎶 抖音`select`[]DIRECT`(运营)`[]🇺🇸 CN2GIA快线`[]🇺🇸 冲浪快线
custom_proxy_group=📕 微博`select`[]DIRECT`(运营)`[]🇺🇸 CN2GIA快线`[]🇺🇸 冲浪快线
```

`(运营)` 把所有名字含「运营」的节点展开进组，新增 `🇨🇴 运营04` 会自动出现，ini 无需改动。
每个业务组各自持有独立的选择状态 → **隔离成立**。

**命名规范**：`🇨🇴 运营NN` / `🇺🇸 {用途}` / `🇯🇵 {用途}`。国旗由 ini 的 `rename` 补，
gist 里写不带国旗的名字（subconverter 会剥离，详见 troubleshooting §14）。

> ⚠️ **不要引入「国家级中间组」**。Clash 的 `select` 组任一时刻只能选中一个节点，多个业务组指向同一中间组即等于共用 IP，隔离会静默失效。`load-balance` 更不可用——它让运营流量在 IP 间跳变。

---

## 各地点的策略映射

同一份规则，三地走向不同——差异全部在 `cfg/*.ini` 里，规则文件本身不需要任何改动：

| 策略组 | 🇨🇳 中国办公室 | 🇺🇸 美国办公室 | 🇨🇴 哥伦比亚办公室 |
|---|---|---|---|
| 🎶 抖音 / 📕 微博 / 📕 小红书 | DIRECT | DIRECT | DIRECT |
| （运营设备的上述 app） | AND 规则 → 🇨🇴 运营01 | 同左 | 同左 |
| 🇺🇸 CN2GIA快线 | CN2GIA | **DIRECT** | CN2GIA |
| 🇨🇳 中国出口 | **DIRECT** | 回国节点 ⚠️ | 回国节点 ⚠️ |
| 🇺🇸 冲浪快线 | 日本中转 | **DIRECT** | **DIRECT** |
| 🐟 漏网之鱼默认 | 冲浪快线 | DIRECT | DIRECT |

运营类三地一致——绑定与所在地无关，平台看的是出口 IP 稳不稳，不是你人在哪。

⚠️ 目前没有中国落地节点，这两格暂为 DIRECT。补上回国专线后自动生效，规则文件无需改动。

---

## 🔍 加规则前的验证规范

2026-08-16 的实测总结。**加错规则比不加更糟**——误伤会把无关流量导向运营 IP，
污染画像且极难察觉。

### 1. 域名归属怎么确认：NS 记录比对

域名名字看不出归属时（如 `bdurl.net`），查它的 NS 记录跟已知域名对照：

```bash
for d in bdurl.net snssdk.com amemv.com; do
  echo "$d → $(dig +short NS $d | head -2 | tr '\n' ' ')"
done
# bdurl.net   → vip3/vip4.alidns.com
# snssdk.com  → vip4/vip3.alidns.com   ← 已知字节域名
# amemv.com   → vip3/vip4.alidns.com   ← 已知字节域名
# 三者一致 → 确认 bdurl.net 属字节
```

比查 whois 有效——域名注册信息大多有隐私保护，查不到持有者。

### 2. IP 段什么时候能加：整段抽查归属

**只有整段归属单一时才能加**。抽查段内 4~5 个点：

```bash
for ip in 36.51.224.1 36.51.224.100 36.51.224.200 36.51.224.254; do
  curl -s "http://ip-api.com/line/$ip?fields=isp,as" | tr '\n' ' '
done
```

| 情况 | 判定 | 实例 |
|---|---|---|
| 全段同一自有 ASN | ✅ 可加 | `36.51.224.0/24` → AS37936 SINA（新浪自有） |
| 独立 CDN 服务商段 | ⚠️ 可加但标注风险 | EdgeNext / Zenlayer / ACE（共享 CDN，其他中企出海也用） |
| **运营商骨干网段** | ❌ **绝不可加** | 抖音备用 IP 落在移动 AS56044/56047、联通 AS17623/17816/136958、金山云 AS141679 |
| **公有云段** | ❌ **绝不可加** | 金山云、阿里云的通用段，跑着大量不同客户 |

**关键认知**：很多 App 租用第三方基础设施，**IP 归属显示的是「房东」不是「租户」**。
抖音的服务器散落在移动/联通/金山云的段里，段内绝大部分 IP 属于别人——这类只能靠域名规则覆盖。

### 3. ASN 规则什么时候用

```yaml
- IP-ASN,139341,no-resolve   # ✅ ACE，专营 CDN，覆盖面可控
- IP-ASN,24429               # ❌ 阿里云整个海外网络，覆盖面远超小红书
- IP-ASN,4134                # ❌ 中国电信骨干网，会把整个电信导向 CO
```

判据：**该 ASN 是否只服务单一主体**。CDN 服务商可以考虑，运营商/公有云绝对不行。

依赖 `ASN.mmdb`（随 `geox-url` 自动更新，OpenClash 内置）。

### 4. 什么时候该用关键字替代逐条

当域名池是**开放集合**时。字节曾逐个收录 17 个 `byte*` 域名，2026-08-16 一天内
又新增 `bdurl`/`bytehwm`/`bytemaimg` 三个——追补没有尽头，最终合并为：

```yaml
- DOMAIN-KEYWORD,byte    # 替代 17 条 DOMAIN-SUFFIX
```

**选关键字的标准是特异性**：

| 关键字 | 判断 |
|---|---|
| `byte` / `weibo` / `xhscdn` / `sinaimg` / `douyin` | ✅ 足够独特 |
| `sina` | ⚠️ 可能误伤（`sinatra.com`） |
| `cn` / `api` / `cdn` | ❌ 灾难 |

关键字还有个额外好处：**能兜住 `.localdomain` 变形**（DNS 解析失败时系统会附加搜索域重试，
`DOMAIN-SUFFIX` 会完全失配）。

### 5. IP 属地怎么验证：用国内库，不是国际库

**国际库判对不算数**。同一个 IP，ip-api 和 RIPE 都说哥伦比亚，国内库却判美国迈阿密——
微博和小红书用的正是后者。

```bash
curl --proxy "socks5h://<凭证>@<入口>" \
     "https://api.bilibili.com/x/web-interface/zone"
# {"addr":"185.177.78.55","country":"美国","province":"佛罗里达州","city":"迈阿密"}
```

B 站接口是最实用的探针，**换 IP 前先跑这条**——几秒验证一个段，
比买完再发评论试错快得多。

> ⚠️ B 站判对**不代表全部平台判对**。2026-08-17 实测 Decodo 的 `23.27.43.108`：
> B站/微博/抖音/微信全判哥伦比亚，唯独小红书判美国。国内库的精细度不一致，
> 最保守的做法是把每个目标平台都实测一遍。

### 6. 买 IP 前必查：RIR 注册归属

比 ASN 和 ISP 更硬的指标。**ASN 是本地运营商也可能被判错**——
Decodo 的 IP ASN 就是 AS14080 Telmex Colombia、实体在波哥大，
但段注册在 ARIN（北美），粗粒度库直接判成美国。

```bash
whois 23.27.43.108 | grep -iE "^(source|organisation|NetRange):"
# organisation: ARIN        ← 北美注册，粗粒度库会判成美国
whois 190.85.0.1  | grep -iE "^(source|organisation|inetnum):"
# organisation: LACNIC      ← 拉美注册，所有库都判对
```

各洲对应的 RIR：**LACNIC** 拉美 / **ARIN** 北美 / **RIPE** 欧洲中东 /
**APNIC** 亚太 / **AFRINIC** 非洲。哥伦比亚的 LACNIC 段通常是
`190.x` `191.x` `200.x` `201.x` 开头。

采购时直接问供应商：**「你们的哥伦比亚 IP 是 LACNIC 段还是 ARIN 段？」**
一句话筛掉不合格的，不用买了再试。

### 7. 纯 IP 直连：域名规则永远补不上的盲区

有些请求**客户端直接连 IP、不做 DNS 解析**，日志里只有裸 IP 没有域名，
`DOMAIN-SUFFIX` / `DOMAIN-KEYWORD` 一条都匹配不到。这类漏网只能靠盯
「🐟 漏网之鱼」里的裸 IP 发现：

```bash
grep "漏网之鱼" /tmp/openclash.log \
  | sed -E 's/.*--> //; s/:[0-9]+ match.*//' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort | uniq -c | sort -rn
```

连续的地址段（如 `.28`~`.35`）几乎肯定属于同一个服务，按 §2 的方法整段抽查后
用 `IP-CIDR,...,no-resolve` 收录。

实测案例：小红书评论接口走 `155.102.55.0/24`（阿里云美国丹佛），
所有域名都走对了节点、属地却仍显示美国，根因就是这一段。

---

## 怎么加一个新域名

只需回答一个问题：**它该从哪个国家出去？**

```
抖音/字节系？               → CO/CO_douyin_rule.yaml
微博/新浪系？               → CO/CO_weibo_rule.yaml
小红书？                    → CO/CO_xhs_rule.yaml
微信视频号？                → CO/CO_wechat_rule.yaml
需要哥伦比亚 IP 的其他需求？ → CO/CO_crypto_rule.yaml
归属未定 / 跨多个 app？      → CO/CO_social_rule.yaml（确认后再移走）
是美国的服务？              → US/US_rule.yaml
是中国的服务？              → CN/CN_rule.yaml
国内 SDK/统计/授时（走直连）？ → CN/CN_sdk_rule.yaml
以上都不是？                → GLOBAL/Global_rule.yaml
```

放进去就行——**三地自动生效，`cfg/*.ini` 一个字都不用改。**

加完检查是否与其它文件重复：

```bash
find rule -name '*.yaml' | xargs grep -hE '^  - DOMAIN' | sed 's/ *#.*//' | sort | uniq -d
```

---

## 规则优先级

`cfg/*.ini` 里 `ruleset=` 的**出现顺序决定优先级，先匹配先生效**。

`CO/` 下的文件必须排在最前面。原因：抖音域名同时符合两条逻辑——按地域算它是"中国服务"（在中国该直连），按运营算它"必须走 CO 住宅 IP"。**运营绑定必须赢**，所以它得排在 `CN_rule` 前面。

---

## 相关文档

完整设计、实测数据与安全约束见 [`docs/superpowers/specs/2026-08-13-multi-location-rules-design.md`](../docs/superpowers/specs/2026-08-13-multi-location-rules-design.md)
