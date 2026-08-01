# Autopilot 架构

本文面向维护者，定义 Autopilot 的观察契约、滚动规划流程和模块责任。用户安装与启用说明位于项目
[README](../README.md)；允许使用的信息和控制能力由 [玩家权限边界](fair-play.md) 统一规定，本文不
重复定义或放宽该约束。

## 运行链路

```text
主场景扩展
├── ObservationService
│   ├── PlayerStateObserver
│   ├── VisibleWorldObserver ──> ObservedMotionEstimator
│   └── ObservedWorldMemory ──> EnemyBehaviorProfiler
└── AutopilotController
    ├── MovementPlanner
    │   ├── SearchBudgetPolicy
    │   ├── TrajectoryGenerator
    │   ├── TrajectoryOutcomePredictor ──> MotionPredictor
    │   │   └── WeaponAttackPredictor ──> MotionPredictor
    │   ├── UtilityModel
    │   └── TrajectorySelector
    └── AutopilotMovementBehavior
```

主场景扩展共同管理观察服务和控制器的生命周期。控制器定期读取观察并请求运动计划，只把计划中的
首个移动方向交给 `MovementBehavior`；这是系统唯一的控制边界。速度、碰撞、击退、动画、瞄准、
攻击触发和移动机制均由原版 `Player`、`Unit` 与武器系统负责。

代码依赖保持单向：`control` 依赖 `planning`，`observation` 依赖 `knowledge`，规划层只读取观察字典，
不访问场景节点。`observation_service.gd` 是观察的公共读取入口。

## 观察契约

启用 Autopilot 且玩家生成后，可以从主场景读取某位玩家的最新观察：

```gdscript
var observation = main.autopilot_observation_service.get_observation(player_index)
```

观察由七个顶层部分组成：

