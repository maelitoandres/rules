#!/bin/sh
# openclash-setup.sh —— OpenClash 本地配置项的统一部署
#
# ★ 解决的问题:
#   仓库里的 cfg/ 与 rule/ 通过订阅和 provider 自动同步到三地，
#   但 OpenClash 的【自定义规则】只能读本地文件，不支持从 URL 加载。
#   这些规则（运营设备的 AND 绑定）此前只存在于中国办公室的路由器上，
#   其他地点部署时得照着文档手敲，容易漏。
#
#   本脚本把规则内容也纳入仓库（local/ 目录），部署时拉取安装 ——
#   仓库仍是唯一源，只是同步方式从「provider 拉取」变成「脚本部署」。
#
# ★ 为什么 AND 规则不能做成 rule-provider（2026-08-17 实测）:
#     AND + DOMAIN-SUFFIX / IP-CIDR  → ✅ provider 接受
#     AND + RULE-SET（嵌套 provider）→ ❌ 静默丢弃，ruleCount 不变且无报错
#   推测是加载时序问题: provider 解析自身内容时，其引用的其他 provider
#   尚未就绪。而全部 28 条 AND 规则都靠 RULE-SET 复用规则集，故走不通。
#
# 用法:
#   sh openclash-setup.sh                         用默认设备 IP
#   OPS_IP1=10.2.2.33 OPS_IP2=10.2.2.34 sh openclash-setup.sh
#
#   OPS_IP1 = 运营设备1（社媒 app 走专属出口，其余流量走本地）
#   OPS_IP2 = 运营设备2（全部流量走专属出口，专机专用）
#
#   默认只装规则文件与嗅探/fake-ip 配置，【不碰】UCI 设置。
#   SYNC_UCI=1 sh openclash-setup.sh              额外同步 UCI 配置（300+ 项）
#   DRY_RUN=1 SYNC_UCI=1 sh openclash-setup.sh    只预览 UCI 会改什么，不写入
#
# 幂等: 可重复执行。安装前备份，安装后校验，失败自动回滚。

set -u

REPO="https://raw.githubusercontent.com/maelitoandres/rules/main"
D=/etc/openclash/custom
BK="/root/openclash-custom-backup-$(date +%Y%m%d-%H%M%S)"

OPS_IP1="${OPS_IP1:-10.1.2.33}"
OPS_IP2="${OPS_IP2:-10.1.2.34}"

echo "=== OpenClash 本地配置部署 ==="
echo "  运营设备1: $OPS_IP1"
echo "  运营设备2: $OPS_IP2"

[ -d "$D" ] || { echo "❌ $D 不存在，OpenClash 未安装？"; exit 1; }

mkdir -p "$BK"
for f in openclash_custom_rules.list openclash_custom_rules_2.list; do
  [ -f "$D/$f" ] && cp "$D/$f" "$BK/$f"
done
echo "  备份 → $BK"

rollback() {
  echo "  ⚠️ $1，回滚中…"
  for f in openclash_custom_rules.list openclash_custom_rules_2.list; do
    [ -f "$BK/$f" ] && cp "$BK/$f" "$D/$f"
  done
  echo "  已回滚"
  exit 1
}

for f in openclash_custom_rules.list openclash_custom_rules_2.list; do
  T="/tmp/_ocs_$f"
  CODE=$(curl -s -o "$T" --max-time 40 -w "%{http_code}" "$REPO/local/$f" 2>/dev/null)
  [ "$CODE" = "200" ] || rollback "拉取 $f 失败 (HTTP $CODE)"
  [ -s "$T" ] || rollback "$f 内容为空"

  # 占位符替换
  sed -i "s|@@OPS_IP1@@|$OPS_IP1|g; s|@@OPS_IP2@@|$OPS_IP2|g" "$T"
  grep -q "@@OPS_IP" "$T" && rollback "$f 仍有未替换的占位符"

  # 校验: 必须以 rules: 开头，且没有残留的模板标记
  head -1 "$T" | grep -q "^rules:" || rollback "$f 格式异常（首行不是 rules:）"

  cp "$T" "$D/$f"
  N=$(grep -cE "^- " "$D/$f")
  printf "  %-32s → %s 条规则\n" "$f" "$N"
  rm -f "$T"
