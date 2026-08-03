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

`DecisionTelemetry` 按固定采样政策，把控制器已取得的合法观察和只读规划账本持久化为
JSON Lines。它的责任终止于序列化和存储；计划生成与动作选择归属规划器和控制器。

`PhysicsFrameBudgetMonitor` 读取 Godot 已完成物理帧的耗时。它跳过紧随规划之后的基线样本，维护基线
物理耗时及其偏差，再把帧预算上下文交给规划器。引擎计时止于该边界；动作决策和计算预算准入分别归属
`MovementPlanner` 与 `PlanningComputeBudgetPolicy`。

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

可见树木的 `destructible_profile` 公开稳定的破坏命中需求、基础材料、基础消耗品掉率和是否必掉。它不把
幸运、当前生命或保树效果提前编译进画像；这些玩家状态只在规划层换算成当轮边际价值。

玩家自身的 `movement.velocity` 保留物理体报告的当前速度用于诊断；`movement.knockback_velocity` 则直接
读取原版 `Unit.get_next_velocity()` 使用的击退分量，并且是运动学预测中外部扰动的唯一来源。这样玩家
生成定位导致的单帧物理体速度不会被误判成击退并外推到候选路径。

### 友方角色与构筑物

可见构筑物由 `visible_world.structures` 单独表示，并带有与投射物相同的当前运动字段；这使游走机器人
一类移动作用区也只能按已观察运动外推。`influence.pressure_relief` 描述炮塔射程、地雷一次性爆炸区或
减速场，`influence.healing_support` 描述治疗覆盖；公共画像只公开半径、相对强度、激活约束、是否一次性、
同时目标容量和是否依赖恢复机会。花园已经生成的果实通过可见消耗品参与规划，不把未知冷却或未来产出
提前计分。

其他玩家和宠物统一由 `visible_world.allied_agents` 表示，公开 `kind`、归属玩家、与当前玩家的关系、
可见运动字段和作用画像。规划器消费压力减免区、治疗区、投射物拦截区，以及其他玩家实体碰撞压力；
不接收“战斗支援”“治疗者”“拦截者”等角色标签。没有完整且合法的协作状态契约时，也不产生额外的
靠近收益。

### 敌人行为画像

场景节点只在观察层内部充当连续性标记，不会进入公共观察。敌人的 `behavior_profile` 由
`EnemyMechanicCompiler`、`EnemyVolleyObserver` 和 `EnemyBehaviorProfiler` 依次构建：编译器从可见敌人的
稳定配置编译攻击方式、耐久、射程、弹速、弹量、投放模式、火力强度和击杀收益载荷；齐射观察器形成
当前的下一轮齐射时间窗；画像器再融合本局运动证据和未知内容的发射归因。稳定内容 ID 只作为编译器的
内部缓存键；公共观察不包含内容 ID、场景节点或敌人的当前生命。

因此，具有 `ShootingAttackBehavior` 的可见敌人会立即贡献已确认的远程火力压力，无需等到它在本局
首次开火。敌人节点下常驻的敌方投射物也会编译为 `attached_orbit` 压力并进入可见弹道观察，覆盖
腐化树和 `predator` 一类不经过主敌方投射物容器的危险。对没有标准攻击配置的扩展内容，附近出现并
向外运动的可见敌方投射物仍可作为降级归因；该证据随敌人轨迹保留，并在轨迹过期时消失。

`enemy_tracks[*].behavior_profile` 公开规划所需的稳定机制与观察结论：

| 字段 | 含义 |
| --- | --- |
| `attack_behavior` | 攻击类别、知识来源、置信度、射程、投射物参数、射击间隔、随机边界、投放模式和火力强度 |
| `next_volley_window` | 下一轮齐射时间窗；确定性冷却给出精确时间，随机冷却只给出稳定区间 |
| `durability.maximum_health` | 不读取当前生命时，用于折算保守移除进度的最大生命基准 |
| `contact_damage` | 当前可见敌人的接触伤害 |
| `kill_rewards` | 基础材料、基础消耗品掉率和必掉约束 |
| `kill_rewards.player_stat_changes` | 击杀造成的玩家属性变化 |
| `battlefield_effects` | 每秒生产敌人数、每秒强化激活数、每次强化比例，以及敌我治疗量等战场后果 |
| `removal_effects.visible_projectile_damage` | 与来源一同删除的当前可见投射物原始伤害总量 |

`attack_behavior.knowledge_source` 区分 `stable_mechanics` 与 `observed_emission`。前者是目标版本的稳定
机制知识；后者只在缺少标准机制配置时作为降级证据。

### 地图定位

`localization` 从移动里程计开始。看到左侧或上侧地图边界后，才能逐轴确定地图坐标；其他已见边界
用于补充当前边缘距离和已知地图尺寸。定位不会读取尚未观察到的完整地图位置。

## 机制知识

