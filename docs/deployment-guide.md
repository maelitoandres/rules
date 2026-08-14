# 部署指南 — 本地 subconverter + OpenClash

面向三地办公室（🇨🇳 中国 / 🇺🇸 美国 / 🇨🇴 哥伦比亚）的 iStoreOS 旁路由。
中国办公室已按此流程部署完成并验证通过（2026-08-14）。

---

## 0. 为什么要本地 subconverter

不用公共转换服务（如 `api.dler.io`）的三个理由：

1. **凭证外泄** —— 公共服务会完整看到你的订阅链接和全部节点凭证；
2. **静默丢字段** —— 实测 `api.dler.io` 会吃掉 `dialer-proxy`（桥接直接失效，且无任何报错）；
3. **单点故障** —— 三地共用一个第三方服务，它挂了三地同时停更。

---

## 1. 前置条件

| 项 | 要求 | 中国办公室实际 |
|---|---|---|
| 系统 | OpenWrt / iStoreOS | iStoreOS 24.10.8 x86_64 |
| Docker | 已安装并运行 | 27.3.1 |
| 内存 | ≥ 512 MB 空闲 | 16 GB（空闲 15.2 GB） |
| 磁盘 | ≥ 200 MB | Docker 目录可用 1.8 GB |
| OpenClash | 已安装 | luci-app-openclash 0.47.156 |

---

## 2. 部署 subconverter

### ⚠️ 必须使用 fork 版镜像

官方版 `tindy2013/subconverter` **不支持 VLESS**，转换时会**静默丢弃全部 VLESS 节点**（面板上不会有任何报错，你只会发现节点少了）。实测对比：

| 镜像 | 版本 | VLESS Reality | `dialer-proxy` |
|---|---|---|---|
| `tindy2013/subconverter` | v0.9.0 | ❌ 4 个节点全丢 | — |
| **`asdlokj1qpi23/subconverter`** | **v0.9.9** | ✅ 保留 | ✅ 保留 |

### 部署命令

```bash
docker pull asdlokj1qpi23/subconverter:latest

docker run -d --name subconverter --restart always \
  --dns 223.5.5.5 --dns 119.29.29.29 \
  -p 127.0.0.1:25500:25500 \
  asdlokj1qpi23/subconverter:latest
```

**两个参数都不能省：**

- **`--dns`** —— Docker 默认网桥不继承宿主机 DNS。缺了它容器内无法解析域名，转换会返回 `No nodes were found!`，日志里是 `Could not resolve host`。
- **`-p 127.0.0.1:25500`** —— 只绑本机。不要绑 `0.0.0.0`，否则局域网内任何设备都能用你的转换服务。

### ❌ 不要挂载 pref.toml

曾尝试挂载自定义 `pref.toml` 来调低缓存，结果**整套配置被 subconverter 的默认模板覆盖**——策略组变成 `NETFLIX`/`广告拦截`/`运营劫持` 那一套，节点只剩 2 个。

原因：容器内的 `/base/pref.toml` 实际是 `pref.example.toml` 的副本，里面自带 `snippets/groups.toml` 定义的 13 个默认组，会**覆盖 URL 传入的 `config` 参数**。

如需清缓存，用命令而不是挂载：

```bash
docker exec subconverter sh -c "rm -rf /base/cache/*" && docker restart subconverter
```

### 验证

```bash
curl -s http://127.0.0.1:25500/version
# 期望：subconverter v0.9.9-xxxxx backend

# 容器内域名可达性（四个都应返回 200/301/404，不能是解析失败）
for h in jmssub.net raw.githubusercontent.com gist.githubusercontent.com testingcf.jsdelivr.net; do
  docker exec subconverter wget -q -O /dev/null -S "https://$h" 2>&1 | grep -oE "HTTP/[0-9.]+ [0-9]+" | head -1
done
```

---

## 3. 配置 OpenClash

### 3.1 三处地址

| 项 | 值 |
|---|---|
| **订阅地址** | `<JMS Mihomo/Clash.Meta YAML 订阅>` + `\|` + `<BD 节点 gist raw 链接>` |
| **转换地址** | `http://127.0.0.1:25500/sub` |
| **模板地址** | `https://cdn.jsdelivr.net/gh/maelitoandres/rules@main/cfg/<地区>.ini` |

模板按办公室选择：`cn.ini` / `us.ini` / `co.ini`。**订阅地址三地完全相同**，差异只在模板。

