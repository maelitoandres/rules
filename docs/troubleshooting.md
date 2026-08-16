# 排查手册

> 本文按「症状 → 根因 → 排查方法 → 解法」组织，每条都来自 2026-08-15 ~ 17 的实际故障。
> 涉及 OpenClash 或 subconverter 机制的结论均标注了源码/文档出处——**遇到新问题先查官方文档，
> 不要凭推断下结论**（这条规矩本身就是踩坑换来的，见文末「方法论」）。

---

## 1. 规则集突然全部失效，分流崩溃

### 症状

- 微博/小红书属地突变，评论 IP 显示错误
- yacd 里大量流量掉进「🐟 漏网之鱼」
- `GET /providers/rules` 显示多个 provider 的 `ruleCount` 为 0
- 严重时 `ChinaIp`（7456 条）也归零，国内 IP 全部识别不出来

### 根因

subconverter 在 `expand=false` 模式下，生成的 provider URL 长这样：

```yaml
CO_social_rule:
  type: http
  url: http://127.0.0.1:25500/getruleset?type=6&url=<base64>   # ← 指向本地容器
  interval: 86400
```

**Clash 每次加载规则集都要向 subconverter 容器请求**。容器只应在「更新订阅」时用一次，
却变成了运行期的常驻依赖——容器一挂（重启 / DNS 故障 / 52 个 provider 并发打满），
规则集全部拉不到，分流瞬间崩塌。

更糟的是这会形成**死锁**：容器出不了网 → 规则集空 → `ChinaIp` 为 0 → 容器的 DNS 查询
（223.5.5.5）匹配不到 ChinaIp 规则 → 落到 MATCH 走美国节点 → 查国内 DNS 超时 → 容器
更加出不了网。

### 排查

```bash
PW=$(uci get openclash.config.dashboard_password)
curl -s -H "Authorization: Bearer $PW" http://127.0.0.1:9090/providers/rules \
  | grep -o '"ruleCount":0' | wc -l          # 有多少个规则集是空的

grep -i "provider.*error" /tmp/openclash.log | tail   # 看拉取失败原因
```

### 解法：让 provider 直连，脱离容器

在 ini 的 ruleset 行加**类型前缀**（官方语法，见 subconverter README-cn.md 的外部配置章节）：

```ini
# 改前 —— provider url 指向 127.0.0.1:25500
ruleset=🎶 抖音,https://raw.githubusercontent.com/.../DouYin.list

# 改后 —— provider url 直连原始地址
ruleset=🎶 抖音,clash-classic:https://raw.githubusercontent.com/.../DouYin.yaml
```

原理（subconverter 源码 `src/generator/template/templates.cpp:365, 496-528`）：带 clash 类型
前缀的规则集会被打上 `*` 标记，生成 URL 时走 `url[0] == '*'` 分支直接输出原始地址，
而不是包装成 `getruleset` 接口。

**三个必须注意的前提**：

1. **仍然必须 `expand=false`**（即 OpenClash 订阅设置里的「使用规则集」保持开启）。
   `renderClashScript` 只在 `managed_config_prefix` 非空时被调用，而该值只在 `expand=false` 时赋值。
2. **目标必须是 `payload:` 格式的 `.yaml`**，不能是裸 `.list`。因为 subconverter 只输出
   `type`/`behavior`/`url`/`path`/`interval` 五个字段，**永远不写 `format:`**，而 mihomo 默认
   `format: yaml`。blackmatrix7 和 ACL4SSR 都提供 `.yaml` 版本。
3. **behavior 要选对**：
   - 内容是 `- DOMAIN-SUFFIX,xxx` → `clash-classic:`
   - 内容是 `- '1.0.1.0/24'` 裸 IP → `clash-ipcidr:`
   - 用错会解析失败

改完之后 subconverter 只在生成订阅时用一次，平时停掉都不影响分流。

---

## 2. 「更新订阅」提示成功，但配置根本没变

### 症状

插件日志显示：

```
[Info] Start Updating Config File【统一节点管理】...
[Info] Config File Download Successful, Test If There is Any Errors...
[Info] Config File Test Successful, Check If There is Any Update...
[Info] Config File【统一节点管理】No Change, Do Nothing!    ← 停在这里
```

下载成功、语法通过，但配置文件时间戳纹丝不动。改了 `github_address_mod` 或其他 OpenClash
侧的设置，怎么更新都不生效。

### 根因

`openclash.sh` 的流程是（官方手册 SKILL.md §2546-2554）：

```
config_download()  → 下载订阅
sub_convert        → 发到 subconverter 转换
config_cus_up()    → Ruby 解析 + 节点过滤
config_test()      → clash -t 验证语法
config_su_check()  → 新旧对比，有更新才替换   ← 卡在这
```

`config_su_check()` 比对的是 **subconverter 返回的原始内容**。而 `github_address_mod`
（把 raw 地址改写成 CDN）是在配置生成**之后**由 `yml_rules_change.sh` 执行的——
subconverter 的输出一个字节都没变，对比结果永远是「无变化」。

同理，改订阅 URL 参数（`?v=2` → `?v=3`）也没用：变的是请求 URL，不是返回内容。