机制知识按信息所有者适配或编译。外部实体只有通过可见性判定后，才能调用对应知识模块；玩家自身的
透明效果数据则直接进入玩家效果适配边界。

### 敌人机制

`EnemyMechanicCompiler` 在敌人可见后只读取稳定攻击配置。它聚合标准射击行为和敌人子节点的常驻
投射物，输出最小/最大射程、最大弹速、单轮弹量、估计火力强度、投放模式、齐射间隔区间、发射方向/
速度/原点的随机性、静止危险区、死亡清弹规则、最大生命、接触伤害，以及生产敌人或提高敌群生命、伤害、
速度和治疗的稳定数值后果。Boss 已注册的各阶段攻击与普通敌人的附加攻击统一从 `_all_attack_behaviors`
聚合。当前齐射状态由观察层的
`EnemyVolleyObserver` 单独形成 `next_volley_window`：无随机冷却时公开确定时间，随机冷却只公开稳定区间，
不读取本轮已抽取结果。当前目标、当前生命和随机状态不进入结果。

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
| `timing` | 何时能攻击，包括当前冷却、普通周期、长装填相位和移动许可 |
| `delivery` | 能把命中投送给谁，以射程、路径数、角覆盖、走廊宽度、方向误差、路径容量、伤害保留和重定向容量表达 |
| `impact` | 一次基础命中产生多少伤害、暴击和生命偷取，以及受哪些玩家属性缩放 |
| `rules` | 状态转移语言：已定义事件如何变换前三轴或产生结果，由事件、条件和状态变换组成 |

暴击增加贯穿、材料重置冷却、持续伤害、邻近目标伤害、重新选目标伤害和按目标耐久补足伤害都只是
`rules` 中已有轴的组合，不会成为新的决策维度。原版 `Effect` 子类只允许在编译器中决定如何翻译；规划层
只解释事件、条件、目标、操作、数值来源，以及目标与触发位置间的空间和容量约束。

玩家与武器的 `rules` 使用同一 `consequence` 契约：`probability` 表达发生概率，`target` 与 `operation`
表达状态转移，`amount` 是常量及已建模状态量的线性组合，`delivery` 只含是否复用或排除事件目标、是否以
事件实体为锚点、半径和每事件容量。版本知识模块可以识别原版机制来编译这些量，任何规划器都不能据此恢复
或分派机制类别。

### 攻击模型的当前边界与扩展条件

公共攻击模型尚未覆盖以下三类能力。下表同时规定当前行为、重新设计的条件和责任边界；它们不是按内容
名称积累的适配待办：

| 问题 | 当前决策 | 重新打开设计的条件 | 所有者 |
| --- | --- | --- | --- |
| 非武器自主伤害源 | 当前攻击时序只调度玩家武器；不把周期弹幕或击杀派生攻击塞进物品规则特例 | 该来源能在当前预测窗改变移动选择，且能从合法状态确定其下一次触发时刻 | 将 `attack_model` 泛化为通用攻击源的 `bot/knowledge` 机制编译器与攻击预测器 |
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
作用区；它们可以在机制编译边界识别原版类型，但规划层只接收几何、强度、激活、容量和恢复机会约束。
两者都不读取当前目标、冷却、生命或未知的未来产出。

## 滚动规划

规划器采用受计算预算约束的滚动时域控制近似。动作 `u` 的效用由短预测窗内的环境与生命代价、战斗收益、
事件结果和动作窗外的导航终端价值组成。位置域扫掠与速度障碍合并为碰撞证据，再换算为生命损失。每次
提交固定数量的物理 tick，然后用新观察重新求解。

### 决策流程

每次重规划依次执行以下步骤：

1. 控制器提供由实测物理帧耗时形成的帧预算上下文。规划器先用保守位移上界排除在导航时域内无法影响
   玩家可达区域的投射物；敌人因缺少统一机动上界而全部保留。计算预算政策再把每位存活玩家可用的
   帧余量转换为阶段截止和搜索质量级别；时间采样始终保持碰撞分辨率，持续过载时角向基线可以降级。
2. 导航意图规划器以同一终端总价值比较原点、均匀基线方向、正价值机会的精确方向和预算内角区间；
   机会方向提高搜索分辨率。每个终点同时计算材料、恢复、
   树木、敌人、地图信息和环境暴露的价值差。地图项直接使用候选视口覆盖的有效地图面积与未知前沿面积，
   因而未知边界会产生探索价值，边界已知后则自然偏向把更多有效地图和生成警告保持在视野中。只有正
   增益终点会形成移动偏好；规划器不保留空间图或目标状态。
3. 导航风险使用与局部生存效用相同、随生命、防御和波次时限变化的环境风险价格。
   动作生成器离散化本次可提交的移动输入，并补入导航偏好方向；零向量是不输入移动指令的动作。