done


# ══════════════════════════════════════════════════════════════
# 嗅探器: override-destination 必须为 true
# ══════════════════════════════════════════════════════════════
# OpenClash 默认全局 override-destination 是 false（只有 HTTP 段单独 true）。
# 它的含义是「嗅探到域名后不用它重新匹配规则」。于是当 app 用缓存的真实 IP
# 直接发起 TLS 连接时，Clash 匹配规则的瞬间手上只有 IP，所有域名规则落空，
# 一路掉到 GEOIP,CN 走了直连 —— 监控里显示成「这个域名走了 DIRECT」，
# 看起来像规则顺序错了，实际是嗅探结果没被采纳。
#
# 中国办公室实测: 改之前字节系有 9 个域名走直连（抖音评论属地因此忽变忽不变），
# 改之后降到 0。这一项不改，运营 IP 的效果会时灵时不灵。
#
# ⚠️ 只改全局那一处（sniffer: 下第一层），HTTP 段里的本来就是 true。
S=$D/openclash_custom_sniffer.yaml
if [ -f "$S" ]; then
  cp "$S" "$BK/openclash_custom_sniffer.yaml"
  if grep -qE "^  override-destination: false" "$S"; then
    sed -i "s|^  override-destination: false|  override-destination: true|" "$S"
    echo "  嗅探 override-destination: false → true"
  else
    echo "  嗅探 override-destination 已是 true，跳过"
  fi
  # parse-pure-ip 让无域名的纯 IP 连接也被嗅探，配合上一项才完整
  if grep -qE "^  parse-pure-ip: false" "$S"; then
    sed -i "s|^  parse-pure-ip: false|  parse-pure-ip: true|" "$S"
    echo "  嗅探 parse-pure-ip: false → true"
  fi
else
  echo "  ⚠️ 未找到 $S，跳过嗅探配置"
fi

# ══════════════════════════════════════════════════════════════
# fake-ip filter: 必须移除通配的 +.qq.com
# ══════════════════════════════════════════════════════════════
# 在 fake-ip-filter 里的域名走真实 DNS、拿到真实 IP，Clash 只看得到 IP
# 看不到域名，基于域名的 RULE-SET 规则永远匹配不上 —— 微信的分流会整个失效。
# 前面那 9 条 QQ 音乐的精确条目要保留，只注释通配的那条。
F=$D/openclash_custom_fake_filter.list
if [ -f "$F" ]; then
  cp "$F" "$BK/openclash_custom_fake_filter.list"
  if grep -qE "^\+\.qq\.com$" "$F"; then
    sed -i "s|^+\.qq\.com$|# +.qq.com  # 已移除: 微信需走 fake-ip 才能匹配域名规则（回滚: 删掉行首的 # ）|" "$F"
    echo "  fake-ip filter: 已注释 +.qq.com"
  else
    echo "  fake-ip filter: +.qq.com 已处理，跳过"
  fi
else
  echo "  ⚠️ 未找到 $F，跳过 fake-ip filter 配置"
fi

# ══════════════════════════════════════════════════════════════
# UCI 配置同步（插件设置 / 覆写设置）
# ══════════════════════════════════════════════════════════════
# 从仓库拉取 local/openclash-uci.conf 并应用 —— 该文件由任一地点跑
# openclash-export.sh 生成。这样在地点 A 用 LuCI 调好的设置，
# 其他地点跑本脚本即可同步，不必逐项对照文档手敲。
#
# ⚠️ 以下项【不会】被同步（导出时已排除，各地本地维护）:
#     dashboard_password                       API 密码
#     @config_subscribe[].address              订阅地址，含凭证
#     @config_subscribe[].custom_template_url  三地分别指向 cn/us/co.ini
#     @config_subscribe[].name
#
# ⚠️ 默认【关闭】。UCI 同步会改动 300+ 项配置，风险远高于装规则文件，
#    需显式 SYNC_UCI=1 才执行。首次在新地点使用请先跑 DRY_RUN=1 看清改什么。
if [ "${SYNC_UCI:-0}" != "1" ]; then
  echo "  UCI 同步: 未启用（需 SYNC_UCI=1；建议先用 DRY_RUN=1 预览）"