### 解法

**删掉配置文件，逼它重建**：

```bash
cp /etc/openclash/config/<配置名>.yaml /root/backup.yaml     # 先备份
rm -f /etc/openclash/config/<配置名>.yaml
nohup /usr/share/openclash/openclash.sh >/tmp/gen.log 2>&1 &
sleep 120
date -r /etc/openclash/<配置名>.yaml    # 时间变了才算成功
```

`config_su_check()` 找不到旧文件就无从判定「无变化」，自然会写入新配置。

### 顺带：命令行触发订阅更新的正确方式

| 命令 | 行为 |
|---|---|
| `/usr/share/openclash/openclash.sh` | ✅ 下载订阅 → 转换 → 生成配置 → 重启（LuCI「更新」按钮走这条） |
| `/etc/init.d/openclash reload` | ❌ 只重载现有配置，不下载 |
| `/usr/share/openclash/openclash_update.sh` | ❌ 直接调用无效果 |

---

## 3. 关闭「绕过中国大陆 IP」后订阅转换失败

### 症状

点更新订阅一直卡在「配置文件订阅的下载链接为...」，容器日志：

```
CURL_INFO: Could not resolve host: raw.githubusercontent.com
Fetch failed. No local cache available.
Cannot download subscription data.
```

### 根因

Docker 容器的 DNS 配的是国内地址（`223.5.5.5` / `119.29.29.29`）。关闭绕过后，这些
**UDP** DNS 查询要进 Clash 处理，但 Docker 网段的 UDP 在 TPROXY 层穿不过去（TCP 是通的——
`nc -z 223.5.5.5 53` 成功，`nslookup` 却超时）。

### 解法：容器 DNS 指向路由器

```bash
docker stop subconverter && docker rm subconverter
docker run -d --name subconverter --restart always \
  -p 127.0.0.1:25500:25500 \
  -e TZ=Africa/Abidjan \
  --dns 10.1.2.2 --dns 223.5.5.5 \
  asdlokj1qpi23/subconverter:latest
```

`--dns` 写进容器定义，重启不丢。走路由器的 dnsmasq 就绕开了 UDP 穿透问题。

> ⚠️ 用 `docker exec` 改 `/etc/resolv.conf` 只是临时的，容器一重启就还原。

---

## 4. 域名规则明明写了却不生效：`.localdomain` 陷阱

### 症状

规则文件里有 `DOMAIN-SUFFIX,sinaimg.cn`，日志里却看到：

```
ad.us.sinaimg.cn.localdomain → 🐟 漏网之鱼 → 美国节点
```

### 根因

**DNS 搜索域机制**（操作系统标准行为，非 App 作恶）：

```
App 查询 ad.us.sinaimg.cn
    ↓ 解析失败（NXDOMAIN 或超时）
系统自动附加搜索域重试 → ad.us.sinaimg.cn.localdomain
    ↓
后缀变成 .localdomain，DOMAIN-SUFFIX,sinaimg.cn 完全失配 → 掉进漏网之鱼
```

搜索域可能来自客户端自身配置（部分 Android ROM 默认 `localdomain`），路由器下发的是
`lan` 也拦不住。

### 排查

```bash
grep "localdomain" /tmp/openclash.log | grep -E "漏网|Match" \
  | sed 's/.*--> //' | sort -u
```

### 解法：关键字兜底

`DOMAIN-KEYWORD` 不受后缀影响：

```yaml
- DOMAIN-KEYWORD,sinaimg    # 覆盖 ad.us.sinaimg.cn.localdomain
- DOMAIN-KEYWORD,xhscdn
- DOMAIN-KEYWORD,weibo
```

选关键字时注意特异性——`weibo`/`xhscdn`/`sinaimg` 足够独特，`sina` 就可能误伤
（`sinatra.com` 之类）。

---

## 5. jsDelivr 缓存导致规则更新半天不生效

### 症状

改完规则推送到 GitHub，purge 也返回 `finished`，但 provider 拉到的还是旧版本，
几小时都不更新。

### 根因

- `testingcf.jsdelivr.net` 是**测试镜像，有独立缓存层，`purge.jsdelivr.net` 清不掉**
- `cdn.jsdelivr.net` / `fastly.jsdelivr.net` 可以 purge，但边缘节点传播有延迟
- `@main` 分支引用缓存长达 12 小时

实测同一时刻三个镜像的差异：

```
raw.github          → 71 条  ✅ 最新
fastly.jsdelivr.net → 70 条  落后 1 个 commit
cdn.jsdelivr.net    → 60 条  落后 3 个 commit
```

### 解法

**规则集用 raw 直连**，把 `github_address_mod` 设为 `0`：

```bash
uci set openclash.config.github_address_mod="0"
uci commit openclash
```

实测 Clash 直连 `raw.githubusercontent.com` 完全正常（探针测试 200/0.68s），没有缓存问题。

> `github_address_mod` 的正常用途是把 provider 的 raw 地址自动转成 CDN
> （`yml_rules_change.sh:292-315` 对三个 jsDelivr 域名有专门的路径转换逻辑，
> 会正确生成 `/gh/user/repo@branch/path` 格式）。国内直连 raw 有问题时再启用。