4. 动作只会执行到下一次重规划。提交期由整数物理 tick 派生；近端预测窗为两个控制步。
   局部默认窗至少包含四个控制步，且足以跨越两个玩家碰撞直径；局部上限再保留三个修正步，
   导航窗再延伸五步。较近威胁不会反向截短时间域。角向分辨率使相邻指令经过一个提交期后的端点间距
   不超过玩家半径；时间采样使相邻玩家位移不超过碰撞直径，确定性曲线弹的相位步长不超过 `π/2`。
5. 全部动作先经过碰撞结果投影；该阶段只遍历敌人和投射物，不计算炮塔、地雷、治疗、拾取或经济规则。
   碰撞风险取位置域扫掠证据与速度空间 TTC 证据的较大值，同一次交会不会因两个检测器都发现它而相加；
   位置域投射物使用扫掠线段，避免高速弹体穿过采样间隙。
6. 碰撞证据先按可见威胁伤害、候选移动状态下的护甲/闪避、命中保护和当前生命换算为预期生命损失。
   只有可能直接结束本局的碰撞形成硬可行域：约束保留最低终止风险等价带。所有普通预期掉血都进入
   统一效用账本，与材料、恢复、交战和信息收益交换。
   八方向基线与导航偏好方向继续完整计分；只有在碰撞几何派生的更细角度提供更低风险逃生能力时，才将
   对应方向加入基线评价，等风险冗余角度不重复运行昂贵预测。
7. 在动作细分截止前，规划器围绕当前高分动作的相邻角区间插入中点，逐个执行碰撞投影和不含武器攻击的
   完整评分。最终可行候选按筛选分数排序；完整质量至少预测前两个候选，受限质量至少预测第一个，其余
   候选仅在最终规划截止前继续预测。未做精确武器预测时，进入射程的敌人移除价值只作为同一战斗价值
   的筛选代理；精确结果出现后代理退出评分。
8. 选择器采用统一账本中总效用最高的动作。新旧方向连续性作为控制切换成本计入账本。控制器提交所选
   移动向量，下一次规划重新读取环境。

### 决策基底

进入最终动作选择的量按责任而不是按数据来源划分为最小基底：环境暴露、碰撞风险、已经实现的事件结果、
局部未实现进度、预测窗外的导航终端值，以及控制连续性。一个事实可以被多个预测器观察，但只能由一个
评分量拥有其决策含义：位置扫掠和 VO 都是碰撞检测证据，合并后才计分；实际拾取消耗品只形成
`expected_recovery`，未触发拾取的靠近才形成 `consumable_recovery_approach_progress`；满血或溢出拾取造成的恢复机会
损失形成 `wasted_consumable_recovery`。材料的实际收集与所有局部材料的价值加权接近分别由
`material_acquisition_value` 和 `material_approach_progress` 拥有；所有候选都相同的被动恢复只
影响规划上下文，不进入动作结果；筛选代理量在武器结果出现后退出评分。

效用模型把评分字段唯一分配给六个决策目标：`survival`、`recovery`、`economy`、`combat`、
`navigation` 和 `control_stability`。调试构建在生成评分上下文时断言同一字段不能进入两个目标；
`objective_utility_breakdown` 公开目标级总账，`field_utility_breakdown` 保留字段级解释。敌人的击杀收益、
直接压力和持续机制后果先合并为敌人移除价值，再由伤害、接近和射程代理共同消费。移动状态产生的材料
周期收益归入 `economy`；护甲、闪避、武器属性和移动速度分别进入生存、攻击与运动学预测器。

规划时间域也有唯一所有者：`MovementTimingModel` 从物理 tick、控制步数、玩家碰撞直径和当前速度
派生提交期、局部动作预测期和导航预测期。当前可见且位于局部可达半径内的静态目标归动作预测器负责；
导航意图只消费不可见记忆与局部范围外的机会，避免在责任交界处遗漏或重复计分。导航敌人机会只
形成终端价值，不替代候选动作的武器几何预测。
动作集合包含离散方向和零输入。目标版本 `Unit.get_move_input()` 将非零移动输入归一化后乘移动速度。

### 结果与诊断

状态为 `ready` 的规划结果同时提供评分账本和只读诊断。顶层 `model` 保存统一时间契约和
本次决策实际使用的派生空间尺度；`selection_diagnostics` 保存最大效用选择方式和候选数量；
`candidate_filter` 保存最低终止碰撞风险、终止风险可行域、被拒绝动作数和裁剪的
冗余方向。这些诊断只解释校准样本和最终选择，不参与效用评分。

以下评分字段按当轮价值上下文换算后进入动作总分：

