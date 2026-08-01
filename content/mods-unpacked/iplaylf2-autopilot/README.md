# Autopilot

## 定位

Autopilot 的目标是让 bot 依据玩家可见的外部战场信息、精确的自身状态、局内战斗记忆和预置机制
知识，自主完成 Brotato 的战斗移动。

当前开发先完成信息采集与建模；观察契约完成并经过游戏内验证后，再进入移动控制。本文记录该契约、
建模原则及实现边界，供维护和扩展 Autopilot 使用。

Autopilot 默认关闭。订阅前置 [Mod Options](https://steamcommunity.com/sharedfiles/filedetails/?id=2944608034)
后，可在游戏的 `设置 → Mods → Autopilot` 中开启；设置会立即作用于当前战斗，后续战斗也会沿用。

## 建模原则

- 外部世界只能通过摄像机范围和战争迷雾内的可见信息进入观察。
- 玩家自身的生命、属性、资源、武器和携带机制属于透明信息，不受外部视野限制。
- 离开视野的敌人只能由局内战斗记忆继续估计；估计会随时间增加不确定性并最终过期。
- 属性、位置、速度、冷却和效果数值保留精确值；分类不能替代数值计算。
- 角色、道具和武器通过可复用特征与机制规则建模，公共观察不暴露内容 ID。
- 预置经验是代码中明确给出的分类和机制知识，不进行跨局学习。

## 观察接口

启用 Autopilot 后，主场景扩展在玩家生成后创建 `autopilot_observation_service`。调用：

```gdscript
var observation = main.autopilot_observation_service.get_observation(player_index)
```

返回值由六个顶层部分组成：

```text
physics_frame
player_state
├── health
├── progression
├── resources
├── inventory
├── effective_stats
├── runtime_stats
├── movement
├── pickup
├── weapons
└── mechanic_rules
localization
enemy_tracks
visibility
visible_world
```

`visible_world` 只包含当前可见的中立单位、友方单位、材料、消耗品、敌方弹射物和生成警告。敌人统一
通过 `enemy_tracks` 表示：可见时记录精确观测，离开视野后只保留带时间、置信度和不确定范围的局内
记忆。场景节点只用于观察器与战斗记忆之间的连续性匹配，不进入公共观察。

`localization` 从移动里程计开始；看到左侧或上侧地图边界后，才能逐轴确定地图坐标，其他已见边界
则补充距离和地图尺寸知识。它不会直接读取尚未观察到的完整地图位置。

## 机制规则

携带内容先由原版聚合为玩家 effects，再按机制族编译为 `event`、`condition` 和 `consequences`
组成的规则。决策层因此依赖“移动时增加属性”“拾取材料时治疗”等机制，而不是具体角色或道具 ID。

当前已编译的机制族包括：

- 站立和移动时的属性、材料变化及自动攻击限制；
- 材料与消耗品拾取产生的价值、治疗、伤害、冷却和属性效果；
- 持有材料以及保留敌人或树木产生的波次收益。

受击、闪避、击杀、生命阈值、周期成长和其他特殊效果仍需继续根据原版执行路径补充。无法识别的
机制不会被猜测成已有类别。

## 代码结构

```text
bot/
├── observation/               # 当前玩家状态、可见世界和公共观察组装
└── knowledge/
    ├── battle_memory.gd       # 单局定位与敌人记忆
    ├── enemy_behavior_classifier.gd
    ├── stat_vocabulary.gd
    └── mechanics/             # 按机制族组织的规则编译器
```

依赖方向由观察层指向知识层。`observation_service.gd` 是唯一公共读取入口；知识层不依赖观察服务，
机制族之间也不互相调用。`mod_main.gd` 持久化 Mod Options 配置并公开当前启用状态，主场景扩展只
消费该状态来管理观察服务的生命周期。

## 当前验证状态

仓库的 manifest、GDScript lint、格式检查和路径检查已经通过，尚未完成游戏内加载和行为验证。
在信息与建模覆盖经过游戏内验证前，不进入移动控制功能开发。