### 应急：绕过 CDN 立即生效

改规则后急着验证，可以写进**自定义规则文件**（不依赖任何 CDN）：

```yaml
# /etc/openclash/custom/openclash_custom_rules.list
rules:
- IP-CIDR,154.92.24.0/24,🇨🇴 CO补充,no-resolve
```

需要重启 OpenClash 才注入，但立即生效、不受缓存影响。规则集同步后记得删掉。

---

## 6. App 属地偶尔跳回真实 IP

### 症状

绝大多数时候属地正确，但**偶尔**（约每 40 次操作一次）评论显示真实 IP 属地。
网络本身访问正常，不像断线。

### 根因

**不是规则漏了，是节点超时触发了 App 的备用通道**：

```
请求命中域名规则 → 走 CO 节点 → 拨号超时(context deadline exceeded)
                                        ↓
                        App 判定网络异常，启用内置备用 IP 池
                                        ↓
                        备用通道是硬编码 IP，不查 DNS、无域名
                                        ↓
                        Clash 只看到裸 IP → GEOIP(cn) → DIRECT → 真实 IP
```

日志证据长这样（规则命中了，是拨号阶段失败）：

```
dial 🎶 抖音 (match RuleSet/DouYin) --> aggr5-normal-s13.amemv.com:443
     error: context deadline exceeded
```

### 排查：模拟节点故障，精确捕获备用 IP

```bash
# 1. 记录正常状态的 DIRECT 基线
grep "10.1.2.33" /tmp/log | grep DIRECT | grep -oE '\-\-> [0-9.]+:[0-9]+' \
  | sed 's/--> //' | sort -u > /tmp/base.txt

# 2. 阻断节点（模拟波动）
iptables -I OUTPUT -p tcp --dport 22228 -j DROP

# 3. 操作 App，让它启用备用通道，再采集
grep "10.1.2.33" /tmp/log | grep DIRECT | grep -oE '\-\-> [0-9.]+:[0-9]+' \
  | sed 's/--> //' | sort -u > /tmp/now.txt

# 4. 差集就是备用通道 IP
grep -vxF -f /tmp/base.txt /tmp/now.txt

# 5. 恢复
iptables -D OUTPUT -p tcp --dport 22228 -j DROP
```

### 解法

**先看备用 IP 能不能加规则**（判定标准见 `rule/README.md`）：

- 抖音的备用 IP 落在移动/联通/金山云的骨干段里（AS56044/56047/17623/17816/136958/141679），
  **段内混杂无法验证归属，不能加**
- 微博的落在自有段 `36.51.224.0/24`（AS37936 SINA），**整段抽查一致，可以加**

**根本解法是消除超时**。本例的超时源头是 Bright Data 的
**100 req/min 速率限制**——刷短视频轻松突破（100 秒抓到 118 条连接，
评论区头像批量加载瞬时可达 10+ req/s）。完成 KYC 验证可提升至 1000 req/min。

---

## 7. 属地恒定显示错误国家（与实际出口 IP 不符）

### 症状

出口 IP 经多方核实确实在目标国家，泄漏排查也做到 0 条，但平台仍显示其他国家。
且**不同平台判定不一致**——同一个 IP，抖音判哥伦比亚，微博和小红书判美国。

### 根因

**国内平台的 IP 地理库与国际库判定分歧**。各平台各自维护独立的属地判断机制，
没有统一标准——抖音用字节自有库，微博、小红书、B 站各有各的来源。

实测 `185.177.78.55`：

| 数据源 | 判定 |
|---|---|
| ip-api（国际） | Colombia Bogotá · proxy:false |
| ipwho.is（国际） | Colombia Bogota |
| RIPE 注册信息 | `country: CO` |
| **B 站（国内库）** | **美国 佛罗里达州 迈阿密** |
| 抖音 | 哥伦比亚 ✅ |
| 微博 / 小红书 | 美国 ❌ |

该段的先天问题：**注册在 RIPE（欧洲注册局）而非 LACNIC（拉美）**，持有者 ALAXONA
不是哥伦比亚本地 ISP，网络名 `ES2019`。字节读 RIPE 的 `country: CO` 判对，其他库不认。

### ★ 2026-08-17 修正：决定因素是 RIR，不是 ISP

上面「持有者不是本地 ISP」的推断**只对了一半**。换到 Decodo 之后拿到了反例：

| IP | RIR | ASN / ISP | 国内库判定 |
|---|---|---|---|
| `185.177.78.55` (BD) | RIPE | ALAXONA（转售商） | 全部判美国 |
| `23.27.43.108` (Decodo) | **ARIN** | **AS14080 Telmex Colombia** | 微博/B站/抖音/微信 ✅　小红书 ❌ |
| `136.0.47.9` (Decodo) | **ARIN** | **AS14080 Telmex Colombia** | 同上 |
| `190.85.0.1`（对照） | **LACNIC** | AS14080 Telmex Colombia | — |

Decodo 那批的 ASN 和 ISP **就是哥伦比亚本地运营商 Telmex**，实际也在波哥大，
但 IP 段本身注册在 ARIN（北美）。结果是精细库判对、粗粒度库判错。