| 字段 | 含义 |
| --- | --- |
| `material_acquisition_value` | 动作路径实际进入收集半径的可见材料价值 |
| `material_approach_progress` | 对所有尚未拾取的局部材料，按价值聚合的收集半径接近进度 |
| `consumable_recovery_approach_progress` | 尚未触发拾取时，对所有可恢复消耗品按当前可兑现恢复聚合的局部接近进度 |
| `consumed_consumable_recovery_supply` | 拾取消耗品时从地图恢复储备中消耗的恢复量，与实际恢复共同形成当前生命和未来供给的净价值差 |
| `expected_enemy_removal_value_progress` | 预期武器伤害按各敌人的移除价值与最大生命折算后的收益 |
| `enemy_removal_value_approach_progress` | 对所有局部敌人，按移除价值、可击杀性和置信度聚合的接近进度 |
| `enemy_removal_value_in_range` | 尚未运行精确武器预测时，预测终点处进入可用武器范围的敌人移除价值代理 |
| `expected_rule_damage` | 玩家效果规则因拾取、治疗、受击或闪避产生的预期敌人伤害 |
| `expected_recovery` | 候选动作的实际拾取、生命偷取和动作相关事件规则产生的预期恢复量 |
| `expected_stat_upgrade_equivalents` | 效果规则产生的永久或临时属性变化折合成的期望一级升级份数 |
| `expected_stat_opportunity_value` | 属性变化影响未来事件机会所产生的材料等价边际价值 |
| `expected_material_gain` | 暴击击杀等战斗事件直接产生的预期材料，不含地图上已有材料的拾取 |
| `movement_damage_exposure_reduction` | 候选移动状态相对当前状态降低的护甲与闪避伤害暴露，按碰撞风险调制；负值表示暴露增加 |
| `tree_opportunity_progress` | 进入树木攻击范围或向其接近的进度，按材料、幸运修正掉落和保树机会成本折算 |
| `integrated_allied_healing_support` | 动作沿途处于友方治疗或治疗增益覆盖内的累计支援暴露 |
| `integrated_environmental_exposure` | 敌人接近、生成、远程火力、地图边缘和队友阻塞扣除对应减压后的沿途环境暴露；不含碰撞 |
| `expected_health_loss` | 碰撞风险按预测会与该候选交会的最大单次伤害、候选护甲、闪避和命中保护折算的预期生命消耗 |
| `terminal_collision_risk` | 一次命中可能结束本局时保留的终止碰撞风险；用于终止约束和终止效用 |
| `navigation_terminal_value_gain` | 动作方向对齐最佳导航终点时兑现的终端总价值增益 |
| `standing_seconds`、`moving_seconds` | 对应移动状态在预测窗口内的持续时间，只承载该状态的周期材料收益 |
| `heading_continuity` | 新旧移动方向的点积 |

诊断字段解释评分来源，但不直接进入动作总分：

| 字段 | 含义 |
| --- | --- |
| `expected_weapon_damage` | 自动武器对所有敌人的预期总伤害；敌人移除价值另行计分 |
| `integrated_enemy_proximity_pressure` | 敌人距离与记忆不确定性形成的有界累计压力 |
| `integrated_projectile_proximity_pressure` | 敌方投射物位置域扫掠形成的累计邻近压力 |
| `peak_projectile_contact_risk` | 位置域扫掠确认的峰值投射物接触风险 |
| `integrated_spawn_pressure` | 靠近可见敌对生成警告的累计压力 |
| `integrated_edge_pressure` | 靠近已观察地图边缘的累计压力 |
| `peak_enemy_contact_risk` | 按实体物理半径计算的峰值敌人接触风险 |
| `integrated_ranged_attack_pressure` | 暴露在已确认远程攻击范围内的累计压力 |
| `integrated_allied_body_pressure` | 多人模式下靠近其他玩家实体形成的累计阻塞压力 |
| `integrated_allied_pressure_relief` | 构筑物或战斗宠物对相关敌人环境压力的累计原始减压量 |
| `integrated_projectile_interception_relief` | 友方角色先于玩家截获威胁弹道后形成的累计投射物减压 |
| `integrated_hostile_exposure` | 按暴露政策加权后的沿途总敌对暴露 |
| `integrated_exposure_relief` | 受对应敌压上限约束的沿途总减压 |
| `peak_environmental_pressure` | 动作预测中任一采样点的峰值环境暴露 |
| `peak_path_collision_risk` | 位置域采样和扫掠得到的峰值碰撞风险 |
| `initial_environmental_pressure` | 候选动作起点的环境暴露 |
| `terminal_environmental_pressure` | 候选动作预测终点的环境暴露 |
| `mean_environmental_pressure_derivative` | 沿候选动作的平均环境暴露物质导数 |
| `velocity_obstacle_risk` | 候选速度落入敌人、弹体或队友碰撞锥的有界 TTC 证据 |
| `collision_risk` | 位置域峰值碰撞证据与速度空间 TTC 风险的较大值；作为生命资源成本的输入，不直接定价 |
| `enemy_velocity_obstacle_risk` | 与敌人交会的 VO 风险 |
| `projectile_velocity_obstacle_risk` | 与敌方投射物交会的 VO 风险 |
| `ally_velocity_obstacle_risk` | 与其他玩家交会的 VO 风险 |
| `minimum_time_to_collision` | 当前候选速度下最早预测交会时间 |
| `candidate_velocity` | 结合移动输入与已观察击退衰减后的候选平均速度 |
| `maximum_armor_adjusted_hit_damage` | 预测会与候选交会的最强单次伤害经过候选护甲换算后的数值 |
| `weapon_prediction_included` | 标明结果是否包含武器攻击预测，决定筛选代理是否有效 |
| `wasted_consumable_recovery` | 拾取消耗品时因满血或溢出而未转化为当前生命的恢复量；储备损失已由 `consumed_consumable_recovery_supply` 计价 |
| `battlefield_exposure_trace` | 每个预测时刻的位置、原始通道、敌对暴露、减压、环境压力和路径碰撞风险 |
| `expected_attack_hits` | 武器几何预测得到的预期命中数 |
| `expected_recovery_events` | 玩家效果规则预测得到的恢复事件数 |
| `expected_kill_weight` | 预期伤害相对敌人最大生命形成的保守击杀进度 |
| `expected_critical_kill_weight` | 上述进度按武器暴击率折算的暴击击杀证据 |

