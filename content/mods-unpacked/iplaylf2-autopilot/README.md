# Autopilot

Autopilot 是一个实验性 Brotato mod。它在玩家权限边界内评估环境暴露、碰撞风险、资源和交战机会，
再通过滚动规划选择战斗移动方向。唯一的控制输出是 `MovementBehavior.get_movement()`；瞄准、
攻击、速度、碰撞、击退、动画和移动机制仍由原版系统负责。

## 兼容性与验证状态

- 目标环境为 Brotato `1.1.15.4` 和 Godot Mod Loader `6.3.0`；以 `manifest.json` 中的声明为准。
- 游戏内加载和行为验证尚未完成，因此当前版本应视为开发版。仓库静态检查只覆盖目录结构、
  manifest 数据、源码格式和静态规则，不代表游戏内兼容性。

## 安装与启用

Autopilot 依赖 [Mod Options](https://steamcommunity.com/sharedfiles/filedetails/?id=2944608034)，并且默认
关闭。安装依赖后，在游戏中打开 `设置 → Mods → Autopilot`，启用 **Enable Autopilot**。

设置会立即作用于当前战斗并保存到后续战斗。关闭后，Autopilot 会停止移动并恢复玩家原有的
`MovementBehavior`。

## 公平边界

- 外部战场信息只有在玩家可见时才能进入观察；离开视野的敌人只依据先前观察继续估计。
- 玩家通过正常游玩可以掌握的敌人、投射物和波次机制可以作为预置知识，不要求每局重新学习。
- 玩家自身状态可以参与规划，但唯一控制输出始终是 `MovementBehavior.get_movement()` 的返回值。
- 武器预测只评价移动动作，不会调用或修改瞄准、攻击、目标、冷却、伤害和实体状态。

完整规则见 [玩家权限边界](docs/fair-play.md)。

## 工作方式

Autopilot 从当前可见信息、玩家自身状态、稳定机制知识和先前合法观察中建立局内世界模型。
规划器反复比较停留与各个移动方向，综合环境暴露、碰撞风险、资源、自动攻击机会、移动机制和
全局路线价值，每次只提交下一个短周期的移动输入。

敌对暴露、友方减压和治疗机会保持不同语义：友方火力只能降低对应敌人造成的环境暴露；
投射物拦截只降低实际拦截时刻之后的弹道暴露；治疗则作为独立收益。这些约束避免将支援能力误解为
无条件的安全区。具体观察字段、
评分结果和算法流程见 [架构文档](docs/architecture.md)。

## 维护入口

文档按权威范围分工：

- [玩家权限边界](docs/fair-play.md) 定义允许读取的信息和唯一控制面；
- [架构文档](docs/architecture.md) 定义公共观察、规划结果、决策流程和模块责任；
- [原版敌人与投射物机制参考](docs/vanilla-enemy-mechanics.md) 记录目标版本的敌人攻击与投射物入口；
- [原版道具与武器机制审计](docs/vanilla-item-weapon-mechanics.md) 记录目标版本的非常规效果覆盖及复核方法。

## 诊断接口

启用后，可以读取某位玩家的最新观察和计划：

```gdscript
var observation = main.autopilot_observation_service.get_observation(player_index)
var plan = main.autopilot_controller.get_current_plan(player_index)
```

计划包含所选动作、移动方向、结果字段、字段级与目标级效用账本、动态上下文、导航价值图、搜索预算和
近优动作摘要，供游戏内诊断与回放校准。