> ⚠️ **模板必须用 `cdn.jsdelivr.net`，不要用 `testingcf.jsdelivr.net`。**
>
> testingcf 虽然国内快 7 倍（0.8s vs 5.7s），但它是测试镜像、有独立缓存层，**`purge.jsdelivr.net` 清不掉**——改完 ini 后长达 12 小时仍返回旧版，subconverter 拿到的是过期模板，新加的 ruleset 静默消失，而面板上一切正常。定位这个问题曾耗掉一整晚。
>
> 模板是低频、小体积请求，5.7 秒完全可接受。规则文件（`rule/*.list`）走 raw 地址，不受此影响，改完立即生效。

> `|` 是 subconverter 的多订阅源合并语法，JMS 节点由官方订阅提供（自动跟进 IP/参数变更），BD 的 socks5 节点手写在 gist 里。
>
> gist 链接**不要带 commit hash**——带 hash 的是快照，改了 gist 也不会更新。用 `.../raw/proxy.yaml` 这种形式。

### 3.2 必须调整的开关

```bash
# 关闭 emoji 重写（见 §5.2）
uci set openclash.@config_subscribe[0].emoji='false'

# 启用自定义规则（否则 openclash_custom_rules.list 根本不会被读取）
uci set openclash.config.enable_custom_clash_rules='1'

# API 密码换成强密码（默认是 123456，且端口对整个局域网开放）
uci set openclash.config.dashboard_password='<强密码>'

uci commit openclash
```

> `external-controller` 无法改为 `127.0.0.1`——LuCI 的面板入口是让**浏览器直连** `路由器IP:9090`，改了就打不开 yacd。只能靠强密码防护。

### 3.3 fake-ip-filter 调整

若需要按域名劫持微信（见 §4.2），必须移除 `+.qq.com`：

```bash
F=/etc/openclash/custom/openclash_custom_fake_filter.list
cp $F ${F}.bak-$(date +%s)
sed -i "s|^+\.qq\.com$|# +.qq.com|" $F
```

**原因**：在 filter 里的域名走真实 DNS、拿到真实 IP，Clash 只看得到 IP 看不到域名，**基于域名的 `RULE-SET` 规则永远匹配不上**。

前面那 9 条 QQ 音乐的精确条目要保留，只注释通配的 `+.qq.com`。

### 3.4 ⚠️ 嗅探器必须开启 override-destination

**这一项不改，运营 IP 的效果会时灵时不灵。**

```bash
F=/etc/openclash/custom/openclash_custom_sniffer.yaml
cp $F ${F}.bak-$(date +%s)
sed -i "s|^  override-destination: false|  override-destination: true|" $F
/etc/init.d/openclash restart
```

**为什么必须改**：OpenClash 默认的自定义嗅探配置里，全局 `override-destination` 是 `false`（只有 HTTP 段单独设为 true）。它的含义是「嗅探到域名后**不用它重新匹配规则**」。

于是当 app 用缓存的真实 IP 直接发起 TLS 连接时：

```
匹配规则的瞬间 Clash 手上只有 IP → 所有域名规则落空
  → 一路掉到最后的 GEOIP,CN → 走了直连
  → 之后嗅探器才从 SNI 读出域名，但走向已成定局
  → 监控里显示成「这个域名走了 DIRECT」，看起来像规则顺序错了
```

中国办公室实测：改之前字节系有 **9 个域名**走直连（抖音评论的 IP 属地因此忽变忽不变），改之后**降到 0**。

覆盖范围：TLS/QUIC/HTTP 有 SNI 或 Host 头的连接都能救回；纯 TCP 无 SNI、或启用了 ECH 的连接仍无法还原域名。

### 3.5 本地配置项清单（**不随仓库同步，每地必须手动配置**）

仓库里只有 `cfg/*.ini` 和 `rule/*.list`。以下都是路由器本地的文件或 UCI 设置，**OpenClash 不支持从 URL 加载**，另外两地部署时必须逐项配置：