压力通道先在各自语义内归一化和有界叠加，再按当前生命的边际价格换成公共价值。材料以一单位材料为
基准；普通属性变化按目标版本一级升级所给的属性增量归一化，属性造成的未来机会变化另作边际定价；
敌人移除价值由击杀收益、直接伤害压力、剩余时间内的生产、强化和治疗后果、保留敌人收益及敌人提供的
玩家治疗机会共同计算。

### 暴露与导航意图

底层环境暴露 `P(x,t)` 是位置和时间上的连续启发式运行成本，不声称是物理压力、受伤概率或完整价值函数。
`NavigationIntentPlanner` 只在最长导航时域的可达终点上采样该场，用于选择大方向而非精确避弹。均匀方向
保证没有已知机会时仍能比较空间；所有正价值机会的精确方向避免角向离散遗漏小目标，但只增加候选，
不预选目标。未知边界保留一个导航时域的可探索范围，已知边界则裁剪终点。信息价值只表达继续观察的
预期收益，不把未知区域视为已知安全区。

每个终点聚合动作预测窗之外的材料、恢复、树木、敌人移除机会与地图信息价值。当前可见且局部可达的机会
仍由动作预测器计分；不可见记忆与远场机会由导航拥有。规划结果公开 `movement_preference`、
`terminal_value_gain`、`position_evaluation_count`、`origin_value`、`selected_displacement`、
`selected_value_breakdown`、`sampling_radius`、`local_prediction_radius` 和 `control_distance`，便于验证导航
意图来源。其中 `position_evaluation_count` 包含原点，
`baseline_position_evaluation_count` 与 `budgeted_position_evaluation_count` 分别记录基线和预算内评价次数；
`sampling_radius` 是地图边界裁剪前的候选半径，不声称是实际行进距离。

导航终点的环境暴露按局部生存效用使用的同一动态风险价格计入成本。动作评价仍检查完整路径并执行扫掠
碰撞检测，因此导航终点不会替代局部避障。候选动作还记录环境暴露沿路径的平均变化率
`[P(x(T),T)-P(x(0),0)]/T`，即 `∂P/∂t + v·∇P` 的路径平均。

各通道的抵消关系受语义约束：友方火力只能降低当前敌人接近和远程火力造成的环境暴露，不能抵消尚未
生成的警告；投射物拦截只能降低拦截时刻之后该弹原本会造成的压力。减压不能消除实体接触、地图边缘或
队友阻塞，也不能超过当时对应的敌对压力，因此友方作用区不会产生无上限收益。治疗和治疗增益属于独立
恢复机会，不能抹去已经预测到的伤害压力。

### 动态效用

上下文在每次规划时重建。`HealthResourceValueModel` 根据当前生命、最强可见单次伤害、可见与记忆中的
消耗品、剩余时间内的掉落机会和被动恢复，为当前生命及恢复储备分别计算边际价值。普通碰撞的预期生命
损失始终按该价格进入总账；恢复充足时价格下降，接近终止余量且供给稀缺时价格上升。拾取消耗品会
消耗未来恢复储备，实际恢复量受缺失生命上限约束。

消耗品的治疗价值取当前可兑现恢复。拾取引发的爆炸、属性或材料效果由候选拾取位置上的事件预测器计算；
导航终端值使用消耗品的基础恢复机会。

`OpportunityValueModel` 每帧一次性建立敌人移除价值账本。每个敌人的移除价值等于击杀收益、其直接接触
与远程压力负担、来源死亡可清除的当前投射物、剩余时间内预期新增敌人造成的负担、强化和治疗对现存
敌群的负担，再减去波末保留该敌人的收益及其可给玩家提供的治疗机会。所有项先换成材料等价值；武器
伤害按最大生命比例兑现，接近和导航再乘剩余时间内的可击杀性。
击杀或效果规则造成的属性变化由 `StatOpportunityValueModel` 按当前属性、机会曲线和剩余波次计算边际价值。
账本构造只扫描敌群一次，动作、导航和每次武器目标预测共享结果，避免密集敌群下的二次复杂度。