所以国内 IP 库分两派：

- **精细库**（微博 / B站 / 抖音 / 微信）跟踪真实 BGP 通告和 ASN → 判哥伦比亚 ✅
- **粗粒度库**（小红书）按 RIR 分配归属判定 → ARIN = 北美 = 美国 ❌

`190.85.0.0/16` 是同一个 AS14080 下的 LACNIC 段——**同一家运营商，不同 RIR，判定就不同**。
这说明选 IP 时 ASN 和 ISP 都不是硬指标，**RIR 才是**。

验证一个段属于哪个 RIR：

```bash
whois 23.27.43.108 | grep -iE "^(source|organisation|NetRange):"
# organisation: ARIN          ← 北美，粗粒度库会判成美国
# whois:        whois.arin.net

whois 190.85.0.1 | grep -iE "^(source|organisation|inetnum):"
# organisation: LACNIC        ← 拉美，所有库都判对
```

**买之前先 whois 看 source 字段**，比买完再测省一整轮。向服务商提需求时也要用这个说法：
「需要 LACNIC 注册的段（190/191/200/201 开头）」，而不是「你们的 IP 属地不对」——
后者对方会回「我们的 IP 确实在哥伦比亚」，然后对话就卡住了。

### ★ 验证方法：用 B 站接口当探针

**不要用国际库验证**，它们判对不代表国内平台判对。B 站接口直接回显服务端看到的归属，
且实测与微博、小红书判定一致：

```bash
curl --proxy "socks5h://<代理凭证>@<入口>" \
     "https://api.bilibili.com/x/web-interface/zone"

# 返回: {"addr":"185.177.78.55","country":"美国","province":"佛罗里达州","city":"迈阿密",...}
```

**换 IP 前先用这条验证，返回目标国家才值得买**。几秒就能判断一个段能不能用，
比买了之后发微博评论试错快得多。

### 解法

换出这个 IP 段。实测 `185.177.78.0/23` 整块（`.78` 和 `.79` 两段）都被判迈阿密——
正好覆盖 RIPE 登记的那个 `/23`，所以区块内换任何 IP 都无效。

选新 IP 时的优先级（按重要性排序，2026-08-17 修正）：

1. **RIR 必须是 LACNIC**（哥伦比亚：190/191/200/201 开头）——这是硬指标，
   其他条件再好也补不上。Decodo 的 ARIN 段 ASN 是本地运营商却仍被小红书判美国。
2. ISP 为目标国本地运营商（哥伦比亚：ETB / Claro / Movistar / Tigo / Telmex）
3. 避开转售商持有的段

采购时直接问：**「你们的哥伦比亚 IP 是 LACNIC 段还是 ARIN 段？」** 一句话就能筛掉
不合格的供应商，不用买了再试。

---

## 8. 关闭「绕过中国大陆 IP」的完整影响

### 该开关做了什么（双重机制）

**YAML 层**（`yml_change.sh:692`）：往 `dns.fake-ip-filter` 注入 `rule-set:oc-cn-domain`，
使国内域名**返回真实 IP 而非 Fake-IP**。

**防火墙层**（`init.d/openclash:1405-1413`）：

```
nft: ip daddr @china_ip_route ip daddr != @china_ip_route_pass counter return
```

目标为国内 IP 的流量直接 `return`，**不进内核**。

### 后果

这两层叠加导致：**App 用硬编码 IP 直连国内服务器时，流量在防火墙层就被放行，
Clash 完全看不到**。微信、微博的 API 大量使用这种方式，所以属地怎么改都不生效。

### 关闭后

```
关闭前: 微信 IP 直连 → 防火墙 return → 真实 IP 出去（Clash 看不见）
关闭后: 微信 IP 直连 → 进内核 → parse-pure-ip 嗅探还原域名 → 命中规则 → 走 CO
```

实测关闭后：国内 IP 流量 234 条经 TPROXY，微信从「完全看不见」变成 65 条被规则捕获。

**app 级分流完全不受影响**——`parse-pure-ip` 把域名还原后，这些流量和正常走 DNS 的没有区别。

### 代价与前提

- 所有设备的国内流量都经内核走一遍（N100 上负载从 0.3 涨到约 0.5~0.8，无压力）
- **Clash 挂掉时会全网断网**（关闭前国内流量不依赖它）
- **前提：provider 必须已脱离容器**（见第 1 节），否则会触发死锁
- **前提：容器 DNS 必须指向路由器**（见第 3 节）

### 没有「按源 IP 豁免」的官方机制

源码层面已穷尽确认：

- `china_ip_route` 的全部 nft 规则**只匹配 `ip daddr`**，无一含 `saddr`
- `china_ip_route_pass` 是目标 IP 例外（LuCI「Chnroute Bypassed List」）
- **`lan_ac` 白名单是陷阱**：规则是 `ip saddr != @白名单 → return`，含义是「不在名单里的
  踢出代理」。白名单设备只是「有资格被代理」，走到下面照样被 china bypass 拦下
- `lan_ac_traffic` 的 target 只有 `return`/`accept`/`drop`，没有「强制代理」

