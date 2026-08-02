# 原版敌人与投射物机制审计

本文记录 Autopilot 针对 PC 版 Brotato `1.1.15.4` 的敌人攻击与投射物入口审计。它只保存版本兼容性
证据，不定义玩家权限或模块边界；权限规则见 [玩家权限边界](fair-play.md)，实现责任见
[架构文档](architecture.md)。审计依据位于本地 GDRETools 恢复工程
`.local/brotato-1.1.15.4-recovered/`，恢复工程不属于 mod 发布内容。

## 覆盖范围

审计以本地 GDRETools 恢复工程为依据，检查以下原版入口：

- 敌人注册的全部 `ShootingAttackBehavior`，包括普通攻击、附加攻击和 Boss 各阶段攻击；
- 敌人节点下常驻的 `EnemyProjectile`；
- 主敌方投射物容器中的移动、静止和动画危险区；
- 不属于任何可清理敌人的环境弹幕。

当前覆盖结果：

| 机制族 | 原版内容 |
| --- | --- |
| 标准或继承的射击行为 | `spitter`、`horned_spitter`、`junkie`、`dire_junkie`、`fly`、`horned_fly`、`lamprey`、`tentacle`、`slasher`、`mad_slasher`、`butcher`、`colossus`、`croc`、`gargoyle`、`invoker`、`mantis`、`mom`、`monk`、`rhino`、`predator` |
| 敌人子节点常驻投射物 | 腐化树的单枚旋转投射物；`predator` 的九枚旋转投射物 |
| 投射物形态 | 普通移动弹、静止或动画斩击区、柱状区域、附着旋转投射物、环境弹幕 |

## 实现映射

前两类具有可清理的敌人来源。`EnemyMechanicCompiler` 会在敌人可见后聚合其全部标准射击行为与常驻
投射物，编译射程、弹速、弹量、火力强度、投放模式、静止危险区、死亡时清除投射物的规则和保守
耐久成本。

腐化树和 `predator` 的旋转投射物不在主敌方投射物容器中，因此观察器还会遍历可见敌人的子节点。
环境弹幕没有可清理的敌人来源，只作为具体可见弹道参与规避，不会生成敌人清理目标。

对于没有使用标准入口的扩展内容，观察器仍可根据可见发射行为做降级归因；该推断不会覆盖已经编译的
稳定机制知识。

## 版本复核

升级目标游戏版本时，应重新检查：

1. 所有引用或继承 `shooting_attack_behavior.gd` 的敌人场景；
2. Boss 状态是否继续通过 `_all_attack_behaviors` 注册；
3. 敌人场景中是否新增常驻 `EnemyProjectile` 子节点；
4. 是否出现绕开上述入口、自行生成敌方投射物的敌人脚本；
5. 投射物容器、运动字段和死亡时清除投射物的规则是否发生变化。

若入口发生变化，应先更新机制编译或观察边界，再修改目标版本声明。不要把恢复工程、原版脚本或资源
复制进 mod 包或仓库内容。
