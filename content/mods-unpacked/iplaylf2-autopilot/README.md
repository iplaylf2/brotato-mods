# Autopilot

Autopilot 是一个实验性 Brotato mod：它依据玩家能够获得的信息进行短时间窗滚动规划，并自动控制战斗
移动。它的唯一控制输出是 `MovementBehavior.get_movement()` 返回的移动方向；瞄准、攻击触发、
速度、碰撞、击退、动画和移动机制始终由原版负责。

## 当前状态

- `manifest.json` 声明以 Brotato `1.1.15.4` 和 Godot Mod Loader `6.3.0` 为目标。
- 已实现可见世界观察、局内观察记忆、运动趋势估计、动态效用、轨迹搜索和移动执行闭环。
- 代码已经通过仓库格式和 lint 检查，但尚未完成游戏内加载与行为验证。

## 安装与启用

Autopilot 依赖 [Mod Options](https://steamcommunity.com/sharedfiles/filedetails/?id=2944608034)，并且默认
关闭。安装依赖后，在游戏中打开 `设置 → Mods → Autopilot`，启用 **Enable Autopilot**。

设置会立即作用于当前战斗并保存到后续战斗。关闭后，Autopilot 会停止移动并恢复玩家原有的
`MovementBehavior`。

## 公平边界

- 外部战场信息只有在玩家可见时才能进入观察；离开视野的敌人只依据先前观察继续估计。
- 玩家通过正常游玩可以掌握的敌人、投射物和波次机制可以作为预置知识，不要求每局重新学习。
- 玩家自身状态可以参与规划，但唯一控制输出始终是 `MovementBehavior.get_movement()` 的返回值。
- 武器预测只评价移动轨迹，不会调用或修改瞄准、攻击、目标、冷却、伤害和实体状态。

完整规则见 [玩家权限边界](docs/fair-play.md)。

## 规划特点

- 所有轨迹经过相同的结果预测与动态效用评分，不先通过角色或目标条件树决定唯一行为。
- 规划器根据连续可见位置估计敌人和敌方投射物的速度与加速度，并以短时衰减模型外推运动趋势；它不
  读取尚未表现的移动意图或随机结果。
- 可见敌人会立即匹配稳定机制知识；远程单位无需在本局先开火即可成为压力源。规划器同时比较射程、
  火力强度、耐久、清理收益、接敌代价和具体弹道风险。高速投射物使用扫掠路径参与避让，不会只检查
  离散采样点。
- 接触压力是随生命与防御状态变化的软成本，不是“确定死亡”的硬门槛；可控卖血路线仍能参与比较。
- 规划器可以利用原版自动攻击的只读预测选择移动方向，但不能影响攻击行为本身。

## 开发与诊断

观察契约、结果字段、搜索预算、模块责任和当前限制见 [架构文档](docs/architecture.md)；目标游戏版本的
敌人与投射物覆盖情况见 [原版机制审计](docs/vanilla-enemy-mechanics.md)。

启用后，可以读取某位玩家的最新观察和计划：

```gdscript
var observation = main.autopilot_observation_service.get_observation(player_index)
var plan = main.autopilot_controller.get_current_plan(player_index)
```

计划包含所选轨迹、移动方向、结果向量、逐项效用、动态上下文、搜索预算和近优轨迹摘要，供游戏内
诊断与回放校准。