要按源 IP 区分只能自己写 nft，且自定义防火墙脚本跑在**所有 OpenClash 规则之后**，
`nft add rule` 会落在终结性 `redirect` 后面对 TCP 完全无效，必须用
`nft insert ... position <handle>` 精确插入。

---

## 9. 补充规则与 app 主规则不同组，流量分走两个 IP

### 症状

面板上把某个 app 切到别的出口测试，发现**只有一半流量跟着切**——另一半还在原来的
节点上。或者同一个 app 的连接，yacd 里显示两个不同的策略组。

### 根因

自建的补充规则集指向了独立的组（如「🇨🇴 CO补充」），而 app 主规则走自己的组
（如「📕 微博」）。**两个组各自持有独立的选择状态**，切换其一另一个不动。

2026-08-16 实测撞到：重新生成配置后 `🇨🇴 CO补充` 被重置为「🇨🇴 冲浪」、
`📕 微博` 是「🇨🇴 社媒」——微博的域名规则走社媒 IP，而补充规则里的 `sinaimg`
关键字和微博 CDN 的 IP 段走冲浪 IP。**同一账号的流量从两个 IP 出去**，
这比 IP 判定不对更容易触发风控。

### 解法

**补充规则集必须指向 app 自己的策略组**，不要新建「xx补充」组：

```ini
ruleset=🎶 抖音,clash-classic:.../Clash/DouYin/DouYin.yaml    # 上游
ruleset=🎶 抖音,clash-classic:.../CO/CO_douyin_rule.yaml      # 自建补充，同组
```

ini 里补充规则紧跟对应上游规则之后。这样面板上组数不变，切换时两份规则同步生效。

> 只有**跨 app 或归属未定**的域名才放进独立的兜底组（本库是 `CO_social_rule` →
> `🇨🇴 CO补充`），确认归属后应移入对应 app 的规则集。

---

## 10. 换任何节点都打不开某个网站：hosts 绕过了整个策略组

### 症状

`gist.github.com` 打不开，但 `github.com` 正常。在 yacd 里把「🚀 GitHub」组换成
任何一个节点都没用——**换节点完全不起作用**，这是关键线索。

### 根因

`/etc/hosts` 里有 GitHub520 之类的加速条目：

```
37.61.54.158    gist.github.com   # Timeout
```

`37.61.54.158` 归属 **Azerbaijan · Baku · Aztelekom LLC**，根本不是 GitHub 的地址。
行尾的 `# Timeout` 是 GitHub520 生成时自己打的标记——它测速时就知道这个 IP 不通，
**照样写进了 hosts**。

hosts 的优先级高于一切 DNS，所以：

```
hosts 硬编码  →  gist.github.com 拿到 37.61.54.158
              →  绕过 fake-ip，也绕过策略组
              →  Clash 老老实实把这个阿塞拜疆地址送进你选的节点
              →  无论选哪个节点都超时
```

`gist.githubusercontent.com` 不在 hosts 里，走 fake-ip 正常，所以只有部分域名坏掉，
更难联想到 hosts。

### 排查

```bash
# 关键判据: 走代理的域名应该拿到 fake-ip(198.18.x.x)，拿到真实 IP 就说明被绕过了
nslookup gist.github.com 127.0.0.1
# → 37.61.54.158        ← 不是 fake-ip，有问题
nslookup gist.githubusercontent.com 127.0.0.1
# → 198.18.1.253        ← fake-ip，正常

# 确认是 hosts 而非 DNS 污染
grep -n "gist" /etc/hosts

# 对照真实 IP
dig +short gist.github.com @1.1.1.1
```

日志层面还有个反直觉现象：Clash 日志里**规则匹配是正确的**
（`match RuleSet(GitHub) using 🐙 GitHub[🇺🇸 日本中转]`），因为 SNI 嗅探还原了域名。
但目标 IP 早在 DNS 阶段就错了，规则对也没用。**日志显示规则正确 ≠ 连接目标正确**。

### 解法

```bash
cp /etc/hosts /etc/hosts.bak
sed -i '/# Timeout/d' /etc/hosts     # 先删明确失效的
/etc/init.d/dnsmasq restart
```

更彻底的做法是**删掉整个 GitHub520 区块**。既然已经有完整的 GitHub 策略组，
hosts 加速没有额外价值，反而是个定时炸弹：

- 完全绕过 fake-ip 和策略组，面板上换节点毫无作用
- IP 过期后是**静默失败**，表现为「某个域名莫名其妙打不开」，极难定位
- 没有自动更新机制的话，条目只会越来越旧

---

## 11. 纯 IP 直连：域名规则永远补不上的盲区

### 症状

某个 app 的属地判定错误，但检查发现**所有相关域名都走对了节点**，
`grep` 日志里该 app 的域名一条漏网都没有。

### 根因

客户端**直接连 IP，不做 DNS 解析**。日志里只有裸 IP，没有域名：

```
10.1.2.33 --> 155.102.55.30:443  match Match  using 🐟 漏网之鱼[🇺🇸 CN2GIA]
10.1.2.33 --> 155.102.55.31:443  match Match  using 🐟 漏网之鱼[🇺🇸 CN2GIA]
...连续 8 个地址 .28 ~ .35
```