| 配置项 | 位置 | 值 | 作用 |
|---|---|---|---|
| 嗅探重定向 | `custom/openclash_custom_sniffer.yaml` | `override-destination: true` | 见 §3.4，**最关键** |
| fake-ip 过滤 | `custom/openclash_custom_fake_filter.list` | 注释掉 `+.qq.com` | 微信域名规则才能匹配 |
| 自定义规则 | `custom/openclash_custom_rules.list` | 微信 AND 劫持规则 | 见 §4.2 |
| 自定义规则开关 | `uci openclash.config.enable_custom_clash_rules` | `1` | 默认 0，不开则上一项完全不生效 |
| emoji 处理 | `uci openclash.@config_subscribe[0].emoji` | `false` | 配合 ini 里的 rename 保留国旗 |
| API 密码 | `uci openclash.config.dashboard_password` | 强密码 | 默认 `123456` 且端口对局域网开放 |
| 自动清缓存钩子 | `custom/openclash_custom_overwrite.sh` | 见 §6.2.2 | 手动 restart 时自动拉取最新规则 |

一次性配置命令：

```bash
# 嗅探
sed -i "s|^  override-destination: false|  override-destination: true|" \
  /etc/openclash/custom/openclash_custom_sniffer.yaml
# fake-ip
sed -i "s|^+\.qq\.com$|# +.qq.com|" \
  /etc/openclash/custom/openclash_custom_fake_filter.list
# UCI
uci set openclash.config.enable_custom_clash_rules='1'
uci set openclash.@config_subscribe[0].emoji='false'
uci set openclash.config.dashboard_password='<强密码>'
uci commit openclash
/etc/init.d/openclash restart
```

---

## 4. 运营 WiFi（可选，仅需要 IP 属地伪装时）

### 4.1 网络层

**主路由（UCG-Fiber）侧：**

1. 新建 Network，VLAN ID 自定（中国办公室用 `2`），网段如 `10.1.9.0/24`
2. Gateway IP 填 UCG 自己的地址（如 `10.1.9.1/24`，它会强制要求）
3. **DHCP 里把默认网关和 DNS 都指向旁路由**（如 `10.1.9.2`）
4. 新建 SSID 绑定该 VLAN
5. 确认旁路由所在端口放行该 VLAN 的 tagged 帧

**旁路由侧：**

```bash
# VLAN 子接口（vid 要和 UCG 上的一致）
uci set network.vlan9=device
uci set network.vlan9.type='8021q'
uci set network.vlan9.ifname='br-lan'
uci set network.vlan9.vid='2'
uci set network.vlan9.name='br-lan.2'

# 接口地址（即该网段的网关）
uci set network.colombia=interface
uci set network.colombia.device='br-lan.2'
uci set network.colombia.proto='static'
uci set network.colombia.ipaddr='10.1.9.2'
uci set network.colombia.netmask='255.255.255.0'

# 纳入 lan zone（继承 ACCEPT + masq）
uci add_list firewall.@zone[0].network='colombia'

# DHCP 交给 UCG，本机只提供 DNS 和网关
uci set dhcp.colombia=dhcp
uci set dhcp.colombia.interface='colombia'
uci set dhcp.colombia.ignore='1'

uci commit; /etc/init.d/network reload; /etc/init.d/firewall reload
```

**关键点：网关必须与客户端同网段。** UCG 上填 `10.1.9.2` 作为网关是可行的，前提是旁路由在该网段真的有这个地址——这正是上面 VLAN 接口的作用。跨网段的网关客户端 ARP 不到，包发不出去。

**TPROXY 无需任何改动** —— OpenClash 的规则挂在 `mangle_prerouting` / `dstnat` hook 上且不绑定接口，新网段的流量会自动被接管。

### 4.2 微信劫持规则

写入 `/etc/openclash/custom/openclash_custom_rules.list`：

```yaml
rules:
- AND,((SRC-IP-CIDR,10.1.9.0/24),(RULE-SET,WeChat)),💬 微信运营
```

效果分层：运营 WiFi 的微信 → 🇨🇴 节点（属地显示哥伦比亚）；其他设备的微信 → 各自策略组不受影响；运营设备的其他 app → 照常走全局策略。

> `AND` 复合规则**必须写在这里**，不能写进 ini——subconverter 会把它的语法解析坏（策略组名被插到括号里、后半段被截断）。单条 `SRC-IP-CIDR` 则可以正常透传。

---

## 5. 部署后验证

