#!/bin/sh
# openclash-export.sh —— 把本机 OpenClash 的通用配置导出为可同步的文件
#
# ★ 用途:
#   在【调试完成的地点】跑这个脚本，把「插件设置 / 覆写设置」里的所有通用项
#   导出成 local/openclash-uci.conf，提交到仓库后，其他地点跑
#   openclash-setup.sh 即可同步同一份配置 —— 不用再记「我改了哪几项」。
#
# ★ 会排除的项（地点特定或含凭证，绝不入库）:
#     dashboard_password              API 密码
#     @config_subscribe[].address     订阅地址，含 JMS/gist 凭证
#     @config_subscribe[].custom_template_url   三地分别指向 cn/us/co.ini
#     @config_subscribe[].name        订阅名称，各地可自定
#
#   其余全部导出，包括 @dns_servers（37 个 DNS 服务器，三地应当一致）。
#
# 用法:
#   sh openclash-export.sh                    输出到 ./openclash-uci.conf
#   sh openclash-export.sh /path/to/out.conf  指定输出路径
#
#   导出后把文件放到仓库 local/ 目录并提交:
#     scp root@<路由器>:/root/openclash-uci.conf  local/openclash-uci.conf
#     git add local/openclash-uci.conf && git commit && git push

set -u
OUT="${1:-./openclash-uci.conf}"

# ── 排除清单 ──
# ⚠️ 必须用 '=' 结尾而不是 '$' —— uci show 的输出是 key='value'，
#    字段名后面还有 =值，用 $ 锚点会永远匹配不到（2026-08-17 踩过，
#    导致订阅 address 连同 JMS service ID 和 UUID 一起被导出）。
EXCLUDE="dashboard_password=|@config_subscribe\[[0-9]+\]\.(address|custom_template_url|name)="

# 导出后的强制自检模式 —— 命中任何一条就中止，不生成文件
LEAK='jmssub|gist\.github|decodo|password=|token=|uuid=|service=[0-9]'

command -v uci >/dev/null 2>&1 || { echo "❌ 未找到 uci"; exit 1; }
uci -q show openclash >/dev/null 2>&1 || { echo "❌ 读不到 openclash 配置"; exit 1; }

{
  echo "# OpenClash 通用配置 —— 由 openclash-export.sh 生成"
  echo "# 源地点导出时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "#"
  echo "# ⚠️ 本文件由脚本生成，不要手工编辑 —— 在任一地点用 LuCI 界面调好之后"
  echo "#    重新导出并提交，才能保证与实际运行配置一致。"
  echo "#"
  echo "# 已排除: dashboard_password / 订阅 address / custom_template_url / 订阅 name"
  echo "#         这些含凭证或三地必然不同，由各地本地维护。"
  echo ""
} > "$OUT"

# tr -d '\r' 是必须的 —— 若通过 expect/ssh 等带终端模拟的通道取回文件，
# 输出会变成 CRLF，每个值末尾多一个不可见的 \r，导致应用端逐项比对
# 永远判为「不同」而全量重写配置（2026-08-17 实测 387 项全部损坏）。
uci -q show openclash 2>/dev/null \
  | grep -vE "$EXCLUDE" \
  | grep -E "=" \
  | tr -d '\r' \
  | sort >> "$OUT"

# ── 强制自检: 宁可不生成，也不能泄漏凭证 ──
if grep -iqE "$LEAK" "$OUT"; then
  echo "❌ 检测到疑似凭证，已中止并删除输出文件:"
  grep -inE "$LEAK" "$OUT" | sed -E "s/=.*/=***/" | head -5
  rm -f "$OUT"
  exit 1
fi

TOTAL=$(uci -q show openclash 2>/dev/null | grep -cE "=")
KEPT=$(grep -cE "^openclash\." "$OUT")
SKIP=$((TOTAL - KEPT))

echo "=== 导出完成 ==="
echo "  输出:   $OUT"
echo "  已导出: $KEPT 项"
echo "  已排除: $SKIP 项（含凭证或地点特定）"
echo ""
echo "  分段统计:"
for s in config @dns_servers @config_subscribe; do
  N=$(grep -cE "^openclash\.${s}" "$OUT" 2>/dev/null || echo 0)
  printf "    %-20s %s 项\n" "$s" "$N"
done
echo ""
echo "  ✅ 凭证自检通过（脚本已自动校验，未通过会中止并删除输出）"
