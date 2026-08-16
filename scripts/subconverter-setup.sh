#!/bin/sh
# subconverter-setup.sh —— subconverter 容器的强制定制项
#
# ★ 三地办公室必须执行同一份脚本，确保配置一致。
#   容器重建(docker rm + run)后定制会丢失，必须重跑本脚本。
#
# 用法:
#   curl -sL https://raw.githubusercontent.com/maelitoandres/rules/main/scripts/subconverter-setup.sh | sh
#   或  sh subconverter-setup.sh
#
# 幂等: 可重复执行，已生效的项会跳过。
# 安全: 修改前备份到 /root/subconverter-backup-<日期>，改完验证容器能启动，
#       启动失败自动回滚。

set -u
C=subconverter
P=/base/pref.toml
BK=/root/subconverter-backup-$(date +%Y%m%d-%H%M%S)

echo "=== subconverter 定制 ==="

docker ps --filter "name=^${C}$" --format '{{.Names}}' 2>/dev/null | grep -q "^${C}$" || {
  echo "❌ 容器 $C 未运行"; exit 1; }

# ── 备份 ──
mkdir -p "$BK"
docker cp "$C:$P" "$BK/pref.toml" 2>/dev/null || { echo "❌ 备份失败"; exit 1; }
echo "  备份 → $BK/pref.toml"

restore() {
  echo "  ⚠️ 检测到异常，回滚中…"
  docker stop "$C" >/dev/null 2>&1; sleep 2
  docker cp "$BK/pref.toml" "$C:$P" >/dev/null 2>&1
  docker start "$C" >/dev/null 2>&1; sleep 10
  echo "  已回滚到 $BK/pref.toml"
  exit 1
}

# ── ① 提高规则集上限 ──
# 默认 64。超限时 subconverter【静默返回空配置】，不报任何错误 ——
# 2026-08-17 新增 4 条 ruleset 达到 65 条，触发此限制导致服务中断，
# 表现为策略组从 40 个变成 subconverter 的 13 个默认组。
CUR=$(docker exec "$C" sh -c "grep -oE '^max_allowed_rulesets *= *[0-9]+' $P | grep -oE '[0-9]+'" 2>/dev/null)
if [ "${CUR:-0}" -lt 256 ] 2>/dev/null; then
  docker exec "$C" sh -c "sed -i 's|^max_allowed_rulesets *= *[0-9]*|max_allowed_rulesets = 256|' $P"
  echo "  ① max_allowed_rulesets: ${CUR:-?} → 256"
else
  echo "  ① max_allowed_rulesets 已是 $CUR，跳过"
fi

# ── ② 禁用默认模板 ──
# pref.toml 默认 import 了 snippets/groups.toml（13 个默认策略组）与
# snippets/rulesets.toml。当 config 参数指向的 ini 解析失败时，subconverter
# 会【静默回退】到这些默认组 —— 配置看起来正常生成了，实际分流全错。
# 禁用后，解析失败会返回 0 个策略组，问题立即暴露。
#
# ⚠️ 必须连同 [[custom_groups]] / [[rulesets]] 表头一起注释。
#    只注释 import 行会留下空表，TOML 解析器报 key "name" not found 并崩溃。
if docker exec "$C" sh -c "grep -q '^\[\[custom_groups\]\]' $P" 2>/dev/null; then
  docker exec "$C" sh -c "
    sed -i 's|^\[\[custom_groups\]\]|# [[custom_groups]]  # 禁用默认模板 by subconverter-setup.sh|' $P
    sed -i 's|^import = \"snippets/groups.toml\"|# import = \"snippets/groups.toml\"|' $P
    sed -i 's|^\[\[rulesets\]\]|# [[rulesets]]  # 禁用默认规则集 by subconverter-setup.sh|' $P
    sed -i 's|^import = \"snippets/rulesets.toml\"|# import = \"snippets/rulesets.toml\"|' $P
  "
  echo "  ② 默认模板已禁用"
else
  echo "  ② 默认模板已是禁用状态，跳过"
fi

# ── 重启并验证 ──
docker restart "$C" >/dev/null 2>&1
OK=0
for i in 1 2 3 4 5 6; do
  sleep 5
  V=$(curl -s --max-time 10 http://127.0.0.1:25500/version 2>/dev/null)
  [ -n "$V" ] && { echo "  容器正常: $V"; OK=1; break; }
done
[ "$OK" -eq 1 ] || restore

# ── 生效确认 ──
echo ""
echo "=== 生效确认 ==="
docker exec "$C" sh -c "grep -E '^max_allowed_rulesets|^# \[\[custom_groups\]\]|^# \[\[rulesets\]\]' $P" 2>/dev/null | sed 's/^/  /'
echo ""
echo "✅ 完成。备份保留在 $BK"
echo "   下一步: 跑 preflight.sh 验证转换结果，再执行更新订阅。"