else
  U=/tmp/_ocs_uci.conf
  CODE=$(curl -s -o "$U" --max-time 40 -w "%{http_code}" "$REPO/local/openclash-uci.conf" 2>/dev/null)
  if [ "$CODE" != "200" ] || [ ! -s "$U" ]; then
    echo "  ⚠️ UCI 配置拉取失败 (HTTP $CODE)，跳过同步（规则文件已装好）"
  else
    uci export openclash > "$BK/openclash-uci-before.conf" 2>/dev/null
    CHANGED=0

    # ── @dns_servers: 先清空再重建，避免各地条目数不同导致错位 ──
    WANT_DNS=$(grep -c "@dns_servers" "$U")
    if [ "${DRY_RUN:-0}" = "1" ]; then
      HAVE_DNS=$(uci show openclash 2>/dev/null | grep -c "@dns_servers.*\.ip=")
      echo "  [dry-run] @dns_servers: 现有 $HAVE_DNS 组 → 将按仓库重建"
    elif [ "$WANT_DNS" -gt 0 ]; then
      while uci -q delete openclash.@dns_servers[-1] 2>/dev/null; do :; done
      IDX=-1
      grep "^openclash\.@dns_servers\[" "$U" | while IFS= read -r line; do
        N=$(echo "$line" | sed -E "s/^openclash\.@dns_servers\[([0-9]+)\].*/\1/")
        K=$(echo "$line" | sed -E "s/^[^.]+\.[^.]+\.([^=]+)=.*/\1/")
        V=$(echo "$line" | cut -d= -f2- | tr -d "\047\r")
        if [ "$N" != "$IDX" ]; then uci -q add openclash dns_servers >/dev/null; IDX=$N; fi
        uci -q set "openclash.@dns_servers[-1].$K=$V"
      done
      echo "  UCI @dns_servers: 已重建（$(grep -c '@dns_servers' "$U") 项）"
      CHANGED=1
    fi

    # ── config 与 @config_subscribe: 逐项比对，仅在不同时写入 ──
    # ⚠️ 剥离引号必须用 cut + tr，不要用 sed 的 s/'$// ——
    #    那个 $ 锚点在多层引号嵌套下不可靠（独立脚本里能跑，放进本脚本就失效），
    #    结果是尾引号残留: '1' 变成 1'。后果不是少改一项，而是【每一项都被
    #    判为与当前值不同】而全量重写 —— 2026-08-17 实测 387 项配置全部损坏，
    #    en_mode 变成 fake-ip'、dns_port 变成 7874'。
    #    tr -d "\047" 直接删掉所有单引号，UCI 的值里不含单引号，安全。
    grep -E "^openclash\.(config|@config_subscribe)" "$U" | while IFS= read -r line; do
      K=$(echo "$line" | sed -E "s/=.*//" | tr -d "\r")
      V=$(echo "$line" | cut -d= -f2- | tr -d "\047\r")
      [ -n "$K" ] || continue
      CUR=$(uci -q get "$K" 2>/dev/null)
      [ "$CUR" = "$V" ] && continue
      if [ "${DRY_RUN:-0}" = "1" ]; then
        echo "    [dry-run] $K: ${CUR:-<未设置>} → $V"
      else
        uci -q set "$K=$V" && echo "    $K: ${CUR:-<未设置>} → $V"
      fi
    done
    # ⚠️ uci changes 是累计值，此处已包含上面 @dns_servers 重建产生的变更，
    #    不要写成「config/subscribe 的变更数」—— 会让人误以为改了几百项 config。
    NSET=$(uci -q changes openclash | wc -l)
    [ "$NSET" -gt 0 ] && CHANGED=1
    echo "  UCI 待提交变更合计: $NSET 项（含 @dns_servers 重建）"

    # ── 写入结果抽检: 值里混进引号说明剥离失败，立即回滚 ──
    if [ "${DRY_RUN:-0}" != "1" ] && [ "$NSET" -gt 0 ]; then
      BAD=0
      for k in en_mode proxy_mode dns_port http_port; do
        VAL=$(uci -q get "openclash.config.$k")
        case "$VAL" in *\'*|*\"*) echo "  ❌ $k 的值异常: [$VAL]"; BAD=1 ;; esac
      done
      if [ "$BAD" = "1" ]; then
        echo "  ⚠️ 检测到配置损坏，回滚中…"
        uci -q revert openclash
        cp "$BK/openclash-uci-before.conf" /etc/config/openclash 2>/dev/null
        uci -q commit openclash 2>/dev/null
        echo "  已回滚到 $BK/openclash-uci-before.conf"
        exit 1
      fi
    fi

    if [ "$CHANGED" = "1" ]; then
      uci commit openclash && echo "  UCI 已提交（改动前配置备份于 $BK/openclash-uci-before.conf）"
    else
      echo "  UCI 已与仓库一致，无需变更"
    fi
    rm -f "$U"
  fi