效用模型对 `integrated_environmental_exposure`、`expected_health_loss` 和
`terminal_collision_risk` 施加生存成本。位置域
`peak_path_collision_risk` 与速度空间 `velocity_obstacle_risk` 取较大值后只作为生命成本的输入，不重复
计分。VO 使用连续 TTC 风险；碰撞约束只拒绝终止风险明显更高的动作，可行域内的所有非终止风险与收益
仍在同一效用账本交换。环境暴露变化率和两类碰撞证据只保留在诊断账本中。敌人轨迹的位置不确定半径
只扩大邻近压力，不扩大 VO 的实体碰撞圆；物理碰撞几何始终使用玩家与敌人的实体半径，避免把“可能
位于某处”误写成“TTC 为零”。

友方作用区进入公共效用账本。炮塔和战斗宠物只有在
预测敌人进入其作用范围且仍对玩家形成近身压力时才产生减压价值；猫炮还要求玩家进入其可见激活区。
地雷按一次性机会计分：当前可见敌人的预测路径用于计算触发和爆炸覆盖，离开视野的记忆轨迹形成环境
压力。治疗覆盖随缺失生命提高权重。水母盾只在预测会先于玩家
截获威胁弹道时计分。
原版玩家和敌人的碰撞层不与构筑物碰撞；构筑物不参与实体掩体计算。

### 武器预测

武器预测读取玩家自身武器的 `timing`、`delivery`、`impact` 和 `rules`，结合最近的合法敌人轨迹计算攻击
时刻、几何命中与事件结果。原版的装填、扩散、贯穿、弹射、近战形态和命中后效果只在机制编译边界变换成
这些量。预测结果只参与移动动作效用。

### 可中断计算预算

计算预算以实测物理帧余量和规划成本为输入。`PhysicsFrameBudgetMonitor` 读取 Godot
`Performance.TIME_PHYSICS_PROCESS`，规划后连续排除三个可能含延迟尖峰的样本，以 `0.5 s` 时间常数维护基线物理
耗时的指数移动平均，并以绝对偏差的指数移动平均表示近期波动。物理帧容量由
`Engine.iterations_per_second` 派生：

```text
单个规划器的规划耗时预算
= max(0, 物理帧容量 - 基线物理耗时 EMA - 2 × 物理耗时偏差 EMA) / 调度规划器数
```

`MovementPlanner` 用 `OS.get_ticks_usec()` 测量从投射物可达性过滤到动作选择完成的主要规划路径。
`PlanningComputeBudgetPolicy` 把本轮帧余量转换成单调时钟截止，并以近期规划耗时占预算的比例选择完整、
受限或临界质量。完整质量使用派生角度、八方向导航和至少两个完整武器预测；受限与临界质量使用八方向
动作、四方向导航和至少一个完整武器预测。预算内导航评价、局部角度细分和其余武器预测只在预计单项耗时
仍容纳于阶段截止时启动。导航评价使用总预算前 `20%`，局部动作细分使用前 `60%`。

完整质量的动作角向覆盖由玩家碰撞半径和一个提交期的移动距离推导；受限质量保留八方向逃生基线。
时间采样由碰撞直径、控制期与相关曲线弹最大角频率推导，所有质量级别保持一致。碰撞筛选随后从八方向动作
格点及必要逃生角度形成可执行基线，并在优胜动作相邻角区间递归插入中点。导航评价在完整质量下从八方向、
受限质量下从四方向开始，再加入所有正价值机会方向并递归细分优胜角区间。二者都由截止时间和
质量级别共同限制。

`ProjectileReachabilityFilter` 在重复战术扫掠之前，用导航时域内玩家最大位移、可见投射物当前速度、
已观察加速度和已解析曲线速度的保守积分上界判断规划域可达性。不能影响局部可达域的投射物仍保留在
原始观察和遥测中，但不再提高局部时间采样数，也不参与每个动作的重复碰撞计算。敌人尚无统一的最大
机动能力契约，因此当前不对敌人做同类过滤，避免把保守性建立在不完整速度假设上。

`projectile_filter` 公开过滤结果：`included_projectile_count` 与 `deferred_projectile_count` 分别记录进入
重复规划计算和被延后的投射物数；`horizon_seconds` 是判定使用的导航时域；`mode` 记录当前保守距离判据。
过滤后的观察只在规划包内部传递，不替换采样中的原始公共观察。

`compute_budget` 公开本轮分配和反馈状态：