```bash
# ① 节点数与策略组数
sed -n '/^proxies:/,/^proxy-groups:/p' /etc/openclash/统一节点管理.yaml | grep -cE '^- name:'
sed -n '/^proxy-groups:/,/^rule-providers:/p' /etc/openclash/统一节点管理.yaml | grep -c '^- name:'

# ② 关键字段是否保留（VLESS Reality 与桥接）
for k in vless reality-opts dialer-proxy socks5; do
  printf "%-16s %s\n" "$k" "$(grep -c "$k" /etc/openclash/统一节点管理.yaml)"
done

# ③ 自定义规则是否在 rules 最前
sed -n '/^rules:/,+2p' /etc/openclash/统一节点管理.yaml

# ④ 节点可用性（含桥接）
SEC=$(uci get openclash.config.dashboard_password)
curl -s -H "Authorization: Bearer $SEC" \
  "http://127.0.0.1:9090/proxies/<URL编码的节点名>/delay?timeout=8000&url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"
```

中国办公室的基准值：节点 5、策略组 40、`vless`/`reality-opts`/`dialer-proxy`/`socks5` 各 2。

---

## 6. 故障排查（实际踩过的坑）

### 6.1 改了 ini 却不生效

**三层缓存，逐层排查：**

| 层 | 时长 | 清除方式 |
|---|---|---|
| GitHub raw CDN | ~5 分钟 | 无法控制，只能等；急用时改用 commit hash 的 URL |
| subconverter | `cache_config` 默认 300s | `docker exec subconverter sh -c "rm -rf /base/cache/*" && docker restart subconverter` |
| OpenClash | 需手动触发 | 见下 |

### 6.2 改了东西不生效？先分清改的是哪一层

这是本项目**最容易浪费时间的地方**，务必按下表对号入座：

| 你改了什么 | 需要做什么 | 为什么 |
|---|---|---|
| **`rule/*.list`**（规则内容） | 清 provider 缓存 + `/etc/init.d/openclash restart` | provider 的 URL 没变，变的是 URL 背后的内容；主配置无需重新生成 |
| **`cfg/*.ini`**（策略组结构） | 界面点「更新订阅」重新生成主配置 | 策略组、规则映射都写在主配置里 |
| 自定义规则 / UCI 开关 | `/etc/init.d/openclash restart` | 由 `yml_rules_change.sh` 在启动流程中注入 |

**三个命令的实际职责**：

```
界面「更新订阅」/ openclash.sh   → 调 subconverter 重新【生成主配置】
/etc/init.d/openclash restart    → 重启服务：重载配置 + 注入自定义规则 + 重新拉取缺失的 provider
/etc/init.d/openclash reload     → 仅重载，【不走 start_service】← 定时更新订阅走的是这条
```

⚠️ **最后一条尤其要注意**：cron 里的定时更新订阅走 `reload`，**不会触发 `start_service`**，因此挂在启动流程上的自定义脚本（如覆写钩子）在定时更新时不会执行。

### 6.2.1 rule-provider 有独立的 24 小时缓存

改了 `rule/*.list` 后最容易踩的坑：

```yaml
rule-providers:
  CO_social_rule:
    url: http://127.0.0.1:25500/getruleset?...
    path: ./rule_provider/5496933961057482693.yaml
    interval: 86400          ← 一天才更新一次
```

Clash 把规则**加载在内存里**，删掉 `rule_provider/*.yaml` 也不影响它继续运行，但同样不会主动重读。所以必须：

```bash
rm -rf /etc/openclash/rule_provider/*
/etc/init.d/openclash restart      # 启动时发现文件缺失 → 重新拉取
```

> `interval` 由 subconverter 的服务端配置（`pref.toml` 的 `[[rulesets]]` 段）决定，**外部 ini 无法控制**——在 `ruleset=` 后加 `,3600` 实测无效。

### 6.2.2 自动清缓存的覆写钩子

`/etc/openclash/custom/openclash_custom_overwrite.sh` 在「配置生成后、Clash 启动前」执行，可在此自动清缓存：

```bash
LOG_OUT "Tip: Clearing subconverter and rule-provider cache..."
docker exec subconverter sh -c "rm -rf /base/cache/*" >/dev/null 2>&1
rm -rf /etc/openclash/rule_provider/* >/dev/null 2>&1
```

**生效范围**：手动 `restart` 时有效（已实测）；定时更新订阅走 `reload`，**不会触发**。所以它是「手动验证时的加速器」，不是「全自动方案」。

### 6.3 节点名的 emoji 丢失

subconverter 的 `emoji` 参数语义是「**先剥掉原有的**，再决定要不要按内置规则重加」，不是「保留原样」：