`DOMAIN-SUFFIX` / `DOMAIN-KEYWORD` 这类规则**一条都匹配不到**，因为压根没有域名可匹配。
无论往规则集里加多少域名都没用——这是分流的结构性盲区。

实测案例：小红书评论接口走 `155.102.55.0/24`（阿里云美国丹佛），微博切到新节点后
属地已正确，小红书仍显示美国，根因就是这一段掉进了漏网之鱼走美国节点。

### 排查

**盯漏网之鱼里的裸 IP**，这是唯一的发现途径：

```bash
# 找出走漏网之鱼的纯 IP（排除有域名的）
grep "漏网之鱼" /tmp/openclash.log \
  | sed -E 's/.*--> //; s/:[0-9]+ match.*//' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort | uniq -c | sort -rn
```

连续的地址段（如 `.28`~`.35`）几乎肯定属于同一个服务。确认归属后**整段抽查**：

```bash
for ip in 155.102.55.1 155.102.55.28 155.102.55.35 155.102.55.200; do
  curl -s "http://ip-api.com/line/$ip?fields=as,isp,country,city"
done
# 五点全部一致 → 可以按 /24 整段收录
```

### 解法

只能用 `IP-CIDR` 补，且必须带 `no-resolve`：

```yaml
  - IP-CIDR,155.102.55.0/24,no-resolve
```

`no-resolve` 的意义：不为这条规则触发 DNS 解析。纯 IP 连接本来就没有域名，
不加这个参数会让 Clash 做无谓的反查，拖慢匹配。

**不要图省事用 `IP-ASN`。** 例如 `155.102.55.0/24` 属于 AS24429（阿里云），
写 `IP-ASN,24429` 会把所有走阿里云海外服务的流量都拽进运营出口。
只按实测到的段精确覆盖，宁可以后再补。

---

## 12. 更新订阅后策略组全部被重置

### 症状

更新订阅或重启后，面板上所有策略组回到默认值（select 组的第一个选项，通常是 DIRECT）。
运营组被重置意味着**流量直接从真实 IP 出去**，危险且不易察觉。

### 根因

先确认 `store-selected` 的实际状态——**注意查对文件**：

```bash
# ❌ 这是订阅转换后的源配置，里面没有 profile 段，查了会误判
grep -A3 "^profile:" /etc/openclash/config/<配置名>.yaml

# ✅ 内核实际加载的运行配置
ps w | grep "openclash/clash" | grep -oE "\-f [^ ]+"
grep -A3 "^profile:" /etc/openclash/统一节点管理.yaml
# profile:
#   store-selected: true
#   store-fake-ip: true
```

OpenClash 在 `yml_change.sh:532` 无条件注入 `store-selected = true`，
所以**正常情况下策略组选择是持久化的**，每日 cron 自动更新不会重置。

真正会触发重置的是**改名**。`store-selected` 存的是「策略组名 → 节点名」的字符串
映射（在 `/etc/openclash/history/<配置名>.db`）。一旦节点名或组名变化，
旧记录失配，就回退到默认值：

```
节点  运营01     →  🇨🇴 运营01        ← 记录里的"运营01"找不到了
组名  🇺🇸 快线   →  🇺🇸 CN2GIA快线    ← 同理
```

### 排查

```bash
# 验证持久化是否真的工作: 重启后选择应当原样保留
/etc/init.d/openclash restart
sleep 60
curl -s -H "Authorization: Bearer $SECRET" \
     "http://127.0.0.1:9090/proxies/<URL编码的组名>" | grep -oE '"now":"[^"]*"'
```

### 解法

- 改名是一次性代价，改完手动恢复一次即可，之后自动更新不会再重置
- **运营出口不要依赖策略组选择**。写进自定义规则、直接指向节点名的 AND 规则
  不受重置影响（见 §9），这是运营链路唯一可靠的绑定方式
- 批量改名前先导出当前选择，改完照着恢复

---

## 13. 区分桥接层故障与出口节点故障

### 症状

运营流量间歇性 `context deadline exceeded`，怀疑是代理服务商不稳定，
但服务商侧的并发和延迟测试都正常。

### 根因

用 `dialer-proxy` 桥接时，链路是**两跳**：

```
客户端 → Clash → 桥接节点(dialer-proxy) → 出口节点(住宅IP) → 目标
```

任何一跳出问题都表现为同样的超时。**日志里的报错地址就是判据**：

```
dial 🎶 抖音 ... --> edith.xiaohongshu.com:443
  error: 198.35.45.233:443 connect error: context deadline exceeded
          ^^^^^^^^^^^^^^ 这是桥接节点(CN2GIA)的地址，不是出口节点
```

实测 2026-08-16：39 次超时**全部**来自桥接层，而同期直接测出口节点：
并发 20 全部成功、单连接 5 次测试 IP 稳定不变。问题在桥接节点，不在服务商。

### 排查

