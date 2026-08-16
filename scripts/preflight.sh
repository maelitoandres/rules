#!/bin/sh
# preflight.sh —— 更新订阅前的强制自检
#
# 用途: 改完 ini / gist 之后、执行「更新订阅」之前跑这个。
#       它用 subconverter 干跑一遍转换，校验结果是否合格，
#       不合格就拒绝放行 —— 避免把坏配置写进运行环境。
#
# 背景: 2026-08-17 因为改 ini 后直接更新配置，subconverter 解析失败
#       静默回退默认模板，40 个策略组变成 13 个默认组，服务中断。
#       该脚本把「先验证」这一步固化下来，不依赖人的记性。
#
# 用法: sh /root/preflight.sh          检查当前订阅配置
#       sh /root/preflight.sh <ini_url>  检查指定 ini

set -u

SUB=$(uci get openclash.@config_subscribe[0].address 2>/dev/null)
TPL=${1:-$(uci get openclash.@config_subscribe[0].custom_template_url 2>/dev/null)}
API="http://127.0.0.1:25500"

# 合格标准（按当前架构设定，改架构时同步调整）
MIN_SIZE=20000      # 正常配置约 24000 字节，默认模板约 12000
MIN_GROUPS=35       # 正常 40 个策略组
MIN_NODES=6         # 3 个 JMS + 3 个 Decodo

fail() { echo "❌ $1"; echo ""; echo "拒绝放行 —— 请勿执行更新订阅。"; exit 1; }

echo "=== 前置检查 ==="

# ① 容器活着吗
V=$(curl -s --max-time 10 "$API/version" 2>/dev/null)
[ -z "$V" ] && fail "subconverter 无响应，先查 docker ps 与 docker logs subconverter"
echo "  容器: $V"

# ② ini 拉得到吗
CODE=$(curl -s -o /tmp/_pf.ini --max-time 30 -w "%{http_code}" "$TPL" 2>/dev/null)
[ "$CODE" != "200" ] && fail "ini 拉取失败 (HTTP $CODE): $TPL"
GROUPS_IN_INI=$(grep -c "^custom_proxy_group" /tmp/_pf.ini 2>/dev/null)
echo "  ini: HTTP 200, $(wc -c < /tmp/_pf.ini) 字节, $GROUPS_IN_INI 个策略组定义"
[ "$GROUPS_IN_INI" -lt "$MIN_GROUPS" ] && fail "ini 里策略组只有 $GROUPS_IN_INI 个（应 ≥ $MIN_GROUPS）—— CDN 可能给了旧版本，先 purge 再试"

# ③ 干跑转换
ENC() { echo -n "$1" | sed "s/:/%3A/g; s|/|%2F|g; s/?/%3F/g; s/&/%26/g; s/=/%3D/g; s/|/%7C/g"; }
R=$(curl -s --max-time 90 "$API/sub?target=clash&new_name=true&url=$(ENC "$SUB")&config=$(ENC "$TPL")&expand=false" 2>/dev/null)

SIZE=$(echo "$R" | wc -c)
NGROUPS=$(echo "$R" | grep -c "^  - name:")
NNODES=$(echo "$R" | grep -cE "^  - \{name:")
echo "  转换: $SIZE 字节, $NGROUPS 个策略组, $NNODES 个节点"

# ④ 逐项校验
[ "$SIZE" -lt "$MIN_SIZE" ] && fail "配置过小（$SIZE < $MIN_SIZE）—— 多半是解析失败"
[ "$NGROUPS" -lt "$MIN_GROUPS" ] && fail "策略组只有 $NGROUPS 个（应 ≥ $MIN_GROUPS）"
[ "$NNODES" -lt "$MIN_NODES" ] && fail "节点只有 $NNODES 个（应 ≥ $MIN_NODES）"

# ⑤ 默认模板特征（禁用 pref.toml 的 import 后不该再出现）
if echo "$R" | grep -qE "节点选择|NETFLIX|广告拦截|运营劫持"; then
  fail "检测到 subconverter 默认模板特征 —— ini 没被应用"
fi

# ⑥ 关键内容抽查
for kw in "抖音" "运营01" "CN2GIA快线" "漏网之鱼"; do
  echo "$R" | grep -q "$kw" || fail "缺少关键内容「$kw」"
done
echo "  关键内容: 抖音 / 运营01 / CN2GIA快线 / 漏网之鱼 均在"

# ⑦ 自定义规则的节点名能否对上（防 AND 规则被静默丢弃）
D=/etc/openclash/custom
for f in "$D/openclash_custom_rules.list" "$D/openclash_custom_rules_2.list"; do
  [ -f "$f" ] || continue
  # 取规则末尾的目标名（去掉 no-resolve/src 后缀）
  sed -nE 's/^- .*,([^,]+)$/\1/p' "$f" 2>/dev/null | sort -u | while read -r t; do
    case "$t" in DIRECT|REJECT|PASS|"") continue ;; esac
    echo "$R" | grep -q "$t" || echo "  ⚠️ 自定义规则的目标「$t」在新配置中不存在，该规则会被丢弃"
  done
done

echo ""
echo "✅ 全部通过，可以执行更新订阅。"