| 字段 | 含义 |
| --- | --- |
| `allocation_mode`、`quality_mode`、`has_deadline` | 当前使用的截止准入、搜索质量级别，以及本轮是否已有有效帧耗时样本 |
| `planning_started_usec`、`planning_deadline_usec` | 规划起点与全部预算内计算的最终截止 |
| `navigation_deadline_usec`、`movement_refinement_deadline_usec` | 导航评价和局部移动细分的累计阶段截止 |
| `planning_deadline_overrun_usec` | 实际结束时超过最终截止的微秒数；无帧样本时为 `null` |
| `estimated_work_unit_duration_usec` | `navigation_evaluation`、`movement_refinement`、`weapon_prediction` 单次耗时的 EMA |
| `physics_frame_capacity_usec` | 由物理帧率派生的单帧容量 |
| `baseline_physics_duration_usec_ema` | 用于估计非规划负载的物理耗时基线 |
| `physics_duration_deviation_usec_ema` | 物理耗时相对基线的绝对偏差估计 |
| `has_frame_time_sample`、`scheduled_planner_count` | 帧耗时样本是否有效，以及共享余量的规划器数量 |
| `planning_duration_budget_usec` | 分配给单个规划器的本轮耗时预算 |
| `planning_duration_usec`、`planning_duration_usec_ema` | 本轮实测规划耗时及其指数移动平均 |
| `planning_duration_budget_utilization` | 本轮实测耗时与耗时预算之比；大于 `1` 表示超出预算 |

基础方向之外加入导航偏好方向，并单独加入零移动输入。单步动作空间使用确定性自适应角区间，不需要
模拟退火；若以后允许多个自由动作段，组合数会指数增长，届时再考虑束搜索或交叉熵方法。

Godot 性能监视器可能短暂延迟，因此控制层会跳过规划之后连续三个基线样本。单项耗时 EMA 只能防止启动
预计无法完成的预算内工作，不能中断已经开始的单项计算；基线工作、首次成本估计、同帧突发负载和监视值
更新延迟仍可能造成超预算。预算为零或尚无帧样本时只执行基线工作。

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
| `Planner` | 协调候选生成、预测、评价与选择，产出一个完整决策 | `plan` |
| `Monitor` | 读取运行时监视值，维护平滑状态并公开上下文 | `observe_*`、`build_context` |
| `Constraint` | 根据不可违反的语义边界形成可行域 | `apply` |
| `Pruner` | 删除不增加能力或信息的冗余候选，不改变可行域语义 | `prune` |
| `Filter` | 按明确判据产生输入子集，并公开过滤诊断 | `apply` |
| `Refiner` | 根据已评价候选提出更细的搜索候选，不拥有评价或停止策略 | `propose_*` |
| `Policy` | 根据资源上下文形成计算预算或其他可调策略 | 领域动词，或 `set_frame_budget_context`、`allocate`、`observe_*` |
| `Telemetry` | 按既定采样政策持久化诊断记录，不参与被记录的决策 | `start`、`record_decision`、`close` |

数据仍按其产物命名，例如 `attack_model`、`rule_projection`、`behavior_profile` 和 `navigation_intent`；组件名
则使用上表的角色后缀。这样可以区分“投影结果”与执行投影的 `Projector`，以及导航意图与生成它的
`NavigationIntentPlanner`。`bot/planning` 根目录仍是主要的扁平协作包，因为这些组件共同服务唯一入口
`MovementPlanner`，且存在密集的包内依赖。`bot/planning/motion` 是唯一子目录：它拥有“规范运动观察 →
未来位置”的稳定协议，同时容纳经验运动趋势外推和解析投射物方程，供暴露、交会、事件与动作采样共同
消费。其他协作者在出现第二个独立规划入口或可单独消费的稳定子协议之前继续留在规划根目录。

所有新增能力必须先满足 [玩家权限边界](fair-play.md)。玩家效果的原版字段映射由
`bot/knowledge/player_effects` 拥有，消耗品稳定画像由 `bot/knowledge/pickups` 拥有；公共规则轴及其解释权
属于规划模型，不能随字段数量同步扩张。新增敌人稳定特征或画像规则应放入 `bot/knowledge/enemies`。
新增参与评分的结果维度必须同时定义预测语义和效用权重；新增诊断维度则应明确标注不参与评分。

关键所有权如下：

- `bot/knowledge/allies/ally_mechanic_compiler.gd` 与
  `bot/knowledge/structures/structure_mechanic_compiler.gd` 分别拥有友方实体和构筑物的稳定作用画像。
- `bot/knowledge/weapons/weapon_mechanic_compiler.gd` 拥有目标版本武器状态与资源到 `attack_model` 的映射；
  `bot/planning/weapon_fire_model.gd` 统一定义与目标无关的射击时序和单次命中伤害，
  `bot/planning/weapon_attack_predictor.gd` 负责已获准候选动作的目标几何。
- `bot/planning/battlefield_exposure_model.gd` 拥有环境暴露、位置域碰撞风险、友方减压、挡弹时序和动作诊断；
  `bot/planning/navigation_intent_planner.gd` 为局部预测未拥有的目标和动作窗外的价值形成导航偏好。
  规划时间域由 `bot/planning/movement_timing_model.gd` 唯一定义，体型、
  速度与这些时域形成的共享空间尺度由 `bot/planning/movement_geometry_model.gd` 统一派生。