```bash
# 1. 报错地址是谁？如果是桥接节点的 IP，问题就在桥接层
grep "deadline exceeded" /tmp/openclash.log | grep -oE "error: [0-9.]+:[0-9]+" | sort | uniq -c

# 2. 单独压测出口节点，绕开桥接（直接从本机连服务商）
for i in $(seq 1 20); do
  (curl -s -o /dev/null --max-time 20 --proxy "socks5h://<凭证>@<入口>:<端口>" \
        -w "%{http_code}\n" "https://example.com/" &)
done; wait

# 3. 逐个测桥接候选节点的稳定性
for n in <节点1> <节点2>; do
  for i in 1 2 3 4 5 6; do
    curl -s -H "Authorization: Bearer $SECRET" \
      "http://127.0.0.1:9090/proxies/$n/delay?url=http://www.gstatic.com/generate_204&timeout=6000"
  done
done
```

### 解法：桥接组用 fallback，不要用 url-test

```ini
# ❌ url-test 选延迟最低的成员 —— 快的那个会永远胜出，等于指定主节点无效
custom_proxy_group=🇺🇸 CN2GIA快线`url-test`[]🇺🇸 CN2GIA`[]🇯🇵 日本`http://www.gstatic.com/generate_204`300,,50

# ✅ fallback 按顺序取第一个可用的 —— 主节点活着就用它，挂了自动降级，恢复后切回
custom_proxy_group=🇺🇸 CN2GIA快线`fallback`[]🇺🇸 CN2GIA`[]🇯🇵 日本`http://www.gstatic.com/generate_204`60,5
```

两个要点：

- **成员顺序即优先级**，不要随意调整
- `interval` 取 60s 而非默认 300s。桥接层故障会直接让运营流量报错，
  5 分钟才发现太久；代价只是多一点健康检查流量

**桥接节点更换不影响出口 IP**，平台看到的仍是住宅 IP，所以桥接层可以放心做自动切换——
但运营出口组必须保持 `select` 手动固定。

---

## 14. 改完 gist 节点全部失效：YAML 语法与 emoji 剥离

### 症状

在 gist 里改了节点名，更新订阅后节点消失或名字变成空字符串，所有引用该节点的
规则和策略组一起失效。

### 根因一：`name:` 后缺空格

```yaml
# ❌ 冒号后没有空格，YAML 不把它当键值对
- {name:🇨🇴 运营01, server: isp.decodo.com, ...}

