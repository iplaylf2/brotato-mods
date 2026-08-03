# Autopilot 架构

本文面向 Autopilot 维护者，定义运行链路、公共观察、机制语义、滚动规划和模块责任。安装与启用说明见
[README](../README.md)；允许使用的信息和控制能力由 [玩家权限边界](fair-play.md) 规定，本文不重复
权限条款。

按维护任务选择阅读入口：

| 任务 | 本文入口 | 配套文档 |
| --- | --- | --- |
| 修改公共数据或记忆语义 | [观察契约](#观察契约) | [玩家权限边界](fair-play.md) |
| 接入版本机制 | [机制知识](#机制知识) | [敌人与投射物参考](vanilla-enemy-mechanics.md)、[道具与武器审计](vanilla-item-weapon-mechanics.md) |
| 修改决策行为或诊断字段 | [滚动规划](#滚动规划) | [决策采样与模型校准](model-calibration.md) |
| 调整武器输出估计 | [期望武器结果场](#期望武器结果场) | [武器结果场的性能边界](model-calibration.md#武器结果场的性能边界) |
| 调整性能预算或排查掉帧 | [截止准入与连续保真度](#截止准入与连续保真度) | [性能反馈的可解释范围](model-calibration.md#性能反馈的可解释范围) |
| 调整文件归属或依赖方向 | [模块责任](#模块责任) | — |

## 运行链路

```text
主场景扩展
├── ObservationService
│   ├── 当前观察：PlayerStateObserver、VisibleWorldObserver
│   ├── 版本知识：bot/knowledge
│   └── 局内记忆：ObservedWorldMemory
└── AutopilotController
    ├── PhysicsFrameBudgetMonitor
    ├── MovementPlanner
    │   ├── 投射物可达性过滤、计算预算与导航意图
    │   ├── 动作生成与结果预测
    │   └── 效用评价与动作选择
    ├── DecisionTelemetry
    └── AutopilotMovementBehavior
```

主场景扩展负责管理观察服务和控制器的生命周期。启用 Autopilot 后，控制器定期读取观察并请求运动
计划，只把计划中的首个移动方向交给 `MovementBehavior`；这是系统唯一的控制边界。游戏暂停时，观察、
规划和采样一并停止；波次清场时，主场景扩展先停止 Autopilot 并恢复原移动行为，再由原版释放战斗
节点。速度、碰撞、击退、动画、瞄准、攻击触发和移动机制均由原版 `Player`、`Unit` 与武器系统负责。
观察层每个物理帧更新可见世界、运动估计、里程计和记忆，但只在控制器读取时物化公共观察快照；这样
持续感知仍为原物理频率，而随局内记忆增长的轨迹与实体副本只按重规划频率构造一次。

`DecisionTelemetry` 按固定采样政策，把控制器已取得的合法观察和只读规划账本持久化为
JSON Lines。它的责任终止于序列化和存储；计划生成与动作选择归属规划器和控制器。

`PhysicsFrameBudgetMonitor` 读取 Godot 按渲染帧更新的物理耗时监视值。它对同一渲染帧去重，并排除包含
本次规划的下一监视值世代，再维护非规划物理耗时基线及其偏差。引擎计时止于该边界；动作决策和计算预算
准入分别归属 `MovementPlanner` 与 `PlanningComputeBudgetPolicy`。

代码依赖保持单向：`control` 依赖 `planning`，`observation` 依赖 `knowledge`。规划层只接收已经移除
场景节点的观察字典；`bot/observation/observation_service.gd` 是观察的公共读取入口。

## 观察契约

### 公共入口与顶层结构

启用 Autopilot 且玩家生成后，可以从主场景读取某位玩家的最新观察：

```gdscript
var observation: Dictionary = main.autopilot_observation_service.get_observation(player_index)
```

观察由九个顶层部分组成：

```text
physics_frame
wave_state
player_state
├── dead
├── health
├── progression
├── resources
├── inventory
├── effective_stats
├── stat_opportunity_profiles
├── runtime_stats
├── collision_radius
├── movement
├── pickup
├── weapons
└── effect_rules
party_state
localization
enemy_tracks
remembered_entities
visibility
visible_world
```

`visible_world` 只包含当前可见的树木、友方角色、构筑物、材料、消耗品、敌方投射物和生成警告。
`wave_state` 包含当前波次、最终波次、无尽模式标记、剩余秒数和波次时长。
`player_state.stat_opportunity_profiles` 按规范属性名提供未来事件概率曲线。每条画像包含 `curve`、
`scale` 和 `chance_limits`；这些目标版本参数由属性知识模块适配，规划层据此计算属性变化的边际机会。
敌人统一由 `enemy_tracks` 表示：可见时更新测量值，离开视野后根据最后一次速度与衰减加速度
估计位置，并附带距上次出现的时间、置信度和不确定范围。`visual_radius` 通常从精灵尺寸估算，无法读取
时使用默认值；它不是碰撞形状的精确半径。

### 实体记忆与存在信念

`remembered_entities` 永久保存本局中已经合法看见过的材料、消耗品、树和构筑物。实体持续可见时，
同一条记录会刷新位置、运动状态和最后可见时间；离开视野后才保留最后观测并估计当前存在性。记录证明
观察确实发生过；`existence_confidence` 表示实体现在仍存在的可信程度。时间本身不构成消失证据，
置信度下降也不会删除记录。

材料或消耗品没有再次出现，且玩家或可见队友的实际拾取圆覆盖其记忆位置时，记忆层可以确认它已消失；
实体只进入吸附范围时，则按实际距离累计消失风险。队友离开视野后，系统仅以最后一次合法位置、速度、
实际移动速度和拾取半径估计可达区域。不曾定位过的队友不会产生风险；没有存活队友且玩家自身也未进入
拾取过程时，离开视野的材料和消耗品不会自行降低存在置信度。树和构筑物目前没有充分的合法消失证据，
因此只保留观测事实，不作任意时间衰减。

静止实体的最后观测位置不会随时间漂移；只有已观察到运动的实体才会扩大位置不确定范围。
`party_state` 公开队友总数、存活队友数和存活队友索引，但不公开不可见队友的位置或隐藏行为。原版
实体池可能复用节点来生成新的材料或消耗品，记忆层会根据位置可达性分配新的 `memory_record_id`，
避免覆盖旧记录。

因此，全图决策使用“当前可见信息 + 永久观测记录 + 带置信度的当前存在信念”。从未看见的实体不会
进入记忆，远处实体也不会因为留有记录就被视为确定存在。

### 运动状态

观察器先读取可见实体当前呈现的速度；获得连续可见帧后，再按位置差更新速度，并由速度差估计平滑且
限幅的加速度。规划器用快速衰减的加速度模型短时外推弯曲或变速趋势；首次看到、观察中断或样本不足
时自动退化为当前速度或匀速预测。该过程不读取移动目标、攻击目标、随机状态或未来行为。

当前可见的敌方投射物通过 `visible_world.enemy_projectiles` 公开以下运动字段：

| 字段 | 含义 |
| --- | --- |
| `relative_position` | 当前相对玩家的位置 |
| `velocity` | 当前基础世界坐标速度；解析运动模型的速度偏移另行叠加 |
| `acceleration` | 由连续可见样本估计并经过平滑、限幅的世界坐标加速度 |
| `motion_confidence` | 加速度趋势的可信权重，范围为 `0.0–1.0` |
| `visual_radius` | 从可见外观估计的半径 |
| `motion_model` | 已形成弹道的解析运动模型；正弦弹公开速度振幅、角频率和当前相位，普通弹为线性模型 |
| `contact_damage` | 当前可见投射物一次命中的原始伤害，用于生命风险预算 |

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

速度和加速度分别使用世界坐标单位/秒与世界坐标单位/秒²。`motion_confidence` 只调节没有解析机制时的
加速度趋势；速度仍作为最低阶运动估计。正弦横摆一类已形成的稳定曲线弹道由当前相位、速度振幅和角频率
唯一确定，规划器直接积分原版速度方程；发射方向、散布或速度的随机结果在弹体出现后已经体现为可见基础
速度。尚未发射且仍含随机分支的未来弹道只保留机制区间，不读取随机结果。规划层消费
`estimated_velocity` 和 `estimated_acceleration`，而
`last_observed_*` 字段保留最后一次可见时的测量，供诊断和记忆解释。

敌人稳定机制还可形成 `behavior_profile.target_position_response` 与
`behavior_profile.charge_attack`。前者描述移动行为是否响应目标位置，以及稳定移动速度和偏好距离；候选
路径预测以已观察速度为基线，只加入候选玩家位置相对零输入反事实造成的响应差。后者描述冲撞的触发
距离、速度、持续时间、可达距离和稳定冷却区间。
`next_charge_attack_window` 与齐射时间窗采用同一公开规则：确定冷却给出精确时间，尚未完成的随机冷却
只给出稳定区间；冷却归零并已形成可见攻击准备时公开立即就绪。冲撞风险按锁定位置与高速扫掠走廊同
候选路径的交会计算，因此横向脱离、沿线停留或径直后退的差异来自几何预测，不编码闪避动作方向。
这些版本知识无需以本局受击为前提。

可见树木的 `destructible_profile` 公开稳定的破坏命中需求、基础材料、基础消耗品掉率和是否必掉。它不把
幸运、当前生命或保树效果提前编译进画像；这些玩家状态只在规划层换算成当轮边际价值。

玩家自身的 `movement.velocity` 保留物理体报告的当前速度用于诊断；`movement.knockback_velocity` 则直接
读取原版 `Unit.get_next_velocity()` 使用的击退分量，并且是运动学预测中外部扰动的唯一来源。这样玩家
生成定位导致的单帧物理体速度不会被误判成击退并外推到候选路径。

### 友方角色与构筑物

可见构筑物由 `visible_world.structures` 单独表示，并带有与投射物相同的当前运动字段；这使游走机器人
一类移动作用区也只能按已观察运动外推。`influence.combat_support` 描述炮塔射程、地雷一次性爆炸区或
减速场，`influence.healing_support` 描述治疗覆盖；战斗支援分别公开玩家启用半径、玩家/敌人触发半径，
避免把持续启用条件与一次性触发事件混为一谈。公共画像还公开作用半径、相对强度、是否一次性、
同时目标容量和是否依赖恢复机会。花园已经生成的果实通过可见消耗品参与规划，不把未知冷却或未来产出
提前计分。

其他玩家和宠物统一由 `visible_world.allied_agents` 表示，公开 `kind`、归属玩家、与当前玩家的关系、
可见运动字段和作用画像。规划器消费压力减免区、治疗区、投射物拦截区，以及其他玩家实体碰撞压力；
不接收“战斗支援”“治疗者”“拦截者”等角色标签。没有完整且合法的协作状态契约时，也不产生额外的
靠近收益。

### 敌人行为画像

场景节点只在观察层内部充当连续性标记，不会进入公共观察。敌人的 `behavior_profile` 由
`EnemyMechanicCompiler`、`EnemyAttackTimingObserver` 和 `EnemyBehaviorProfiler` 依次构建：机制编译器从可见
敌人的稳定配置编译攻击、位置响应、耐久和收益载荷，其中位置相关机制委托给
`EnemyMotionMechanicCompiler`；攻击时序观察器形成当前的下一轮齐射与冲撞时间窗；画像器再融合稳定机制、
当前时序和未知内容的本局发射归因。稳定内容 ID 只作为编译器的内部缓存键；公共观察不包含内容 ID、
场景节点或敌人的当前生命。

因此，具有 `ShootingAttackBehavior` 的可见敌人会立即贡献已确认的远程火力压力，无需等到它在本局
首次开火。敌人节点下常驻的敌方投射物也会编译为 `attached_orbit` 压力并进入可见弹道观察，覆盖
腐化树和 `predator` 一类不经过主敌方投射物容器的危险。对没有标准攻击配置的扩展内容，附近出现并
向外运动的可见敌方投射物仍可作为降级归因；该证据随敌人轨迹保留，并在轨迹过期时消失。

`enemy_tracks[*].behavior_profile` 公开规划所需的稳定机制与观察结论：

| 字段 | 含义 |
| --- | --- |
| `projectile_attack` | 投射物攻击类别、知识来源、置信度、射程、投射物参数、射击间隔、随机边界、投放模式和火力强度 |
| `next_volley_window` | 下一轮齐射时间窗；确定性冷却给出精确时间，随机冷却只给出稳定区间 |
| `target_position_response` | 敌人对目标位置变化的连续移动响应、偏好距离和稳定速度 |
| `charge_attack` | 冲撞的触发范围、速度、持续时间、最大可达距离、冷却区间和目标随机性 |
| `next_charge_attack_window` | 当前下一次冲撞时间窗；确定性与随机冷却的公开规则同齐射时间窗 |
| `durability.maximum_health` | 不读取当前生命时，用于折算保守移除进度的最大生命基准 |
| `contact_damage` | 当前可见敌人的接触伤害 |
| `kill_rewards` | 基础材料、基础消耗品掉率和必掉约束 |
| `kill_rewards.player_stat_changes` | 击杀造成的玩家属性变化 |
| `battlefield_effects` | 每秒生产敌人数、每秒强化激活数、每次强化比例，以及敌我治疗量等战场后果 |
| `material_assimilation` | 材料吸附与拾取半径、进化材料阈值及最高耐久倍率；移除价值由当前材料竞速几何派生，不包含敌人类别优先级 |
| `removal_effects.visible_projectile_damage` | 与来源一同删除的当前可见投射物原始伤害总量 |

`projectile_attack.knowledge_source` 区分 `stable_mechanics` 与 `observed_emission`。前者是目标版本的稳定
机制知识；后者只在缺少标准机制配置时作为降级证据。

### 地图定位

`localization` 从移动里程计开始。看到左侧或上侧地图边界后，才能逐轴确定地图坐标；其他已见边界用于
补充当前边缘距离和已知地图尺寸。观察记忆还以四分之一短边视口为网格尺度记录合法视野覆盖。该网格只
描述“何处曾经可见、距今多久”，不记录格内隐藏内容，也不读取尚未观察到的完整地图位置。

| 字段 | 含义 |
| --- | --- |
| `odometry_position` | 从本局初始位置累计的玩家位移；不要求地图边界已经定位 |
| `map_x`、`map_y`、`map_position` | 看到对应左侧或上侧边界后才能确定的地图坐标；未知轴为 `null` |
| `map_bounds` | 四条边是否已见、当前距已见边界的距离，以及可由两侧边界确定的地图尺寸 |
| `observation_grid_cell_size` | 由首次有效视口短边的四分之一派生的正方形观察网格边长 |
| `observation_cells[*].grid_x`、`grid_y` | 已被合法视口覆盖过的里程计网格坐标 |
| `observation_cells[*].seconds_since_observed` | 该网格距最近一次合法视口覆盖的秒数 |

覆盖计算使用 `visibility.viewport_size` 与 `viewport_offset_from_player`，因此视口不以玩家为中心时仍沿用
实际可见矩形。未出现于 `observation_cells` 的网格表示尚无合法覆盖记录，不表示其中安全或没有实体。

## 机制知识

机制知识按信息所有者适配或编译。外部实体只有通过可见性判定后，才能调用对应知识模块；玩家自身的
透明效果数据则直接进入玩家效果适配边界。

### 敌人机制

`EnemyMechanicCompiler` 是敌人可见后稳定机制的聚合入口。它直接编译投射物攻击、耐久、接触伤害、奖励
和战场效果，并委托 `EnemyMotionMechanicCompiler` 编译目标位置响应与冲撞。Boss 各阶段攻击和普通敌人的
附加攻击统一从 `_all_attack_behaviors` 聚合。稳定配置可以包含攻击区间和随机边界，但不包含本轮已经
抽取的结果。

当前攻击时序归观察层的 `EnemyAttackTimingObserver` 所有，并分别形成 `next_volley_window` 与
`next_charge_attack_window`。确定冷却公开精确时间，未完成的随机冷却只公开稳定区间，已经可见的攻击
准备公开立即就绪；当前目标、当前生命和随机状态不进入机制画像。公共字段及其含义由前文的
[敌人行为画像](#敌人行为画像)定义。

目标版本的敌人清单、投射物形态、实现映射和升级复核步骤见
[原版敌人与投射物机制参考](vanilla-enemy-mechanics.md)。目标游戏版本的覆盖结论独立于架构契约维护。

### 玩家效果规则

原版先把玩家携带内容聚合为 `effects`。`bot/knowledge/player_effects` 是这套目标版本存储格式的适配边界，
只把已理解的字段翻译为统一规则。每条规则由事件、作用于事件载荷的条件和状态变换组成；条件描述可组合
事实，状态变换使用 `target`、`operation` 和参数表达。规则的支持范围由这些正交轴定义，不以角色、
物品、武器或扩展内容的目录衡量。

`PlayerRuleProjector` 沿上述轴产生恢复、生存与动作状态的规则投影，结果预测器则把
同一规则应用到候选路径。两者都不能读取原版字段名或内容 ID。可见消耗品同样只公开基础恢复量和语义
特征；实体特征由通用条件匹配，不以“能否触发某项机制”的布尔字段扩张观察契约。

`StatOpportunityProfileAdapter` 把属性影响未来事件概率的目标版本参数适配为
`stat_opportunity_profiles`。曲线参数属于版本知识；材料等价基准和剩余机会时域属于规划层估值。

### 武器攻击模型

武器由 `bot/knowledge/weapons/weapon_mechanic_compiler.gd` 读取目标版本的运行时状态和效果资源，编译出
不含节点、内容 ID 或机制名称的 `attack_model`。参与决策的最小契约是三个正交状态轴和一套状态转移语言：

| 轴 | 回答的问题 |
| --- | --- |
| `timing` | 长期单位时间能交付多少攻击，包括长装填折入后的期望周期和移动许可 |
| `delivery` | 能把命中投送给谁，以锁定距离、最大飞行距离、飞行速度、路径数、角覆盖、走廊宽度、方向误差、路径容量、伤害保留、重定向选择与容量表达 |
| `impact` | 一次基础命中产生多少伤害、暴击和生命偷取，以及受哪些玩家属性缩放 |
| `rules` | 状态转移语言：已定义事件如何变换前三轴或产生结果，由事件、条件和状态变换组成 |

暴击增加贯穿、持续伤害、邻近目标伤害、重新选目标伤害和按目标耐久补足伤害都只是
`rules` 中已有轴的组合，不会成为新的决策维度。原版 `Effect` 子类只允许在编译器中决定如何翻译；规划层
只解释事件、条件、目标、操作、数值来源，以及目标与触发位置间的空间和容量约束。

玩家与武器的 `rules` 使用同一 `consequence` 契约：`probability` 表达发生概率，`target` 与 `operation`
表达状态转移，`amount` 是常量及已建模状态量的线性组合，`delivery` 只含目标选择、是否复用或排除事件
目标、是否以事件实体为锚点、半径、飞行速度、最大飞行距离和每事件容量。
`minimum_targeting_distance` 与 `maximum_targeting_distance` 界定自动锁定范围；
`maximum_travel_distance` 则界定路径或后续事件的传播距离。版本知识模块可以识别原版机制来编译这些量，
任何规划器都不能据此恢复或分派机制类别。

### 攻击模型的当前边界与扩展条件

公共攻击模型尚未覆盖以下三类能力。下表同时规定当前行为、重新设计的条件和责任边界；它们不是按内容
名称积累的适配待办：

| 问题 | 当前决策 | 重新打开设计的条件 | 所有者 |
| --- | --- | --- | --- |
| 非武器自主伤害源 | 当前结果场只汇总玩家武器；不把周期弹幕或击杀派生攻击塞进物品规则特例 | 该来源能稳定改变移动位置上的期望结果场，且可从合法状态估计其单位时间容量 | 将 `attack_model` 泛化为通用攻击源的 `bot/knowledge` 机制编译器与结果场模型 |
| 目标条件伤害 | `impact` 只使用当前公共目标画像可表达的量；敌人当前生命受权限契约排除，因此精确击杀、按当前生命追加伤害和依赖当前状态的连锁不参与预测 | 新增条件是允许观察且能跨内容复用的目标事实 | `bot/observation` 的统一目标响应画像；版本映射模块不得自行读取目标状态 |
| 命中后的运动反馈 | 当前动作内的敌人轨迹不因尚未发生的击退、减速或扩散效果而改写；下一次重规划使用新观测 | 游戏内回放能校准通用状态转移，并证明它会实质改变动作排序 | 运动观察与动作期状态转移预测器共同拥有，不能由单个效果修补轨迹 |

没有单独列为扩展点的行为已经由现有契约决定：击杀价值只使用最大生命形成的保守进度；一次攻击只对其
预测时刻已存在的合法目标计分，不猜测返程前可能新入场的实体；预测窗外的周期属性、波间收益和随机升级
不提前计分，实际生效后由下一次观察和重规划自然接管。

新增能力优先组合已有的事件、条件和状态变换。只有共享模型缺少必要表达能力时才扩展正交轴，
并使现有规则能够自然复用。目标版本的原版字段映射只是局部适配代码；本文只描述规则轴、预测语义和
扩展条件；按内容核对的版本覆盖分别由两份原版机制参考与审计文档维护。

### 友方与构筑物作用画像

`AllyMechanicCompiler` 与 `StructureMechanicCompiler` 把可见玩家、宠物和构筑物编译为同一类数值化
作用区；它们可以在机制编译边界识别原版类型，但规划层只接收几何、强度、启用条件、触发条件、容量和
恢复机会约束。
两者都不读取当前目标、冷却、生命或未知的未来产出。

## 滚动规划

规划器采用受计算预算约束的滚动时域控制近似。动作 `u` 的效用由短预测窗内的可逆环境暴露、本次提交期
内的生命、战斗与事件结果，以及动作窗外的导航终端价值组成。位置域扫掠与速度障碍在完整局部窗内保留
远期交会证据，其中提交期内的部分再换算为本次动作造成的生命损失。每次提交固定数量的物理 tick，然后
用新观察重新求解。

### 决策流程

每次重规划依次执行以下步骤：

1. 控制器提供由实测物理帧耗时形成的帧预算上下文。规划器先用保守位移上界排除在导航时域内无法影响
   玩家可达区域的投射物；敌人因缺少统一机动上界而全部保留。计算预算政策再把每位存活玩家可用的
   帧余量转换为最终截止和连续预算压力。搜索保真度分配器再按对象最早可能产生物理影响的时间分配搜索广度：
   近场随预算压力下降较慢，远场下降较快；零输入、价值模型给出的导航方向和碰撞时间采样始终保留。
2. 导航意图规划器以同一终点总价值比较原点、均匀基线方向、正价值机会按可达价值聚合形成的角向质心和
   额外角区间；合计价值最高的机会方向属于有界基线，其余机会方向和角区间受截止约束。每个终点同时
   计算材料、恢复、树木、敌人、地图信息和环境暴露的价值差。
   动态敌人与环境暴露都以同一未来时刻的零输入状态为反事实基线，只把玩家移动实际改变的部分归给动作。
   地图项使用从原点到候选终点的视口扫掠并按网格去重，再按观察陈旧度计价：未见网格具有完整再观察
   价值，已见网格随距上次观察的时间连续恢复该价值。因此未知区域产生探索，地图全部定位后也会自然
   巡游较久未观察的区域，无需预设巡逻路线。只有正增益终点会形成移动偏好。
3. 导航风险使用与局部生存效用相同、随生命、防御和波次时限变化的环境风险价格。
   动作生成器离散化本次可提交的移动输入，并补入导航偏好方向；零向量是不输入移动指令的动作。
4. 动作只会执行到下一次重规划。提交期由整数物理 tick 派生；近端预测窗为两个控制步。
   局部默认窗至少包含四个控制步，且足以跨越两个玩家碰撞直径；局部上限再保留三个修正步，
   导航窗再延伸五步。动作、导航、速度障碍和投射物可达性使用的有效时域都截断至本波剩余时间，
   不会给波次结束后无法发生的收益或碰撞计价。较近威胁不会反向截短时间域。角向分辨率使相邻指令
   经过一个提交期后的端点间距不超过玩家半径；时间采样使相邻玩家位移不超过碰撞直径，确定性曲线弹的
   相位步长不超过 `π/2`。
5. 每个动作只生成一次战场、速度障碍和事件基础结果，再从共享的[期望武器结果场](#期望武器结果场)
   读取该动作对下一决策状态的修正，然后进入唯一一次完整评分。候选方向不会各自展开攻击过程。
   碰撞风险取位置域扫掠证据与速度空间交会证据的较大值；后者同时包含普通 TTC 和已知冲撞的锁定走廊。
   同一次交会不会因两个检测器都发现它而相加；位置域投射物使用扫掠线段，避免高速弹体穿过采样间隙。
6. 提交期内的峰值碰撞与累计接触证据先按可见威胁伤害、候选移动状态下的护甲/闪避、命中保护、原版
   最短无敌帧间隔和当前生命换算为预期生命损失；生命成本对消耗后的有效生存缓冲积分，越接近最强可见下一击所需
   储备，边际成本越高。可能直接耗尽生命的部分另以未折价的终止风险价格进入同一效用账本。
   规划器不在效用账本外设置碰撞硬筛选，因此承伤、材料、恢复、交战和信息收益使用同一选择语义。
   按搜索保真度保留的均匀基线与导航偏好方向继续完整计分。均匀格点数量虽是整数，但由连续曲线取整产生，
   不存在共享的质量档或跨模块档位分支。
7. 在最终截止与当轮搜索保真度给出的精炼额度内，规划器围绕当前高分动作的相邻角区间插入中点；每个
   新候选也执行与基线相同的完整预测和评分。搜索预算只改变候选覆盖，不改变候选之间的结果语义。
8. 选择器采用统一账本中总效用最高的动作。控制器提交所选移动向量，下一次规划重新读取环境。

### 决策基底

进入最终动作选择的量按责任而不是按数据来源划分为最小基底：环境暴露、碰撞风险、已经实现的事件结果、
期望武器结果和尚未兑现的导航行程价值。一个事实可以被多个预测器观察，但只能由一个
评分量拥有其决策含义：位置扫掠和 VO 都是碰撞检测证据，合并后才计分；实际拾取消耗品形成
`expected_recovery`，并由 `consumed_consumable_recovery_supply` 结清离开地图的恢复储备；箱子形成的
保守道具选择收益由 `consumable_item_choice_value` 结算，满血或溢出拾取造成的恢复机会损失另由
`wasted_consumable_recovery` 诊断。不可逆的拾取、承伤和路径规则事件只在本次实际提交的控制期内
确认；武器通道只表达提交期尺度上的期望状态修正，不宣称某次命中已经发生。提交期外尚未发生的结果只能
由环境暴露或导航机会势能表达，不能预支为已经实现。`material_acquisition_value` 只拥有实际收集；尚未
拾取材料的空间价值由导航统一聚合。导航以原版吸附半径作为材料交互边界，并按直线路径到各实体的最近点
计值，因此一条路线扫过的材料会全部贡献价值，已进入吸附范围的材料则无需继续要求玩家追到拾取圈。
所有候选都相同的被动恢复只影响规划上下文，不进入动作结果。

效用模型把评分字段唯一分配给五个决策目标：`survival`、`recovery`、`economy`、`combat` 和
`navigation`。调试构建在每个效用模型实例首次生成评分上下文时验证同一字段不能进入两个目标；
`objective_utility_breakdown` 公开目标级总账，`field_utility_breakdown` 保留字段级解释。敌人的击杀收益、
直接压力和持续机制后果先合并为敌人移除价值，再由期望伤害和导航机会共同消费。树木的未兑现接近由
导航路径势能表达；期望武器结果场让敌人与树木进入同一连续目标覆盖分布，并按期望命中容量折算树木收获进度。
移动不会把拾取与自动攻击拆成互斥目标：每个候选移动同时比较导航路径上的材料、恢复和树木机会，以及
该路径允许的武器攻击结果；只有提交控制期内已经进入交互边界的事件才记为已实现结果。敌人的已观察运动
对所有候选使用同时间基线；稳定目标响应只加入候选玩家位置
相对零输入状态造成的运动差，因此追踪经验会改变地图和轨迹评分，却不会变成预设动作。
移动状态产生的材料周期收益归入 `economy`；护甲、闪避、武器属性和移动速度分别进入生存、攻击与
运动学预测器。

规划时间域由 `MovementTimingModel` 唯一拥有：它从物理 tick、控制步数、玩家碰撞直径和当前速度派生
提交期、局部动作预测期和导航预测期。空间机会的评分归属则由 `SpatialOpportunityValueModel` 统一处理。
已确认不存在的记忆不进入机会模型；所有仍可能存在的可见与记忆机会都由导航路径统一计值，不再按局部
半径分账。导航敌人机会只形成终端价值，不替代候选动作对局部期望武器结果场的采样。
动作集合包含离散方向和零输入。目标版本 `Unit.get_move_input()` 将非零移动输入归一化后乘移动速度。

### 结果与诊断

状态为 `ready` 的规划结果同时提供评分账本和只读诊断。顶层 `model` 保存统一时间契约和
本次决策实际使用的派生空间尺度；`selection_diagnostics` 保存最大效用选择方式和候选数量。
`compute_budget.phase_duration_usec` 按观察准备、导航、基线动作完整评价与方向细分
记录阶段耗时。这些诊断只解释校准样本和最终选择，不参与效用评分。

以下预测结果直接进入动作总分，或先由效用模型按当轮价值上下文换算。字段级账本记录换算后的有符号
贡献：

| 字段 | 含义 |
| --- | --- |
| `material_acquisition_value` | 本次提交控制期内实际进入收集半径的可见材料价值，包含避免推迟至后续波次兑现的成长时机价值 |
| `consumable_item_choice_value` | 本次提交控制期内拾取箱子所取得的波末道具选择保守价值；按目标版本最便宜普通道具的基础回收收益随波次膨胀计算，不读取未来随机道具 |
| `consumed_consumable_recovery_supply` | 拾取消耗品时离开地图的恢复储备，按恢复供给影子价格扣除；使恢复收益与储备消耗进入同一账本，避免重复计值 |
| `consumed_single_use_support_supply` | 候选路径由玩家或敌人触发地雷等一次性支援时消耗的储备，以支援强度和存在置信度折算，并按当前生命资源价格扣除 |
| `expected_enemy_removal_value_progress` | 期望武器结果场中的伤害按覆盖目标的移除价值与最大生命折算后的收益 |
| `expected_tree_harvest_value_progress` | 树木参与自动武器目标覆盖后，期望命中容量按破坏所需命中数折算的收获进度 |
| `expected_rule_damage` | 玩家效果规则因拾取、治疗、受击或闪避产生的预期敌人伤害 |
| `expected_allied_damage` | 地雷等一次性友方作用对当前可见爆炸范围内敌人的预期伤害，按敌人移除价值计分 |
| `expected_recovery` | 候选动作的实际拾取、生命偷取和动作相关事件规则产生的预期恢复量 |
| `expected_stat_upgrade_equivalents` | 效果规则产生的永久或临时属性变化折合成的期望一级升级份数 |
| `expected_stat_opportunity_value` | 属性变化影响未来事件机会所产生的材料等价边际价值 |
| `expected_material_gain` | 暴击击杀等战斗事件直接产生的预期材料，不含地图上已有材料的拾取 |
| `movement_damage_exposure_reduction` | 候选移动状态相对当前状态降低的护甲与闪避伤害暴露，按碰撞风险调制；负值表示暴露增加 |
| `integrated_allied_healing_support` | 动作沿途处于友方治疗或治疗增益覆盖内的累计支援暴露 |
| `integrated_environmental_exposure` | 敌人接近、生成、远程火力、地图边缘和队友阻塞扣除对应减压后的沿途环境暴露；不含碰撞 |
| `field_utility_breakdown.health_resource_loss_value` | 效用模型对预期生命消耗沿当前有效生存缓冲的稀缺曲线积分后形成的负向贡献；其绝对值在大量消耗剩余缓冲时高于当前边际价格的线性外推 |
| `terminal_collision_risk` | 单次命中或提交期内的累计接触可能耗尽当前生命时保留的终止碰撞风险；按未折价生命价值进入生存效用 |
| `navigation_terminal_value_gain` | 本动作对最佳导航终点总增益的有符号兑现值：按输入相对零输入造成的提交位移在终点方向上的距离比例计算；反向位移产生负值 |
| `standing_seconds`、`moving_seconds` | 对应移动状态在提交控制期内的持续时间，只承载该状态的周期材料收益 |

以下字段记录预测证据和中间量。部分字段参与上方评分量的合成，但都不会作为独立收益或成本再次计分：

| 字段 | 含义 |
| --- | --- |
| `expected_weapon_damage` | 期望武器结果场在一个提交期内对覆盖敌人的伤害容量；敌人移除价值另行计分 |
| `expected_health_loss` | 提交期内的峰值碰撞风险与累计接触按原版最短无敌帧间隔换算预期命中次数，再结合最大单次伤害、候选护甲、闪避和命中保护得到的预期生命消耗；效用模型再将它换算为 `health_resource_loss_value` |
| `integrated_enemy_proximity_pressure` | 敌人距离和记忆不确定性形成的有界累计压力；冲撞走廊由独立碰撞证据拥有 |
| `enemy_charge_obstacle_risk` | 已知冲撞机制按当前时序、锁定位置和高速扫掠走廊与候选路径交会形成的速度障碍风险；该证据同时进入碰撞与生命损失账本 |
| `integrated_projectile_proximity_pressure` | 敌方投射物位置域扫掠形成的累计邻近压力 |
| `peak_projectile_contact_risk` | 位置域扫掠确认的峰值投射物接触风险 |
| `integrated_spawn_pressure` | 靠近可见敌对生成警告的累计压力 |
| `integrated_edge_pressure` | 靠近已观察地图边缘的累计压力 |
| `peak_enemy_contact_risk` | 按实体物理半径计算的峰值敌人接触风险 |
| `integrated_ranged_attack_pressure` | 暴露在已确认远程攻击范围内的累计压力 |
| `integrated_allied_body_pressure` | 多人模式下靠近其他玩家实体形成的累计阻塞压力 |
| `integrated_allied_pressure_relief` | 构筑物或战斗宠物对相关敌人环境压力的累计原始减压量 |
| `integrated_projectile_interception_relief` | 友方角色先于玩家截获威胁弹道后形成的累计投射物减压 |
| `integrated_hostile_exposure` | 按环境压力通道权重合成的沿途总敌对暴露 |
| `integrated_exposure_relief` | 受对应敌压上限约束的沿途总减压 |
| `peak_environmental_pressure` | 动作预测中任一采样点的峰值环境暴露 |
| `peak_path_collision_risk` | 位置域采样和扫掠得到的峰值碰撞风险 |
| `integrated_hostile_collision_risk` | 位置域敌对接触风险沿预测时间的积分，用于区分短暂交会与持续贴身 |
| `committed_peak_path_collision_risk` | 位置域峰值碰撞证据中落在本次提交期内的部分 |
| `committed_integrated_hostile_collision_risk` | 位置域累计敌对接触中落在本次提交期内的部分 |
| `committed_hostile_velocity_obstacle_risk` | TTC 交会发生在本次提交期内的敌对速度空间风险 |
| `initial_environmental_pressure` | 候选动作起点的环境暴露 |
| `terminal_environmental_pressure` | 候选动作预测终点的环境暴露 |
| `mean_environmental_pressure_derivative` | 沿候选动作的平均环境暴露物质导数 |
| `velocity_obstacle_risk` | 候选速度落入敌人、弹体或队友碰撞锥的有界 TTC 证据 |
| `collision_risk` | 完整局部窗内位置域峰值碰撞证据与速度空间 TTC 风险的较大值；用于远期诊断与移动状态暴露调制，生命消耗只读取其提交期子集 |
| `enemy_velocity_obstacle_risk` | 与敌人交会的速度空间风险，包含普通 TTC 与冲撞走廊证据 |
| `projectile_velocity_obstacle_risk` | 与敌方投射物交会的 VO 风险 |
| `ally_velocity_obstacle_risk` | 与其他玩家交会的 VO 风险 |
| `minimum_time_to_collision` | 当前候选速度下最早预测交会时间 |
| `candidate_velocity` | 结合移动输入与已观察击退衰减后的候选平均速度 |
| `maximum_armor_adjusted_hit_damage` | 预测会与候选交会的最强单次伤害经过候选护甲换算后的数值 |
| `expected_collision_hit_count` | 峰值与累计接触按原版最短无敌帧间隔折算的有界预期命中次数 |
| `wasted_consumable_recovery` | 拾取消耗品时因满血或溢出而未转化为当前生命的恢复量 |
| `expected_attack_hits` | 期望武器结果场按攻击率、覆盖和多目标容量估计的命中数 |
| `expected_recovery_events` | 玩家效果规则预测得到的恢复事件数 |
| `expected_kill_weight` | 预期伤害相对敌人最大生命形成的保守击杀进度 |
| `expected_critical_kill_weight` | 上述进度按武器暴击率折算的暴击击杀证据 |

压力通道先在各自语义内归一化和有界叠加，再按本波剩余暴露下的生命边际价格换成公共价值。一单位材料
是基础价值基准；收集地面材料还会计入避免推迟至后续波次兑现的成长时机价值。普通属性变化按目标版本
一级升级所给的属性增量归一化，属性造成的未来机会变化另作边际定价；
敌人移除价值由击杀收益、直接伤害压力、剩余时间内的生产、强化和治疗后果、保留敌人收益及敌人提供的
玩家治疗机会共同计算。

### 暴露与导航意图

底层环境暴露 `P(x,t)` 是位置和时间上的连续启发式运行成本，不声称是物理压力、受伤概率或完整价值函数。
`NavigationIntentPlanner` 只在最长导航时域与本波剩余时间两者较短者的可达终点上采样该场，用于选择
大方向而非精确避弹。均匀方向保证没有已知机会时仍能比较空间；最强正价值机会的精确方向属于基线，
避免计算压力让稀疏目标从候选空间消失；其余机会方向只增加候选，不预选目标。候选终点受本波有效导航
时域和已知边界裁剪。地图信息场对从当前点至候选终点的视口扫掠按观察网格去重计值：未见网格具有完整
再观察价值，已见网格按距上次观察的时间相对波长连续恢复该价值。它只表达合法视野的预期信息收益，
不把未知区域视为已知安全区，也不编码巡逻路线。

每条终点路径聚合尚未兑现的材料、恢复、树木、敌人移除机会与地图信息价值。静态机会按路径到实体的
最近交互距离聚合；材料使用吸附半径，树木使用当前武器射程。候选终点和零输入基线
使用相同预测时刻和敌人运动外推，导航环境暴露也比较两者在该时刻的差值；因此敌人自行靠近只改变共同
未来状态，不会伪装成移动收益。终点总增益只决定导航方向和总行程价值；动作评分再按本次输入相对零输入
造成的提交位移在该方向上的投影占终点距离的比例兑现，不能把击退归因给移动输入，也不能在一个控制期内
预支完整行程。
导航意图公开方向与价值（`movement_preference`、`terminal_value_gain`、`origin_value`、
`selected_displacement`、`selected_value_breakdown`）、评价次数（`position_evaluation_count`）和空间尺度
（`sampling_radius`、`local_prediction_radius`、`control_distance`），便于验证导航意图来源。其中
`terminal_value_gain` 是终点总增益，不是单个动作结果中的本提交期兑现字段
`navigation_terminal_value_gain`；
`origin_value` 是零输入反事实的零值基线；`position_evaluation_count` 包含原点，
`baseline_position_evaluation_count` 与 `extra_position_evaluation_count` 分别记录基线和额外评价次数；
`baseline_opportunity_evaluation_count` 记录基线中是否补入了不与均匀格点重合的最强机会方向；
`sampling_radius` 是地图边界裁剪前的候选半径，不声称是实际行进距离。

导航终点的环境暴露按局部生存效用使用的同一动态风险价格计入成本。动作评价仍检查完整路径并执行扫掠
碰撞检测，因此导航终点不会替代局部避障。候选动作还记录环境暴露沿路径的平均变化率
`[P(x(T),T)-P(x(0),0)]/T`，即 `∂P/∂t + v·∇P` 的路径平均。

各通道的抵消关系受语义约束：友方火力只能降低当前敌人接近和远程火力造成的环境暴露，不能抵消尚未
生成的警告；投射物拦截只能降低拦截时刻之后该弹原本会造成的压力。减压不能消除实体接触、地图边缘或
队友阻塞，也不能超过当时对应的敌对压力，因此友方作用区不会产生无上限收益。治疗和治疗增益属于独立
恢复机会，不能抹去已经预测到的伤害压力。

### 动态效用

上下文在每次规划时重建。`HealthResourceValueModel` 根据当前生命、最强可见单次伤害和近期替代供给
计算生命的边际价值。替代供给包括展望窗内可达的已观察消耗品、剩余时间内的概率掉落、被动恢复，以及
移动时仍可触发的生命偷取；被动生命流失则从生存余量中扣除。非致命生命和替代供给只服务于本波剩余
暴露，其价格按本波剩余比例连续下降：波末清场会重建下一波的起始生命，未消费的安全余量不会跨波保值。
替代供给越充足，普通承伤价格越低。动作消耗生命时不把当前边际价格线性外推，而是对消耗后的有效生存
缓冲积分；因此接近下一次最强可见命中储备时成本连续加速。可能结束本局的碰撞使用未折价价值；终止风险
同时考虑最强单次命中和提交期内按原版最短无敌帧间隔折算的累计接触。拾取消耗品把地图替代供给转化为
当前生命。`expected_recovery` 记录实际恢复收益，`consumed_consumable_recovery_supply` 结清离开地图的
储备价值；两者在同一账本中形成从储备到当前生命的净变化。实际恢复量受缺失生命上限约束。

消耗品的治疗价值取当前可兑现恢复。拾取引发的爆炸、属性或材料效果由候选拾取位置上的事件预测器计算；
导航终端值使用消耗品的基础恢复机会。

`OpportunityValueModel` 统一把材料、消耗品、树木和敌人移除机会换算为材料等价边际价值。树木收益中的
材料使用与地面材料相同的本波兑现价格，概率消耗品按当前恢复供给的转化边际价值计价，因此生命越低，
树木价值会连续提高，无需增加“低血找树”的策略分支。模型在每次规划中一次性建立敌人移除价值账本。
每个敌人的移除价值等于击杀收益、其直接接触与远程压力负担、来源死亡
可清除的当前投射物、剩余时间内预期新增敌人造成的负担、强化和治疗对现存
敌群的负担，再减去波末保留该敌人的收益及其可给玩家提供的治疗机会。所有项先换成材料等价值；武器
伤害按最大生命比例兑现；导航中的敌人机会再乘剩余时间内的可击杀性。
击杀或效果规则造成的属性变化由 `StatOpportunityValueModel` 按当前属性、机会曲线和剩余波次计算边际价值。
账本构造只扫描敌群一次，动作、导航和每次武器目标预测共享结果，避免密集敌群下的二次复杂度。

效用模型对 `integrated_environmental_exposure`、由 `expected_health_loss` 换算的
`health_resource_loss_value` 和
`terminal_collision_risk` 施加生存成本。位置域
`peak_path_collision_risk` 与速度空间 `velocity_obstacle_risk` 取较大值后形成完整局部窗诊断；两者的提交期
子集再合并为生命成本输入，不重复计分。VO 使用连续 TTC 风险；终止与非终止风险都在同一效用账本内和
其他结果交换，不另设硬筛选。
环境暴露变化率和两类碰撞证据只保留在诊断账本中。敌人轨迹的位置不确定半径
只扩大邻近压力，不扩大 VO 的实体碰撞圆；物理碰撞几何始终使用玩家与敌人的实体半径，避免把“可能
位于某处”误写成“TTC 为零”。

友方作用区进入公共效用账本。炮塔和战斗宠物只有在
预测敌人进入其作用范围且仍对玩家形成近身压力时才产生减压价值；猫炮还要求玩家进入其可见启用范围。
地雷按一次性机会计分：原版踏板同时接受玩家与敌人，因此两者的预测路径都可消耗储备；只有当前可见
敌人进入爆炸覆盖时才兑现伤害价值，离开视野的记忆轨迹只形成环境压力。治疗覆盖随缺失生命提高权重。
水母盾只在预测会先于玩家截获威胁弹道时计分。
原版玩家和敌人的碰撞层不与构筑物碰撞；构筑物不参与实体掩体计算。

### 期望武器结果场

`WeaponOutcomeFieldModel` 读取玩家自身武器的 `timing`、`delivery`、`impact` 和 `rules`，估计一个提交期内
自动攻击对下一决策状态的期望修正。它把当前可见敌人与树木表示为连续目标覆盖：目标进入锁定区的程度
随距离平滑变化，近处目标在共享覆盖中的权重更高，但模型不声称已选择某个具体目标。贯穿、弹射和命中后
投送按覆盖目标质量、投送容量与伤害保留率折成期望乘数，不构造逐发、逐弹体、逐碰撞或逐事件传播图。

每次规划按需建立一个移动状态的 `3 × 3` 局部场和一个静止样本。移动场以同时间零输入提交终点为中心，
半径由候选移动速度和提交期派生；同一物理帧内复用目标运动基线与按移动状态投影的武器模型，各格点只
计算候选位置造成的相对响应。移动候选通过双线性插值读取场值，候选加密不会重复展开武器过程。

场值使用长期期望攻击周期而非当前冷却相位；额外长装填会折入平均攻击间隔。这样输出是
下一决策状态的期望修正，不会因某一帧恰好接近开火而产生离散尖峰，也不会把材料重置冷却一类逐发协同
硬编码成移动策略。下一次真实观察会重新构建场。敌人伤害按覆盖分布中的移除价值计分，树木按破坏所需
命中数折算收获进度；总伤害、击杀权重、移除价值和树木价值仍受可见目标总容量约束。

### 截止准入与连续保真度

计算预算以实测物理帧余量和规划成本为输入。`PhysicsFrameBudgetMonitor` 读取 Godot
`Performance.TIME_PHYSICS_PROCESS`。该监视值按已完成渲染帧更新；控制层按
`Engine.get_idle_frames()` 对同一渲染帧只采样一次，并排除包含本次规划的下一监视值世代，以 `0.5 s` 时间
常数维护非规划物理耗时的指数移动平均，并以绝对偏差的指数移动平均表示近期波动。物理帧容量由
`Engine.iterations_per_second` 派生：

```text
单个规划器的规划耗时预算
= max(0, 物理帧容量 - 基线物理耗时 EMA - 2 × 物理耗时偏差 EMA) / 调度规划器数
```

`MovementPlanner` 用 `OS.get_ticks_usec()` 测量从投射物可达性过滤到动作选择完成的主要规划路径。
`PlanningComputeBudgetPolicy` 把本轮帧余量转换成单调时钟截止，并将近期规划耗时占预算的比例平方、截断为
连续预算压力。它只负责时间准入：额外导航评价和局部角度细分仅在预计单项耗时仍容纳于统一最终截止时
启动。搜索保真度决定保留多少动作候选；每个保留候选始终读取同一分辨率的期望武器结果场，并执行相同
的碰撞和事件预测。计算压力不会切换结果语义。

动作角向覆盖上限由玩家碰撞半径和一个提交期的移动距离推导。`PlanningSearchFidelityAllocator` 以此前
规划耗时对当前帧余量的连续压力，以及敌人、投射物、敌对生成警告最早进入玩家可达范围的时间，计算
搜索保真度：
`q = q_min ^ (budget_pressure × (0.5 + 0.5 × normalized_time²))`。最早影响时间以近场时域归一化，因此近场
只承担一半压力、下降斜率较缓，但持续过载时不会无限保留全部宽度；远场较快到达搜索保真度下限。方向数由
`ceil(上限 × q)` 取偶数并保留至少四方向；导航额外评价额度与移动角区间精炼额度都从同一画像派生。
整数化只发生在候选构造边界，不反向形成质量档。

时间采样由碰撞直径、控制期与相关曲线弹最大角频率推导，不随搜索保真度降低。动作搜索从当轮均匀动作
格点与导航偏好方向形成可执行基线，再在优胜动作的相邻角区间递归插入中点。导航与近场的额外工作同时
受曲线额度和统一最终截止约束，避免任一前置阶段通过内部循环耗尽后续计算时间。

`ProjectileReachabilityFilter` 在重复战术扫掠之前，用导航时域内玩家最大位移、可见投射物当前速度、
已观察加速度和已解析曲线速度的保守积分上界判断规划域可达性。不能影响局部可达域的投射物仍保留在
原始观察和遥测中，但不再提高局部时间采样数，也不参与每个动作的重复碰撞计算。敌人尚无适用于全部
规划消费者的统一最大机动能力契约，因此不会从规划观察中全局延后；期望武器结果场只消费当前可见敌人的
短时运动估计，不把不可见目标或运动不确定域扩写成火力收益。

`projectile_filter` 公开过滤结果：`included_projectile_count` 与 `deferred_projectile_count` 分别记录进入
重复规划计算和被延后的投射物数；`horizon_seconds` 是判定使用的有效导航时域；`mode` 记录当前保守距离
判据。
过滤后的观察只在规划包内部传递，不替换采样中的原始公共观察。

敌人运动预测在各消费模块内按“物理帧、轨迹、预测时刻”复用无输入基线；每个候选仍单独计算玩家位移
造成的位置响应反事实。期望武器结果场的移动九格与静止样本只在当前物理帧有效，候选通过插值读取，
不跨帧保留地图或目标状态。

`compute_budget` 公开本轮分配和反馈状态：

| 字段 | 含义 |
| --- | --- |
| `budget_model`、`budget_pressure`、`has_deadline` | 当前使用的帧余量预算模型、由预测预算利用率平方得到的 `[0, 1]` 预算压力，以及本轮是否有可用最终截止 |
| `planning_started_usec`、`planning_deadline_usec` | 规划起点与本轮计算的最终截止 |
| `planning_deadline_overrun_usec` | 实际结束时超过最终截止的微秒数；无帧样本时为 `null` |
| `estimated_work_unit_duration_usec` | `navigation_evaluation` 与 `movement_refinement` 单次额外工作耗时的 EMA |
| `physics_frame_capacity_usec` | 由物理帧率派生的单帧容量 |
| `baseline_physics_duration_usec_ema` | 用于估计非规划负载的物理耗时基线 |
| `physics_duration_deviation_usec_ema` | 物理耗时相对基线的绝对偏差估计 |
| `has_frame_time_sample`、`scheduled_planner_count` | 帧耗时样本是否有效，以及共享余量的规划器数量 |
| `planning_duration_budget_usec` | 分配给单个规划器的本轮耗时预算 |
| `planning_duration_usec`、`planning_duration_usec_ema` | 本轮实测规划耗时及其指数移动平均 |
| `predicted_planning_budget_utilization` | 分配时已知的规划耗时 EMA 与本轮预算之比；用于形成预算压力 |
| `planning_duration_budget_utilization` | 本轮实测耗时与耗时预算之比；大于 `1` 表示超出预算 |

`search_fidelity` 独立公开搜索广度分配：`fidelity_model`、`earliest_physical_influence_seconds`、
`reference_seconds`、`movement_search_fidelity` 与 `navigation_search_fidelity` 解释曲线输入和结果；
`movement_direction_count`、`navigation_direction_count`、`navigation_extra_evaluation_limit` 与
`movement_refinement_limit` 记录曲线在离散候选边界形成的本轮额度。该画像只分配搜索计算，不改变碰撞
时间采样，也不改变敌人、材料、消耗品、构筑物或风险本身的价值。

基础方向之外加入导航偏好方向，并单独加入零移动输入。单步动作空间使用确定性自适应角区间，不需要
模拟退火；若以后允许多个自由动作段，组合数会指数增长，届时再考虑束搜索或交叉熵方法。

Godot 性能监视器按渲染帧而非物理回调更新，因此控制层会去重同一渲染帧，并排除包含规划的监视值世代。
单项耗时 EMA 只能阻止启动预计无法在截止前完成的额外工作，不能中断已经开始的单项计算；基线工作、
首次成本估计、同帧突发负载和监视值更新延迟仍可能造成超预算。预算为零或尚无帧样本时只执行基线工作。

## 模块责任

| 模块 | 责任 | 公共边界 |
| --- | --- | --- |
| `bot/control` | 安排重规划、估计规划帧预算、保存当前计划、采样决策账本，并适配原版 `MovementBehavior` | `AutopilotController.get_current_plan()` 提供计划诊断；`get_decision_sample_path()` 提供当前采样文件；`AutopilotMovementBehavior` 是唯一控制输出 |
| `bot/planning` | 管理导航意图、运动学、速度障碍风险、动作搜索、机会与资源定价及最大效用选择 | `MovementPlanner.plan()`；其余模块是规划包内部协作者 |
| `bot/observation` | 读取当前玩家与可见世界，维护局内观察记忆，组装公共观察 | `ObservationService.get_observation()` |
| `bot/knowledge` | 适配版本数据并编译稳定机制，向观察层提供不含场景节点的语义结果 | 不跨层公开运行时服务，只由观察层调用 |

目录表达依赖与所有权，文件后缀表达组件角色。统一命名规则如下：

| 后缀 | 稳定语义 | 入口动词 |
| --- | --- | --- |
| `Observer` | 读取当前合法状态并形成观察 | `observe` |
| `Adapter` | 按来源或事件域把目标版本存储契约翻译成规范契约 | `adapt` |
| `Compiler` | 分析运行时对象及其资源，把多个具体机制降解为正交规划语义 | `compile` |
| `Profiler` | 融合稳定机制与局内证据形成画像 | `build_profile`、`accumulate_evidence` |
| `Estimator` | 从既有观察估计不可直接测量的当前量 | `estimate` 或状态化 `update` |
| `Predictor` | 沿时间或候选动作推演未来结果 | `predict` 或 `accumulate_outcome` |
| `Projector` | 将同一组已知规则或状态映射到候选表示，不模拟世界演化 | `project` |
| `Model` | 封装可复用的领域关系或评价规律 | 领域动词 |
| `Generator` | 按已给空间与画像构造候选集合，不拥有评价或选择 | `generate`、`make_*` |
| `Selector` | 从已评分候选中选择结果，不拥有预测或评分 | `select` |
| `Planner` | 协调候选生成、预测、评价与选择，产出一个完整决策 | `plan` |
| `Monitor` | 读取运行时监视值，维护平滑状态并公开上下文 | `observe_*`、`build_context` |
| `Filter` | 按明确判据产生输入子集，并公开过滤诊断 | `filter` |
| `Refiner` | 根据已评价候选提出更细的搜索候选，不拥有评价或停止策略 | `propose_*` |
| `Allocator` | 把既有资源信号映射为某一计算维度的本轮额度，不拥有资源测量或行为价值 | `allocate` |
| `Policy` | 根据资源上下文形成计算预算或其他可调策略 | 领域动词，或 `set_frame_budget_context`、`allocate`、`observe_*` |
| `Telemetry` | 按既定采样政策持久化诊断记录，不参与被记录的决策 | `start`、`record_decision`、`close` |

数据仍按其产物命名，例如 `attack_model`、`rule_projection`、`behavior_profile` 和 `navigation_intent`；组件名
则使用上表的角色后缀。这样可以区分“投影结果”与执行投影的 `Projector`，以及导航意图与生成它的
`NavigationIntentPlanner`。`bot/planning` 根目录仍是主要的扁平协作包，因为这些组件共同服务唯一入口
`MovementPlanner`，且存在密集的包内依赖。只有可单独消费的稳定子协议进入子目录：`motion` 拥有“规范
运动观察 → 未来位置”的协议，供暴露、交会、事件与动作采样共同消费；`weapons` 只拥有“攻击模型 →
与目标无关的期望攻击容量”协议，该容量同时由战斗、机会与生命资源模型消费。`WeaponOutcomeFieldModel`
需要组合运动学、敌人运动、机会定价和动作结果账本，因此与其他动作结果协作者一起留在规划根目录。

所有新增能力必须先满足 [玩家权限边界](fair-play.md)。玩家效果的原版字段映射由
`bot/knowledge/player_effects` 拥有，消耗品稳定画像由 `bot/knowledge/pickups` 拥有；公共规则轴及其解释权
属于规划模型，不能随字段数量同步扩张。新增敌人稳定特征或画像规则应放入 `bot/knowledge/enemies`。
新增参与评分的结果维度必须同时定义预测语义和效用权重；新增诊断维度则应明确标注不参与评分。

关键所有权如下：

- `bot/knowledge/allies/ally_mechanic_compiler.gd` 与
  `bot/knowledge/structures/structure_mechanic_compiler.gd` 分别拥有友方实体和构筑物的稳定作用画像。
- `bot/knowledge/weapons/weapon_mechanic_compiler.gd` 拥有目标版本武器状态与资源到 `attack_model` 的映射；
  `bot/planning/weapons/weapon_attack_capacity_model.gd` 统一定义与目标无关的期望主路径攻击率、单次命中
  伤害和生命偷取率；`bot/planning/weapon_outcome_field_model.gd` 负责把这些容量与可见目标投影为下一决策
  状态的局部期望结果场。
- `bot/planning/battlefield_influence_model.gd` 拥有环境暴露、位置域碰撞风险、战斗支援伤害与消耗、友方减压、
  治疗和挡弹时序；
  `bot/planning/navigation_intent_planner.gd` 为尚未兑现的空间机会、地图信息和导航时域环境暴露形成导航偏好。
  规划时间域及其波次剩余时间裁剪由 `bot/planning/movement_timing_model.gd` 唯一定义，体型、
  速度与这些时域形成的共享空间尺度由 `bot/planning/movement_geometry_model.gd` 统一派生；后者区分不会
  随波末收缩的地图探索范围，以及只覆盖波次结束前可行动距离的机会范围和局部预测半径。
- `bot/planning/velocity_obstacle_risk_model.gd` 计算普通 TTC 与已知冲撞扫掠走廊的局部速度空间交会风险，
  最终碰撞风险由动作结果预测器与位置域证据合并；
  `bot/planning/motion/projectile_motion_predictor.gd` 解析积分已形成的确定性弹道，
  `bot/planning/collision_health_impact_model.gd` 把峰值及累计接触证据按原版无敌帧下界换算为预期生命损失与
  终止风险；
  `bot/planning/health_resource_value_model.gd` 根据当前生存余量、近期可达消耗品、
  概率掉落、被动生命变化、生命偷取及剩余暴露时间，统一给掉血、恢复和替代供给计算边际价值；
  `bot/planning/player_kinematics_model.gd` 负责与原版一致的一阶移动和击退衰减。
- `bot/planning/movement_outcome_predictor.gd` 预测动作结果，`bot/planning/movement_utility_model.gd` 把结果转换为
  效用。`bot/planning/opportunity_value_model.gd` 统一换算材料、消耗品、树木和敌人移除机会的边际价值，
  并在每次规划中建立共享敌人移除价值账本；`bot/planning/spatial_opportunity_value_model.gd` 统一计算
  可见与记忆机会沿候选路径的价值，以及动态敌人的同时间反事实价值差。
- `bot/knowledge/stats/stat_metadata.gd` 提供规范属性名和目标版本一级升级增量，
  `bot/knowledge/stats/stat_opportunity_profile_adapter.gd` 适配属性的目标版本机会曲线；
  `bot/planning/stat_opportunity_value_model.gd` 计算属性变化对未来事件机会的边际价值。
- `bot/planning/map_information_value_model.gd` 根据视口、已观察边界、覆盖陈旧度和候选路径计算新观察与
  再观察价值；它不编码探索方向、巡逻路线或地图中心。`bot/planning/player_rule_outcome_predictor.gd` 负责事件触发几何，
  `bot/planning/player_movement_state_projector.gd` 投影候选移动状态造成的属性差量，
  `bot/planning/player_rule_projector.gd` 将规则归约为正交状态；这些模块都不能读取场景节点。
- `bot/observation/observed_world_memory.gd` 聚合每位玩家的实体、敌人轨迹与视野覆盖记忆；实体存在性由
  `bot/observation/remembered_entity_existence_estimator.gd` 估计。观察层只输出语义画像，规划层不读取观察层的
  场景节点或内部实现细节。
- `bot/observation/observed_motion_estimator.gd` 负责跨帧运动测量，
  `bot/planning/motion/observed_motion_predictor.gd` 只负责纯观测运动外推；
  `bot/knowledge/enemies/enemy_motion_mechanic_compiler.gd` 编译稳定目标位置响应与冲撞机制，
  `bot/planning/motion/enemy_motion_predictor.gd` 将观测运动与稳定目标位置响应合并为敌人候选位置预测。
  冲撞时序仍由观察层拥有，候选路径与扫掠走廊的交会则由速度障碍模型拥有；观察层不得反向依赖规划层。
- `bot/observation/enemy_attack_timing_observer.gd` 只拥有当前可见敌人的下一轮齐射与冲撞时间窗。稳定投射物
  攻击配置由 `bot/knowledge/enemies/enemy_mechanic_compiler.gd` 拥有；稳定冲撞配置由
  `bot/knowledge/enemies/enemy_motion_mechanic_compiler.gd` 拥有。两类编译缓存都不得混入战斗期状态。
- `bot/control/physics_frame_budget_monitor.gd` 独占 Godot 性能监视、基线物理耗时与耗时偏差估计，向规划
  边界公开帧预算上下文。
- `bot/planning/planning_compute_budget_policy.gd` 把控制层提供的帧预算上下文转换成统一最终截止与连续预算
  压力，并维护额外工作的耗时估计；`planning_search_fidelity_allocator.gd` 独占从预算压力和物理影响时间到
  搜索保真度及额外工作额度的映射，不拥有行为效用；`projectile_reachability_filter.gd` 只拥有投射物的规划域可达性过滤；
  `adaptive_direction_refiner.gd` 只根据已评分方向提出下一角区间中点，候选构造、评价和停止策略仍归调用方。
- `bot/control/decision_telemetry.gd` 拥有采样频率、JSON Lines 编码、落盘和分片策略；
  `MovementPlanner` 拥有规划结果及其诊断语义，采样器只删除重复画像，不改变保留字段的语义值。

## 算法依据与适用边界

- Khatib 的人工势场提供了实时局部避障的运行成本思想，但普通吸引/排斥势场存在局部极小值问题，因此
  本实现不直接沿暴露梯度控制。
- Fiorini–Shiller 的 Velocity Obstacle 与原版“输入直接决定平移速度”的一阶动力学匹配，用于动态
  圆盘交会；玩家可主动承伤，所以实现采用 TTC 连续松弛而不是硬禁用所有碰撞锥内速度。
- 滚动时域控制负责组合短期运行成本、战斗收益和导航终端价值；离散动作搜索是受限预算的 MPC
  近似，不提供机器人控制意义上的稳定性或安全证明。
- POMDP 的信念状态观点用于区分“已经观察到的世界”与“对当前世界的置信估计”。地图探索不再编码方向，
  而把候选视点带来的新观察和对陈旧覆盖的再观察作为后续决策价值；生命则按可替代供给和生存余量
  形成边际价值。终止碰撞风险使用未折价生命价值，但仍与普通风险及其他动作结果在同一效用账本交换。

主要参考：[Khatib, *Real-Time Obstacle Avoidance for Manipulators and Mobile Robots*
(1986)](https://khatib.stanford.edu/publications/pdfs/Khatib_1986_IJRR.pdf)；[Fiorini & Shiller,
*Motion Planning in Dynamic Environments Using Velocity Obstacles*
(1998)](https://doi.org/10.1177/027836499801700706)；[Kaelbling, Littman & Cassandra,
*Planning and Acting in Partially Observable Stochastic Domains*
(1998)](https://doi.org/10.1016/S0004-3702(98)00023-X)；[Chow et al.,
*Risk-Sensitive and Robust Decision-Making: a CVaR Optimization Approach*
(2015)](https://papers.nips.cc/paper_files/paper/2015/hash/64223ccf70bbb65a3a4aceac37e21016-Abstract.html)。完整 HJ reachability 可以
给出更强安全集合，但其状态维度和实时求解成本不适合当前逐玩家、逐控制期规划预算。

## 尚未完成的验证

整体加载、主链路和多人验证状态由 [README 的“目标环境与验证状态”](../README.md#目标环境与验证状态)
统一维护。本节只列出模型与参数仍缺少的验证：

- 原始压力通道、合成暴露和效用换算尚未由实际伤害、无敌帧与游戏内动作回放完成校准。
- 运动估计的平滑、限幅和衰减参数尚未完成游戏内校准。
- 尚未通过不同设备上的稳态负载、突发负载和多玩家场景校准反馈收敛速度与超预算频率。