- `emoji=true` → 剥掉后按名字猜国家重加，「日本中转」会被猜成 🇯🇵，出现 `🇯🇵 🇺🇸 日本中转` 双国旗
- `emoji=false` → 剥掉且不重加，订阅源自带的 🇨🇴 就没了

**解法：`emoji=false` + 用 `rename` 补国旗**（rename 在 emoji 处理之后执行，写什么是什么）：

```ini
rename=JMS.*c55s3\..*@🇺🇸 CN2GIA
rename=^社媒$@🇨🇴 社媒
```

### 6.4 策略组里出现意外的 DIRECT

subconverter 对 `select` 组会自动补 `DIRECT` 且排在**首位**（即默认选中）。对运营组来说这意味着流量默认从本地真实 IP 出去。

**解法：显式指定兜底项**

```ini
custom_proxy_group=🇺🇸 快线`select`(🇺🇸|CN2GIA|日本中转|直连备用)`[]REJECT
```

用 `REJECT` 而非 `DIRECT`：误选时连接立即失败、能马上发现，而不是静默泄露 IP。

### 6.5 某个 app 走错策略组

**规则先匹配先生效。** 若一个规则文件同时含多个 app 的域名，它只能指向一个策略组，排在后面的同类规则永远轮不到。

实例：`CO_social_rule.list` 里含 `weibo.com`，而它当时指向「🎶 抖音」组 → 打开微博走进了抖音组。

**解法**：把「补充/兜底」性质的规则文件排到所有 app 规则**之后**，指向独立的兜底组。

### 6.6 yacd 看不到某个 app 的连接

先确认 DNS 是否返回 fake-ip：

```bash
nslookup -port=7874 <域名> 127.0.0.1
```

- 返回 `198.18.x.x` → 走 Clash，正常
- 返回真实 IP → 该域名被判定为直连

配置里 `respect-rules: true` 会让 DNS **遵循规则的最终走向**：某域名对应的策略组当前若选中 `DIRECT`，就直接返回真实 IP、不给 fake-ip，流量在防火墙层就被 `china_ip_route` 放行了，自然不进 Clash。

**从路由器本机测试会有偏差**（源 IP 是 `127.0.0.1`，规则判定不同）。准确的做法是经 Clash 实际发包：

```bash
curl -x http://127.0.0.1:7893 -s -o /dev/null https://<域名> &
sleep 3
curl -s -H "Authorization: Bearer $SEC" http://127.0.0.1:9090/connections \
  | tr '{' '\n' | grep -i <关键字> | grep -oE '"host":"[^"]*"|"chains":\[[^]]*\]'