- `bot/planning/velocity_obstacle_risk_model.gd` 计算局部速度空间交会风险，最终碰撞风险由动作结果预测器与位置域
  证据合并；`bot/planning/motion/projectile_motion_predictor.gd` 解析积分已形成的确定性弹道，
  `bot/planning/collision_health_impact_model.gd` 把合并碰撞证据换算为预期生命损失与终止风险；
  `bot/planning/terminal_collision_constraint.gd` 只拥有可能直接结束本局的终止风险可行域，普通承伤始终由
  效用模型与其他收益交换；`bot/planning/health_resource_value_model.gd` 根据当前生存余量、可见和记忆中的
  消耗品、稳定掉落机会、被动恢复及剩余暴露时间，统一给掉血、恢复和浪费恢复量计算边际价值；
  `bot/planning/movement_candidate_pruner.gd` 只裁剪不增加避碰能力的冗余角度；
  `bot/planning/player_kinematics_model.gd` 负责与原版一致的一阶移动和击退衰减。
- `bot/planning/movement_outcome_predictor.gd` 预测动作结果，`bot/planning/movement_utility_model.gd` 把结果转换为
  效用。`bot/planning/opportunity_value_model.gd` 每帧建立共享敌人移除价值账本，
  `bot/planning/spatial_opportunity_value_model.gd` 在导航终点聚合所有远场机会，
  `bot/knowledge/stats/stat_metadata.gd` 提供规范属性名和目标版本一级升级增量，
  `bot/knowledge/stats/stat_opportunity_profile_adapter.gd` 适配属性的目标版本机会曲线；
  `bot/planning/stat_opportunity_value_model.gd` 计算属性变化对未来事件机会的边际价值。
  `bot/planning/map_information_value_model.gd` 根据视口、已观察边界和候选终点计算可见地图面积及未知前沿
  的预期新增观察量；它不编码探索方向或地图中心。`bot/planning/player_rule_outcome_predictor.gd` 负责事件触发几何，
  `bot/planning/player_movement_state_projector.gd` 投影候选移动状态造成的属性差量，
  `bot/planning/player_rule_projector.gd` 将规则归约为正交状态；这些模块都不能读取场景节点。
- `bot/observation/observed_world_memory.gd` 聚合每位玩家的观察记忆；实体存在性由
  `bot/observation/remembered_entity_existence_estimator.gd` 估计。观察层只输出语义画像，规划层不读取观察层的
  场景节点或内部实现细节。
- `bot/observation/observed_motion_estimator.gd` 负责跨帧运动测量，
  `bot/planning/motion/observed_motion_predictor.gd` 负责规划期外推；观察层不得反向依赖规划层。
- `bot/observation/enemy_volley_observer.gd` 只拥有当前可见敌人的下一轮齐射时间窗；稳定齐射间隔与发射
  随机性仍由 `bot/knowledge/enemies/enemy_mechanic_compiler.gd` 拥有，避免编译缓存混入战斗期状态。
- `bot/control/physics_frame_budget_monitor.gd` 独占 Godot 性能监视、基线物理耗时与耗时偏差估计，向规划
  边界公开帧预算上下文。
- `bot/planning/planning_compute_budget_policy.gd` 把控制层提供的帧预算上下文转换成计算截止，并维护预算内
  工作的耗时估计；`projectile_reachability_filter.gd` 只拥有投射物的规划域可达性过滤；
  `adaptive_direction_refiner.gd` 只根据已评分方向提出下一角区间中点，候选构造、评价和停止策略仍归调用方。
- `bot/control/decision_telemetry.gd` 拥有采样频率、JSON Lines 编码、落盘和分片策略；
  `MovementPlanner` 拥有规划结果及其诊断语义，采样器只删除重复画像和高体积轨迹，不改变保留字段的语义值。

## 算法依据与适用边界

- Khatib 的人工势场提供了实时局部避障的运行成本思想，但普通吸引/排斥势场存在局部极小值问题，因此
  本实现不直接沿暴露梯度控制。
- Fiorini–Shiller 的 Velocity Obstacle 与原版“输入直接决定平移速度”的一阶动力学匹配，用于动态
  圆盘交会；玩家可主动承伤，所以实现采用 TTC 连续松弛而不是硬禁用所有碰撞锥内速度。
- 滚动时域控制负责组合短期运行成本、战斗收益和导航终端价值；离散动作搜索是受限预算的 MPC
  近似，不提供机器人控制意义上的稳定性或安全证明。
- POMDP 的信念状态观点用于区分“已经观察到的世界”与“对当前世界的置信估计”。地图探索不再编码方向，
  而把候选视点减少边界不确定性、保留有效地图视野的量作为后续决策价值；生命则按可替代供给和生存余量
  形成边际价值。终止碰撞风险单独进入可行域，普通风险仍留在效用账本中交换。

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
