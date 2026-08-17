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

echo ""
echo "=== 生效确认 ==="
echo "  设备1 规则: $(grep -cE "^- AND,\(\(SRC-IP-CIDR,$OPS_IP1/32\)" $D/openclash_custom_rules.list) 条"
echo "  设备2 规则: $(grep -cE "^- AND,\(\(SRC-IP-CIDR,$OPS_IP2/32\)" $D/openclash_custom_rules.list) 条"
echo "  设备2 兜底: $(grep -cE "^- SRC-IP-CIDR,$OPS_IP2/32," $D/openclash_custom_rules_2.list) 条"
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