```

### 6.7 某 app 的出口 IP 时灵时不灵

典型症状：抖音评论的 IP 属地一会儿是哥伦比亚、一会儿是真实属地；监控里**同一个域名出现多条不同链路**：

```
webcast-core-m.amemv.com    DIRECT ← 🎯 全球直连
webcast-core-m.amemv.com    🇨🇴 社媒 ← 🎶 抖音
```

**这不是规则顺序问题**（先核对一下：`RULE-SET,DouYin` 的行号一定远小于 `GEOIP,CN`）。真正原因是 **§3.4 的 `override-destination`**——app 用缓存 IP 建连时匹配不到域名规则，掉到了 `GEOIP,CN`。按 §3.4 改完即可。

若改完仍有个别域名落进「🐟 漏网之鱼」，说明那些域名没被任何规则覆盖，补进 `CO_social_rule.list` 即可。注意用 **`DOMAIN-KEYWORD`** 而非逐个写后缀——字节系惯用整个域名系列（`bytedns` / `bytedns1` / `bytedns3` / `bytednsdoc`…），逐个补永远补不完。

### 6.8 重置 JMS 凭证后节点全部失效

**JMS 订阅链接里的 `id` 参数就是 UUID 本身**，后台重置 UUID 时链接会一起失效：

```
旧链接返回: HTTP 200 但只有 22 字节，内容为 "Invalid parameters"
→ subconverter 拿到 0 个节点
→ 配置里只剩 gist 的 BD 节点 → Clash 无可用出口
```

**必须回 JMS 后台重新复制订阅链接**，然后更新 OpenClash 的订阅地址（保留 `|gist` 部分）。

⚠️ 这一步会引发**死锁**：没有节点 → 访问不了 `raw.githubusercontent.com` → 拉不到 ini → 生成不了配置。

**因此 ini 必须托管在 jsDelivr**（见 §3.1）。实测无代理时的可达性：

```
jmssub.net        ✅ 可达      gist.github  ✅ 可达
jsdelivr(CN优化)  ✅ 可达      raw.github   ❌ 不可达
```

只要 ini 在 jsDelivr 上，换个订阅链接就能直接恢复，无需停 Clash 或还原备份。

### 6.9 区分「配置损坏」与「凭证失效」

两者症状不同，处理方式完全相反：

| 症状 | 判断 | 处理 |
|---|---|---|
| Clash 起不来、配置为空 | 配置损坏 | `cp` known-good 备份 + restart |
| **配置正常、策略组都在，但节点全连不上** | **凭证失效** | **去服务商后台复制新订阅链接** |

**关键区分点：看策略组还在不在。** 策略组正常只是节点连不上 → 别浪费时间恢复备份。

---

## 7. 三地部署差异

| | 🇨🇳 中国 | 🇺🇸 美国 | 🇨🇴 哥伦比亚 |
|---|---|---|---|
| 模板 | `cn.ini` | `us.ini` | `co.ini` |
| 国际服务默认 | 🇺🇸 冲浪快线 | DIRECT | DIRECT |
| 美国服务默认 | 🇺🇸 快线 | DIRECT | 🇺🇸 快线 |
| 中国服务 | DIRECT | 回国节点 ⚠️ | 回国节点 ⚠️ |
| socks5 桥接 | **必须**（GFW） | 建议保留（一致性） | 建议保留 |
| 运营 WiFi | 已部署 | 按需 | 按需 |

⚠️ 尚无中国落地节点，该组暂为 DIRECT，补节点后在 ini 填一行即可。

订阅地址、gist、subconverter 部署方式三地完全一致，**只需改模板地址**。

---

## 8. 救急恢复

配置损坏且无代理可用时会陷入死锁（Clash 起不来 → 没代理 → subconverter 拉不到 GitHub）。因此每地都应保留一份可用配置：

```bash
mkdir -p /root/openclash-known-good
cp /etc/openclash/统一节点管理.yaml /root/openclash-known-good/
```

恢复：

```bash
cp /root/openclash-known-good/统一节点管理.yaml /etc/openclash/
/etc/init.d/openclash restart
```

配置直接可用，网络恢复后再更新订阅回到最新状态。

> 模板地址已用 `cdn.jsdelivr.net`（国内直连可达），死锁只影响规则文件的 raw 地址。规则有本地缓存（`interval: 86400`），断网期间沿用旧副本，不影响启动。

---

## 改完 ini 后必做：清 CDN 缓存

`@main` 引用在 jsDelivr 上缓存 12 小时。改完 ini 推送后**必须 purge**，否则 subconverter 拿到的还是旧模板，改动看似生效实则没进配置：

```bash
for f in cfg/cn.ini cfg/us.ini cfg/co.ini; do
  curl -s "https://purge.jsdelivr.net/gh/maelitoandres/rules@main/$f" | grep -o '"status":"[^"]*"'
done
# 期望输出三行 "status":"finished"
```

purge 后立即验证拿到的确实是新版：

```bash
curl -s "https://cdn.jsdelivr.net/gh/maelitoandres/rules@main/cfg/cn.ini" | grep -c '<你新加的关键字>'
```

**返回 0 就是缓存还没散**，此时更新订阅只会重新生成旧配置。改规则文件（`rule/*.list`）无需 purge——它们走 raw 地址。

---

## 触发订阅更新的正确命令

面板「更新」按钮之外，命令行只有一条真正会重新生成配置：

| 命令 | 行为 |
|---|---|
| `/usr/share/openclash/openclash.sh` | ✅ 下载订阅 → subconverter 转换 → 生成配置 → 重启 |
| `/etc/init.d/openclash reload` | ❌ 只重载现有配置，不下载 |
| `/usr/share/openclash/openclash_update.sh` | ❌ 直接调用无效果 |

```bash
nohup /usr/share/openclash/openclash.sh >/tmp/gen.log 2>&1 &
sleep 100
date -r /etc/openclash/统一节点管理.yaml   # 时间没变 = 没生成成功
```

另外，OpenClash 用 etag 判断订阅是否变化，**只改模板不改订阅地址时会提示「配置文件没有更新，停止继续操作」**。给订阅 URL 加个无害参数（`?v=2` → `?v=3`）即可绕过。
