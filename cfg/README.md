# 订阅转换模板

三地办公室各用一份，**订阅地址三地完全相同，差异只在模板**。

| 文件 | 地点 | 国际服务默认 | 中国服务 |
|---|---|---|---|
| `cn.ini` | 🇨🇳 中国 | 🇺🇸 冲浪快线 | DIRECT |
| `us.ini` | 🇺🇸 美国 | DIRECT | 回国节点 ⚠️ |
| `co.ini` | 🇨🇴 哥伦比亚 | DIRECT | 回国节点 ⚠️ |

⚠️ 尚无中国落地节点，该组暂为 DIRECT，补节点后在 ini 填一行即可。

三份文件的**规则集与策略组结构完全一致**，只有各组的默认出口不同。改动时
三份要同步——`scripts/` 下的工具会校验，但加规则集时容易只改一份，注意。

## 使用方式

OpenClash → 配置订阅 → 自定义模板地址：

```
https://raw.githubusercontent.com/maelitoandres/rules/main/cfg/<地区>.ini
```

**必须用 `raw.githubusercontent.com`，不要用 jsDelivr**。实测 jsDelivr 的
边缘缓存 purge 六次都刷不掉，改完 ini 后长时间拿到旧版本，而 subconverter
会静默使用过期模板——新加的 ruleset 就这么消失了，界面上却一切正常。

## 改动后必做

```bash
sh scripts/preflight.sh     # 干跑转换并校验，不合格拒绝放行
```

然后才更新订阅。这一步能挡住绝大多数配置事故，详见
[`docs/troubleshooting.md` §16](../docs/troubleshooting.md)。

## 历史

原先使用上游 [Aethersailor/Custom_OpenClash_Rules](https://github.com/Aethersailor/Custom_OpenClash_Rules)
的 `Custom_Clash.ini` 单模板。2026-08-13 起改为三地独立模板以支持多地点部署，
旧模板已于 2026-08-17 移除（切换完成并验证通过后）。