```text
physics_frame
wave_state
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

`visible_world` 只包含当前可见的树木、友方单位、材料、消耗品、敌方弹射物和生成警告。敌人统一由
`enemy_tracks` 表示：可见时更新测量值，离开视野后根据最后一次速度与衰减加速度估计位置，并附带距
上次出现的时间、置信度和不确定范围。`visual_radius` 通常从精灵尺寸估算，无法读取时使用默认值；
它不是碰撞形状的精确半径。

观察器先读取可见实体当前呈现的速度；获得连续可见帧后，再按位置差更新速度，并由速度差估计平滑且
限幅的加速度。规划器用快速衰减的加速度模型短时外推弯曲或变速趋势；首次看到、观察中断或样本不足
时自动退化为当前速度或匀速预测。该过程不读取移动目标、攻击目标、随机状态或未来行为。

### 运动观察字段

当前可见的敌方弹射物通过 `visible_world.enemy_projectiles` 公开以下运动字段：

| 字段 | 含义 |
| --- | --- |
| `relative_position` | 当前相对玩家的位置 |
| `velocity` | 当前测得的世界坐标速度 |
| `acceleration` | 由连续可见样本估计并经过平滑、限幅的世界坐标加速度 |
| `motion_confidence` | 加速度趋势的可信权重，范围为 `0.0–1.0` |
| `visual_radius` | 从可见外观估计的半径 |

敌人通过 `enemy_tracks` 公开当前估计位置和以下运动状态：

| 字段 | 含义 |
| --- | --- |
| `relative_position` | 当前可见位置，或离开视野后的估计位置 |
| `last_observed_velocity` | 最后一次可见时测得的速度 |
| `last_observed_acceleration` | 最后一次可见时估计的加速度 |
| `estimated_velocity` | 将已观察加速度衰减到当前时刻后得到的速度估计 |
| `estimated_acceleration` | 衰减到当前时刻的加速度估计 |
| `motion_confidence` | 用于加速度外推的可信权重；离开视野后持续降低 |
| `seconds_since_seen` | 距最后一次可见的秒数 |
| `uncertainty_radius` | 离开视野后随时间和速度扩大的位置不确定半径 |

速度和加速度分别使用世界坐标单位/秒与世界坐标单位/秒²。`motion_confidence` 只调节加速度趋势；速度
仍作为最低阶运动估计。规划层消费 `estimated_velocity` 和 `estimated_acceleration`，而
`last_observed_*` 字段保留最后一次可见时的测量，供诊断和记忆解释。

场景节点只在观察层内部充当连续性标记，不会进入公共观察。敌人的
`behavior_profile` 根据已观察证据描述攻击方式、移动方式和战略角色；它不包含内容 ID。

`localization` 从移动里程计开始。看到左侧或上侧地图边界后，才能逐轴确定地图坐标；其他已见边界
用于补充当前边缘距离和已知地图尺寸。定位不会读取尚未观察到的完整地图位置。

## 机制知识

原版先把携带内容聚合为玩家 effects，Autopilot 再按机制族编译为由 `event`、`condition` 和
`consequences` 组成的规则。当前编译器覆盖：

- 站立或移动时的属性、材料变化和自动攻击限制；
- 拾取材料或消耗品产生的价值、治疗、伤害、冷却和属性效果；
- 持有材料以及保留敌人或树木产生的波次收益。

规划器目前直接使用移动状态规则和波次收益规则。拾取规则已经进入观察契约，但相关效果尚未全部纳入
轨迹结果预测。受击、闪避、击杀、生命阈值、周期成长和其他特殊效果也仍待补充。无法识别的机制不会
被推断为已有类别。

## 滚动规划

每次重规划依次执行以下步骤：

1. 预算政策根据当前敌人轨迹和可见敌方弹射物数量选择搜索预算。
2. 轨迹生成器创建停留轨迹和一组 0.8 秒曲线移动轨迹。
3. 所有轨迹先预测拾取、接近、危险、跑图和移动机制结果；其中敌人与弹射物的位置按已观察速度和
   短时加速度趋势外推。
4. 粗评分最高的固定数量轨迹再进行自动武器攻击结果预测。
5. 效用模型按当前局势生成权重，并输出逐项得分账本。
6. 选择器从近优轨迹中进行带权随机选择；逐物理帧 seed 使同一帧的选择可复现。
7. 控制器只执行所选轨迹的第一个移动方向，下一次规划重新读取环境。

规划结果向量使用以下语义：

| 字段 | 含义 |
| --- | --- |
| `material_pickup_value` | 轨迹对可见材料的拾取、吸附或接近价值 |
| `healing_pickup_value` | 结合缺失生命比例计算的消耗品拾取价值 |
| `expected_enemy_damage` | 自动武器对所有敌人的预期总伤害 |
| `expected_producer_damage` | 自动武器对生产型敌人的预期伤害 |
| `expected_loot_target_damage` | 自动武器对战利品目标的预期伤害 |
| `producer_approach_progress` | 对生产型敌人的相对接近进度 |
| `loot_target_approach_progress` | 对战利品目标的相对接近进度 |
| `targets_in_weapon_range` | 轨迹末端进入可用武器范围的敌人权重 |
| `tree_attack_opportunity` | 进入树木攻击范围或向其接近的价值 |
| `hazard_exposure` | 沿途靠近敌人、弹射物、生成警告和边缘的累计暴露 |
| `contact_pressure` | 轨迹上最严重的近距离接触压力 |
| `roaming_progress` | 轨迹位移形成的跑图倾向 |
| `standing_seconds` / `moving_seconds` | 对应移动状态在预测窗口内的持续时间 |
| `heading_continuity` | 新旧移动方向的点积 |
| `expected_attack_hits` | 武器几何预测得到的预期命中数，仅供诊断 |

这些量是可比较的启发式结果，不都具有相同物理单位。生产者和战利品目标伤害是总伤害的重叠子集，
用于提供额外战略权重，并非互斥分类。效用模型负责将所有结果转换为统一分数，而不是先用条件树选出
唯一目标。

### 动态效用

权重在每次规划时重建。波次接近结束时，可见材料和战利品目标价值上升，危险成本下降；生产型敌人的
提前处理价值随剩余时间增加。生命比例、护甲、闪避和恢复共同形成风险容忍度；保留敌人或树木的波次
机制会改变对应结果的权重，站立与移动机制也直接进入账本。

`contact_pressure` 只是基于距离的尾部成本，并非受伤或死亡概率。在缺少可靠伤害模型时，它不会作为
硬淘汰条件，因此高收益且风险可控的卖血路线仍可参与比较。

### 武器预测

武器精算考虑冷却、移动攻击限制和最近合法目标，并估计远程扩散、多弹丸、贯穿衰减，以及近战横扫和
突刺的覆盖。它是只读预测，只为移动轨迹提供效用；预测结果不会选择瞄准目标、触发攻击或修改武器。

### 搜索预算

当前预算政策使用“敌人轨迹数 + 可见敌方弹射物数”作为负载代理：

| 等级 | 计数 | 粗评轨迹 | 武器精算上限 |
| --- | ---: | ---: | ---: |
| 正常 | `< 140` | 37 | 10 |
| 繁忙 | `140–319` | 25 | 6 |
| 极端 | `≥ 320` | 9 | 4 |

粗评成本随轨迹数、采样数，以及敌人、弹射物、生成警告、拾取物和树木数量线性增长；武器精算只
作用于固定短名单。当前动作空间只有初始方向和转向率，不需要模拟退火。若以后允许多个自由动作段，
组合数会指数增长，届时应优先考虑 beam search 或交叉熵方法；模拟退火更适合高维连续且预测函数
足够平滑的轨迹空间。

这些等级是计数启发式，不是 Godot 帧耗时测量。`search_budget` 会公开实际等级、计数和上限，供后续
以性能监视器或帧时间反馈替换政策。

## 模块责任

| 模块 | 责任 |
| --- | --- |
| `bot/control` | 安排重规划、保存当前计划，并适配原版 `MovementBehavior` |
| `bot/planning` | 管理搜索预算、轨迹生成、结果预测、效用评分和近优选择 |
| `bot/observation` | 读取当前玩家与可见世界，维护局内观察记忆，组装公共观察 |
| `bot/knowledge` | 提供不随单局变化的行为画像规则、属性词汇和机制编译器 |

所有扩展必须先满足 [玩家权限边界](fair-play.md)。新增机制族应放入 `knowledge/mechanics`，并由
`player_mechanic_compiler.gd` 聚合。新增参与评分的结果维度必须同时定义预测语义和效用权重；新增
诊断维度则应明确标注不参与评分。

新增武器几何应留在 `weapon_attack_predictor.gd`，并且只能产生只读预测结果；运动规划器不得读取
武器实现细节。可见运动的跨帧测量由 `observed_motion_estimator.gd` 负责，规划期外推由
`motion_predictor.gd` 负责。观察层不得反向依赖规划层；规划层只能消费公共运动字段，不得读取观察层
内部的连续性标记。计算降级策略由 `search_budget_policy.gd` 单独负责。

## 当前限制

- 接触压力尚未由实际伤害、无敌帧、闪避和治疗机会校准。
- 拾取机制规则已经编译，但相关效果尚未全部进入结果预测。
- 运动估计的平滑、限幅和衰减参数尚未完成游戏内校准。
- 负载等级仍是实体计数启发式，尚未使用 Godot 性能监视器或实测帧时间。
- 观察、规划和控制尚未完成游戏内加载与行为验证。