fi

# ── 兜底: 这两项无论 UCI 同步是否执行都必须为真 ──
# enable_custom_clash_rules 默认为 0，不开的话上面装的自定义规则完全不会被读取
# emoji=false 配合 ini 里的 rename 保留国旗（subconverter 的 emoji 语义是
#             「先剥掉原有的」，true 会按名字猜国家重加，出现双国旗）
set_uci() {
  CUR=$(uci -q get "$1")
  if [ "$CUR" != "$2" ]; then
    uci set "$1=$2"; echo "  UCI $1: ${CUR:-未设置} → $2"; uci commit openclash
  fi
}
set_uci openclash.config.enable_custom_clash_rules 1
set_uci openclash.@config_subscribe[0].emoji false

# API 密码不自动设置 —— 需要人工选择强密码
PW=$(uci -q get openclash.config.dashboard_password)
case "$PW" in
  ""|123456) echo "  ⚠️ dashboard_password 仍是默认值，请手动改成强密码:";
             echo "       uci set openclash.config.dashboard_password='<强密码>' && uci commit openclash" ;;
  *) echo "  dashboard_password 已自定义" ;;
esac

echo ""
echo "=== 生效确认 ==="
echo "  设备1 规则: $(grep -cE "^- AND,\(\(SRC-IP-CIDR,$OPS_IP1/32\)" $D/openclash_custom_rules.list) 条"
echo "  设备2 规则: $(grep -cE "^- AND,\(\(SRC-IP-CIDR,$OPS_IP2/32\)" $D/openclash_custom_rules.list) 条"
echo "  设备2 兜底: $(grep -cE "^- SRC-IP-CIDR,$OPS_IP2/32," $D/openclash_custom_rules_2.list) 条"
echo "  嗅探 override: $(grep -cE "^  override-destination: true" $D/openclash_custom_sniffer.yaml 2>/dev/null)"
echo "  fake-ip +.qq.com 已注释: $(grep -cE "^# \+\.qq\.com" $D/openclash_custom_fake_filter.list 2>/dev/null)"
echo ""
echo "✅ 完成。备份保留在 $BK"
echo ""
echo "   下一步（自定义规则要重新生成配置才会插入 rules）:"
echo "     sh /root/preflight.sh            # 先自检"
echo "     rm -f /etc/openclash/config/<配置名>.yaml"
echo "     /usr/share/openclash/openclash.sh"
echo ""
echo "   之后务必确认 (应为 0):"
echo "     grep -c 'Skiped The Custom Rule' /tmp/openclash.log"