# ✅
- {name: 🇨🇴 运营01, server: isp.decodo.com, ...}
```

YAML 的 flow mapping 要求 `key: value` 冒号后必须有空格。少一个空格，
subconverter 解析出来是这样：

```
- {name: ""
- {name: " 2"
- {name: " 3"
```

**节点名全空**。危险之处在于订阅转换本身不报错，配置照常生成，
只是所有节点静默失效。

### 根因二：subconverter 会剥离节点名里的 emoji

在 gist 里写 `🇨🇴 运营01`，转换后会变成 `运营01`——国旗被剥掉了。
所以国旗要靠 ini 的 `rename` 补回：

```ini
rename=^运营01$@🇨🇴 运营01
```

注意 `^运营01$` 精确匹配的是**剥离国旗之后**的名字。这解释了一个看起来矛盾的现象：
gist 里明明写着 `🇨🇴 社媒`，ini 里却还要一条 `rename=^社媒$@🇨🇴 社媒` 才生效。

### 排查：改完 gist 先验证解析，不要直接更新订阅

```bash
# 用 subconverter 干跑一遍，不影响运行配置
U="<URL编码的gist地址>"
curl -s "http://127.0.0.1:25500/sub?target=clash&url=${U}" \
  | grep -E "<你的服务器域名>" \
  | grep -oE "name: [^,]+|dialer-proxy: [^,}]+"
```

看到预期的节点名再更新订阅。**这一步能省掉一轮「更新→发现全挂→回滚」**。

### 附带：改名会牵动四个地方

```
① gist 的 name
② ini 的 rename=^新名$@🇨🇴 新名
③ ini 里各策略组的正则 (旧关键字) → (新关键字)
④ 自定义规则(AND 规则)里写死的节点名
```

漏掉任何一处都是**静默失效**：AND 规则的目标找不到时，OpenClash 会打
`Skiped The Custom Rule Because Group & Proxy Not Found`，规则被丢弃，
运营流量退回策略组。改完务必检查：

```bash
grep -c "Skiped The Custom Rule" /tmp/openclash.log   # 应为 0
```

---

## 15. 代理商按类目封锁目标站点

### 症状

代理本身可用（能访问一般网站），但某些站点一律连不上，
表现为 TLS 握手完成后无响应。

### 根因

住宅/ISP 代理商普遍有**默认封锁类目**，与你的用途无关。Decodo 的清单：

> Banking and other financial activities (anything related to financial institutions
> and cryptocurrency financing), Government sites, Entertainment (e.g., Netflix),
> Apple/Google stores, Ticketing, Gaming, Mailing, Streaming, Business, Telecommunications
>
> **Unblocking blocked websites is not possible with Dedicated ISP proxies.**

关键在于**实施上按域名黑名单拦，不看用途**。文档措辞是 "cryptocurrency financing"，
但实测纯行情站 CoinGecko（不涉及任何融资）同样被拦。

### 排查：必须用中立对照组

这类测试极易误判——网络抖动会让所有目标一起失败。**不要用代理商自己的接口做基线**
（`ip.decodo.com` 之类永远是通的，说明不了问题）：

```bash
PX="socks5h://<凭证>@<入口>:<端口>"

# 基线: 中立的国外站点
for u in https://example.com/ https://www.cloudflare.com/; do
  curl -s -o /dev/null --max-time 20 --proxy "$PX" -w "$u → %{http_code}\n"
done

# 基线为 200 时，以下结果才可信
for u in https://www.binance.com/ https://www.coingecko.com/ https://www.netflix.com/; do
  curl -s -o /dev/null --max-time 20 --proxy "$PX" -w "$u → %{http_code}\n"
done
```

实测结果（同一时刻）：

```
example.com / cloudflare.com          → 200 / 200    ← 基线正常
binance / okx / coinbase / coingecko  → 000          ← 类目封锁
chase.com / netflix.com               → 000
```

### 顺带：端口白名单未必如文档所述

Decodo 文档称 Static Residential 只开放 `80 / 443 / 563 / 8443 / 43`，
但实测 `8080` 和 `8081` 同样可用（新浪部分服务走 8081）：

```bash
for pt in 80 443 8080 8081 8443; do
  curl -s -o /dev/null --max-time 20 --proxy "$PX" -w "端口 $pt → %{http_code}\n" \
       "http://portquiz.net:${pt}/"
done
```

`portquiz.net` 在任意端口都监听，是验证端口白名单的现成靶子。

### 解法

把受影响的策略组指向别的节点。加密货币交易所看的是国际 IP 库，
本来就不需要住宅 IP，改走普通节点即可：

```ini
custom_proxy_group=🪙 加密货币`select`[]🇯🇵 日本`[]🇺🇸 CN2GIA快线`[]🇺🇸 冲浪快线`[]DIRECT
```

**采购前先测**：拿试用 IP 把自己要用的关键站点跑一遍，比买完再发现快得多。

---

## 16. 常用排查命令

```bash
# 规则集加载状态
PW=$(uci get openclash.config.dashboard_password)
curl -s -H "Authorization: Bearer $PW" http://127.0.0.1:9090/providers/rules \
  | sed 's/},"/}\n"/g' | grep -oE '"name":"[^"]*"|"ruleCount":[0-9]+'

# 强制刷新单个规则集（改规则后不用重启）
curl -s -X PUT -H "Authorization: Bearer $PW" \
     http://127.0.0.1:9090/providers/rules/<规则集名>

# 某设备的流量走向
grep "10.1.2.33" /tmp/openclash.log | sed 's/.*--> //' \
  | sed 's/:[0-9]* match / | /' | sort | uniq -c | sort -rn

# 找出走漏网之鱼的域名（排除纯 IP）
grep "match Match" /tmp/openclash.log | sed 's/.*--> //' | sed 's/:[0-9]* match.*//' \
  | grep -vE '^[0-9.]+$' | sort | uniq -c | sort -rn

# 连接的完整链路（判断真实出口）
curl -s -H "Authorization: Bearer $PW" http://127.0.0.1:9090/connections \
  | sed 's/},{/}\n{/g' | grep "10.1.2.33" \
  | grep -oE '"host":"[^"]*"|"chains":\[[^]]*\]'

# 节点失败率（业务请求比探测请求更能反映真实情况）
for i in $(seq 1 20); do
  curl -s -H "Authorization: Bearer $PW" \
    "http://127.0.0.1:9090/proxies/<节点名urlencoded>/delay?timeout=8000&url=https%3A%2F%2Faweme.snssdk.com%2F"
done

# 内核层看有无绕过 Clash 的连接
grep "src=10.1.2.33" /proc/net/nf_conntrack | grep -c "sport=7892"   # 经 TPROXY
grep "src=10.1.2.33" /proc/net/nf_conntrack | grep -c "dst=198.18."  # 走 fake-ip
```

---

## 方法论：遇到 OpenClash / subconverter 的问题先查文档

今天有三次因为凭推断下结论而走了弯路：

1. 错判「ruleset 行的 `,3600` interval 无效」并 revert——**实际是官方语法**，
   只在 provider 模式下才输出，当时处于内联展开模式所以看着无效
2. 错判「Clash 直连拉不到 raw.githubusercontent.com」而主张全量改 jsDelivr——
   **实测直连正常**，探针验证 200/0.68s
3. 凭空猜测 rule-provider 名称（`CO_wechat_rule (Domain)`），导致 Clash 启动失败

**权威来源**：

- OpenClash 官方手册（唯一，GitHub 无独立 wiki 页）：
  `https://raw.githubusercontent.com/vernesong/OpenClash/dev/.github/skills/openclash-user-guide/SKILL.md`
- subconverter 中文文档：
  `https://raw.githubusercontent.com/tindy2013/subconverter/master/README-cn.md`
- mihomo 规则集文档：`https://wiki.metacubex.one/config/rule-providers/`
- 路由器本地源码：`/usr/share/openclash/*.sh`、`/etc/init.d/openclash`

> WebFetch 访问 github.com 会被网络策略拦截，用 `curl` 拉 raw 地址。
> 手册本身也有错漏（如覆写脚本的执行时机描述与源码不符），**以源码为准**。
