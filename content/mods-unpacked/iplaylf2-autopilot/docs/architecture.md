# Autopilot 架构

本文面向维护者，定义 Autopilot 的观察契约、滚动规划流程和模块责任。用户安装与启用说明位于项目
[README](../README.md)；允许使用的信息和控制能力由 [玩家权限边界](fair-play.md) 统一规定，本文不
重复定义该约束。

按修改对象选择阅读入口：公共数据见“观察契约”，决策行为见“滚动规划”，版本知识见“机制知识”，
代码归属见“模块责任”，采样格式和参数证据等级见
[决策采样与模型校准](model-calibration.md)。敌人与投射物的目标版本覆盖范围单独保存在
[原版敌人与投射物机制参考](vanilla-enemy-mechanics.md)；道具和武器的非常规效果审计见
[原版道具与武器机制审计](vanilla-item-weapon-mechanics.md)。

## 运行链路

```text
主场景扩展
├── ObservationService
│   ├── 当前观察：PlayerStateObserver、VisibleWorldObserver
│   ├── 版本知识：bot/knowledge
│   └── 局内记忆：ObservedWorldMemory
└── AutopilotController
    ├── MovementPlanner
    │   ├── 搜索预算与导航图
    │   ├── 动作生成与结果预测
    │   └── 效用评价与动作选择
    ├── DecisionTelemetry
    └── AutopilotMovementBehavior
```

主场景扩展负责管理观察服务和控制器的生命周期。控制器定期读取观察并请求运动计划，只把计划中的
首个移动方向交给 `MovementBehavior`；这是系统唯一的控制边界。速度、碰撞、击退、动画、瞄准、
攻击触发和移动机制均由原版 `Player`、`Unit` 与武器系统负责。

`DecisionTelemetry` 按固定采样政策把观察和规划账本持久化为 JSON Lines，但不参与计划生成或动作选择。
它只接收控制器已经取得的合法观察与只读结果，不形成新的观察入口。

代码依赖保持单向：`control` 依赖 `planning`，`observation` 依赖 `knowledge`，规划层只读取观察字典，
不访问场景节点。`bot/observation/observation_service.gd` 是观察的公共读取入口。

## 观察契约

### 公共入口与顶层结构

启用 Autopilot 且玩家生成后，可以从主场景读取某位玩家的最新观察：

```gdscript
var observation = main.autopilot_observation_service.get_observation(player_index)
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
敌人统一由 `enemy_tracks` 表示：可见时更新测量值，离开视野后根据最后一次速度与衰减加速度
估计位置，并附带距上次出现的时间、置信度和不确定范围。`visual_radius` 通常从精灵尺寸估算，无法读取
时使用默认值；它不是碰撞形状的精确半径。

### 实体记忆与存在信念

`remembered_entities` 永久保存本局中已经合法看见过的材料、消耗品、树和构筑物。记录证明观察确实
发生过；`existence_confidence` 则表示实体现在仍存在的可信程度。时间本身不构成消失证据，置信度下降
也不会删除记录。

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
`EnemyMechanicCompiler` 和 `EnemyBehaviorProfiler` 依次构建：前者从可见敌人的稳定配置编译攻击方式、
耐久、射程、弹速、弹量、投放模式和火力强度，后者再融合本局运动证据以及未知内容的发射归因。稳定
内容 ID 只作为编译器的内部缓存键；公共观察不包含内容 ID、场景节点或敌人的当前生命。

因此，具有 `ShootingAttackBehavior` 的可见敌人会立即成为 `ranged_pressure_source`，无需等到它在本
局首次开火。敌人节点下常驻的敌方投射物也会编译为 `attached_orbit` 压力并进入可见弹道观察，覆盖
腐化树和 `predator` 一类不经过主敌方投射物容器的危险。对没有标准攻击配置的扩展内容，附近出现并
向外运动的可见敌方投射物仍可作为降级归因；该证据随敌人轨迹保留，并在轨迹过期时消失。

`enemy_tracks[*].behavior_profile` 公开规划所需的稳定机制与观察结论：

| 字段 | 含义 |
| --- | --- |
| `attack_behavior` | 攻击类别、知识来源、置信度、射程、投射物参数、投放模式和火力强度 |
| `durability.maximum_health` | 不读取当前生命时采用的保守清理成本 |
| `movement_behavior` | 根据本局可见运动归纳的静止、移动或快速逼近类别 |
| `strategic_roles` | 战利品目标、敌人生产者和远程压力源等可重叠角色 |

`attack_behavior.knowledge_source` 区分 `stable_mechanics` 与 `observed_emission`。前者是目标版本的稳定
机制知识；后者只在缺少标准机制配置时作为降级证据。

### 地图定位

`localization` 从移动里程计开始。看到左侧或上侧地图边界后，才能逐轴确定地图坐标；其他已见边界
用于补充当前边缘距离和已知地图尺寸。定位不会读取尚未观察到的完整地图位置。

## 机制知识

机制知识按信息所有者适配或编译。外部实体只有通过可见性判定后，才能调用对应知识模块；玩家自身的
透明效果数据则直接进入玩家效果适配边界。

### 敌人机制

`EnemyMechanicCompiler` 在敌人可见后读取其稳定攻击配置，覆盖
标准射击行为及敌人子节点常驻投射物的最小/最大射程、最大弹速、单轮弹量、估计火力强度、投放模式、
静止危险区和死亡时清除投射物的规则，并提供最大生命作为保守清理成本。Boss 已注册的各阶段攻击和
普通敌人的附加攻击统一从 `_all_attack_behaviors` 聚合；当前阶段、冷却剩余、当前目标、当前生命和
随机状态不进入结果。

目标版本的敌人清单、投射物形态、实现映射和升级复核步骤见
[原版敌人与投射物机制参考](vanilla-enemy-mechanics.md)。版本兼容信息独立于架构契约维护。

### 玩家效果规则

原版先把玩家携带内容聚合为 `effects`。`bot/knowledge/player_effects` 是这套目标版本存储格式的适配边界，
只把已理解的字段翻译为统一规则。每条规则由事件、作用于事件载荷的条件和状态变换组成；条件描述可组合
事实，状态变换使用 `target`、`operation` 和参数表达，可比较结果则映射到少量 `outcome_channels`。规则
支持范围由这些正交轴定义，不以角色、物品、武器或扩展内容的目录衡量。

`PlayerRuleProjector` 沿上述轴产生恢复、生存、动作状态与事件结果通道的规则投影，结果预测器则把
同一规则应用到候选路径。两者都不能读取原版字段名或内容 ID。可见消耗品同样只公开基础恢复量和语义
特征；实体特征由通用条件匹配，不以“能否触发某项机制”的布尔字段扩张观察契约。

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
名称积累的兼容待办：

| 问题 | 当前决策 | 重新打开设计的条件 | 所有者 |
| --- | --- | --- | --- |
| 非武器自主伤害源 | 当前攻击时序只调度玩家武器；不把周期弹幕或击杀派生攻击塞进物品规则特例 | 该来源能在当前预测窗改变移动选择，且能从合法状态确定其下一次触发时刻 | 将 `attack_model` 泛化为通用攻击源的 `bot/knowledge` 机制编译器与攻击预测器 |
| 目标条件伤害 | `impact` 只使用当前公共目标画像可表达的量；敌人当前生命受权限契约排除，因此精确击杀、按当前生命追加伤害和依赖当前状态的连锁不参与预测 | 新增条件是允许观察且能跨内容复用的目标事实 | `bot/observation` 的统一目标响应画像；版本映射模块不得自行读取目标状态 |
| 命中后的运动反馈 | 当前动作内的敌人轨迹不因尚未发生的击退、减速或扩散效果而改写；下一次重规划使用新观测 | 游戏内回放能校准通用状态转移，并证明它会实质改变动作排序 | 运动观察与动作期状态转移预测器共同拥有，不能由单个效果修补轨迹 |

没有单独列为扩展点的行为已经由现有契约决定：击杀价值只使用最大生命形成的保守进度；一次攻击只对其
预测时刻已存在的合法目标计分，不猜测返程前可能新入场的实体；预测窗外的周期属性、波间收益和随机升级
不提前计分，实际生效后由下一次观察和重规划自然接管。

新增能力优先组合已有的事件、条件、状态变换和结果通道。只有共享模型缺少必要表达能力时才扩展正交轴，
并使现有规则能够自然复用。目标版本字段映射只是局部兼容代码；本文只描述规则轴、预测语义和扩展条件，
按内容核对的版本覆盖分别由两份原版机制参考与审计文档维护。

### 友方与构筑物作用画像

`AllyMechanicCompiler` 与 `StructureMechanicCompiler` 把可见玩家、宠物和构筑物编译为同一类数值化
作用区；它们可以在机制编译边界识别原版类型，但规划层只接收几何、强度、激活、容量和恢复机会约束。
两者都不读取当前目标、冷却、生命或未知的未来产出。

## 滚动规划

规划器采用针对游戏目标、受计算预算约束的滚动时域控制近似，而不是纯人工势场控制器。对动作 `u` 的
比较可概括为：短预测窗内累计运行成本与战斗收益，加上速度障碍碰撞风险，再加全图导航图形成的终端
价值。每次只提交未来 0.1 秒的移动输入，然后用新观察重新求解。

### 决策流程

每次重规划依次执行以下步骤：

1. 预算政策根据敌人、投射物，以及友方作用源与它们形成的交互工作量分配搜索预算。
2. 自适应导航图覆盖当前合法认知到的地图范围。近场径向步长由角色碰撞半径、一次控制周期可达距离和
   伤害加权交战能力共同推导；精细区域半径由预测窗可达距离、拾取范围及有效交战范围共同决定，之后环带
   随距离逐步变疏。每个节点把当前与未来环境暴露转换成非负通行成本，把材料、治疗、战略目标以及
   节点处的预期火力输出转换成终端收益。
3. 导航图逐层执行 Bellman 最短路递推，得到累计 `path_cost`、父节点和 `route_value`，因而远场目标
   必须支付中间暴露带的代价。动作生成器离散化本次可提交的移动输入；零向量是不输入移动指令的动作。
4. 动作只会执行到下一次 0.1 秒重规划。用于风险比较的预测窗由最近敌人或弹道的预计交会时间决定，
   限制在 0.18–0.7 秒；预测点近时密、远时疏。
5. 所有动作先预测环境暴露、碰撞、拾取、玩家效果规则、接近、跑图和动作状态结果。碰撞风险取位置域
   扫掠证据与速度空间 TTC 证据的较大值，同一次交会不会因两个检测器都发现它而相加；位置域投射物
   使用扫掠线段，避免高速弹体穿过采样间隙。
6. 筛选评分最高的固定数量动作再进行自动武器攻击结果预测。
   `targets_in_weapon_range` 只在筛选时代理尚未
   计算的攻击结果，包含武器预测的评分不再叠加该代理量。
7. 选择器按候选分数跨度定义近优带并带权选择，因此给所有动作增加同一个常量不会改变选择；控制器提交
   所选移动向量，下一次规划重新读取环境。

### 决策基底

进入最终动作选择的量按责任而不是按数据来源划分为最小基底：环境暴露、碰撞风险、已经实现的事件结果、
局部未实现进度、预测窗外的导航终端值，以及控制连续性。一个事实可以被多个预测器观察，但只能由一个
评分量拥有其决策含义：位置扫掠和 VO 都是碰撞检测证据，合并后才计分；实际拾取消耗品只形成
`expected_recovery`，未触发拾取的靠近才形成 `recovery_approach_progress`；所有候选都相同的被动恢复只
影响规划上下文，不进入动作结果；筛选代理量在武器结果出现后退出评分。

效用模型把评分字段唯一分配给六个决策目标：`survival`、`recovery`、`economy`、`combat`、
`navigation` 和 `control_stability`。运行时断言禁止同一字段进入两个目标；
`objective_utility_breakdown` 公开目标级效用总账，`field_utility_breakdown` 保留字段级解释。
敌人角色带来的附加后果都属于同一个 `combat` 目标，不冒充彼此正交的顶层目标。
移动状态同样不是目标：材料周期收益归入 `economy`，
护甲、闪避、武器属性和移动速度分别进入拥有其结果的生存、攻击与运动学预测器。

三个时间区间也有唯一所有者：`MovementPlanningTiming` 定义 0.1 秒提交期、最长 0.7 秒局部动作预测期
和最长 1.2 秒导航预测期。导航图在局部预测可达半径内的终端收益权重为零，只补充动作预测窗外的残余
价值；局部可达的静态目标完全交给动作预测器，治疗和交战也只能从局部窗口结束后的持续价值开始计入。
动作集合只离散化方向和零输入，不遗漏独立的“力度”轴：目标版本 `Unit.get_move_input()` 会把任何非零
移动输入归一化后乘移动速度，非零向量的长度不会产生不同控制结果。

### 结果与诊断

状态为 `ready` 的规划结果同时提供评分账本和只读诊断。顶层 `model` 保存模型修订号、统一时间契约和
本次决策实际使用的派生空间尺度；`selection_diagnostics` 保存候选分数跨度、近优带、温度、随机种子、
随机抽样位置和所选概率。这些诊断只用于区分校准样本和解释最终选择，不参与效用评分。

以下评分字段与动态权重相乘后进入动作总分：

| 字段 | 含义 |
| --- | --- |
| `material_acquisition_value` | 动作对可见材料的拾取、吸附或接近形成的折算获取价值 |
| `recovery_approach_progress` | 尚未触发拾取时，向可恢复消耗品靠近的局部进度；实际拾取不进入此字段 |
| `expected_weapon_damage` | 自动武器对所有敌人的预期总伤害 |
| `expected_effect_damage` | 玩家效果规则因拾取、治疗、受击或闪避产生的预期敌人伤害 |
| `expected_recovery` | 候选动作的实际拾取、生命偷取和动作相关事件规则产生的预期恢复量 |
| `expected_stat_change_value` | 效果规则产生的永久或临时属性变化的期望归一化价值 |
| `expected_material_gain` | 暴击击杀等战斗事件直接产生的预期材料，不含地图上已有材料的拾取 |
| `movement_damage_exposure_reduction` | 候选移动状态相对当前状态降低的护甲与闪避伤害暴露，按碰撞风险调制；负值表示暴露增加 |
| `expected_producer_damage` | 自动武器对生产型敌人的预期伤害 |
| `expected_loot_target_damage` | 自动武器对战利品目标的预期伤害 |
| `ranged_source_suppression_value` | 预期伤害占最大生命的比例，再按稳定火力和死亡时清除投射物的收益加权 |
| `producer_approach_progress` | 对生产型敌人的相对接近进度 |
| `loot_target_approach_progress` | 对战利品目标的相对接近进度 |
| `ranged_source_engagement_progress` | 缩短与远程压力源之间超出自有武器射程部分的进度 |
| `tree_attack_opportunity` | 进入树木攻击范围或向其接近的价值 |
| `integrated_allied_healing_support` | 动作沿途处于友方治疗或治疗增益覆盖内的累计支援暴露 |
| `integrated_environmental_exposure` | 敌人接近、生成、远程火力、地图边缘和队友阻塞扣除对应减压后的沿途环境暴露；不含碰撞 |
| `collision_risk` | 位置域峰值碰撞证据与速度空间 TTC 风险的较大值 |
| `navigation_guidance_alignment` | 移动向量与导航图建议首步方向的一致程度 |
| `roaming_progress` | 没有导航建议时，动作预测位移形成的探索后备值；存在导航终端时为零 |
| `standing_seconds`、`moving_seconds` | 对应移动状态在预测窗口内的持续时间，只承载该状态的周期材料收益 |
| `heading_continuity` | 新旧移动方向的点积 |

诊断字段解释评分来源，但不直接进入动作总分：

| 字段 | 含义 |
| --- | --- |
| `integrated_enemy_proximity_pressure` | 敌人距离与记忆不确定性形成的有界累计压力 |
| `integrated_projectile_proximity_pressure` | 敌方投射物位置域扫掠形成的累计邻近压力 |
| `peak_projectile_contact_risk` | 位置域扫掠确认的峰值投射物接触风险 |
| `integrated_spawn_pressure` | 靠近可见敌对生成警告的累计压力 |
| `integrated_edge_pressure` | 靠近已观察地图边缘的累计压力 |
| `peak_enemy_contact_risk` | 按实体物理半径计算的峰值敌人接触风险 |
| `integrated_ranged_source_pressure` | 暴露在已确认远程压力源范围内的累计压力 |
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
| `enemy_velocity_obstacle_risk` | 与敌人交会的 VO 风险 |
| `projectile_velocity_obstacle_risk` | 与敌方投射物交会的 VO 风险 |
| `ally_velocity_obstacle_risk` | 与其他玩家交会的 VO 风险 |
| `minimum_time_to_collision` | 当前候选速度下最早预测交会时间 |
| `candidate_velocity` | 结合移动输入与推断击退衰减后的候选平均速度 |
| `targets_in_weapon_range` | 预测末端进入可用武器范围的敌人权重；只在筛选时作为评分代理，包含武器预测时仅供诊断 |
| `weapon_prediction_included` | 标明结果是否包含武器攻击预测，决定筛选代理是否有效 |
| `battlefield_exposure_trace` | 每个预测时刻的位置、原始通道、敌对暴露、减压、环境压力和路径碰撞风险 |
| `expected_attack_hits` | 武器几何预测得到的预期命中数 |
| `expected_recovery_events` | 玩家效果规则预测得到的恢复事件数 |
| `expected_kill_weight` | 预期伤害相对敌人最大生命形成的保守击杀进度 |
| `expected_critical_kill_weight` | 上述进度按武器暴击率折算的暴击击杀证据 |

这些量是可解释的启发式结果，不都具有相同物理单位。压力通道先在各自语义内归一化和有界叠加，再由
暴露政策分别形成环境暴露与碰撞证据；拾取、伤害、战略接近和移动机制仍作为暴露场之外的目标效用。
生产者、战利品目标和远程压力源是可重叠后果而不是正交敌人分类：基础伤害只计一次，各角色字段仅表达
该伤害额外消除的生产、战利品或远程火力后果。因此新增角色必须证明有独立后果，不能只换一个敌人标签。

### 暴露与导航价值

底层环境暴露 `P(x,t)` 是位置和时间上的连续启发式运行成本，不声称是物理压力、受伤概率或完整价值函数。
`NavigationValueGraphBuilder` 在其上构造并求解自适应状态成本图。已知四侧边界后，远场环带覆盖整张
地图；边界尚未发现时，只覆盖可见范围和已观察实体记录形成的认知包络，不把未知区域视为已知安全区。

近场分辨率会随实际移动速度、0.1 秒控制周期、角色尺寸和伤害加权交战能力变化。该能力估计综合武器
`timing`、路径数、方向误差、角覆盖、走廊宽度、路径与重定向容量、伤害保留及 `impact`，而不是把
最大射程或某种武器类别当成交战能力。每个导航节点还针对届时的敌人数量和距离估算预期攻击数、命中数
与伤害，因此走位会比较实际火力收益。

远场角向和径向单元随距离扩大，用于选择大方向而非精确避弹。动作评价仍直接查询连续场，避免远场粗
网格污染局部碰撞判断。局部预测半径内的节点仍参与路径成本，但其终端收益为零；跨出该半径后终端收益
才逐步生效。规划结果同时公开推导出的 `near_node_spacing`、`local_detail_radius`、`local_prediction_radius`、
`control_distance`、`engagement_capacity` 和 `current_engagement_estimate`，便于验证空间尺度是否合理；
每个节点的 `engagement_estimate` 则记录该位置的预计攻击数、命中数和伤害。

每个固定地图节点保存当前环境暴露、预测环境暴露和近似欧拉导数 `∂P/∂t`。候选动作另外诊断
`[P(x(T),T)-P(x(0),0)]/T`，它是沿动作的平均物质导数，对应 `∂P/∂t + v·∇P` 的路径平均。预测时刻
按节点距离自适应，并最多外推 1.2 秒；这描述场如何变化，不表示角色承诺移动到该节点。各通道的正负
关系受语义约束：友方火力只能抵消当前敌人接近和远程火力形成的环境暴露，不能抵消尚未生成的警告；
投射物拦截只能抵消拦截时刻之后该弹的反事实弹道压力。
任何减压都不能消除实体接触、地图边缘或队友阻塞，也不能超过当时对应敌压。
因此，友方作用区不能产生无上限的正收益。治疗和治疗增益是独立的恢复机会效用，不会
抹掉已经预测到的伤害压力。

### 动态效用

权重在每次规划时重建。波次接近结束时，可见材料和战利品目标价值上升，危险成本下降；生产型敌人的
提前处理价值随剩余时间增加。生命比例、护甲、闪避和恢复共同形成风险容忍度；规则投影产生的事件价值、
状态变化和长期保留价值通过同一账本调整对应结果，不切换到内容专属策略。

远程压力源同样不触发硬编码目标模式。剩余时间较长时，对压力源的预期伤害和进入自有武器射程具有
额外清理价值，并按预期伤害占最大生命的比例、稳定火力强度和死亡时清除投射物的收益计分。低生命、
低防御或可见弹幕密集时，接敌意愿下降，持续处于该敌人稳定攻击范围内的成本上升；具体投射物的扫掠
危险始终另行计入。因而规划器可以在可控时创造自动攻击机会，也可以在接敌成本超过收益时拉开距离或
选择更安全的侧向动作。

效用模型只对 `integrated_environmental_exposure` 和统一的 `collision_risk` 施加生存成本。前者不含实体
或弹体碰撞；后者取位置域 `peak_path_collision_risk` 与速度空间 `velocity_obstacle_risk` 的较大值，而不是相加。
VO 使用连续 TTC 风险而不是硬排除集合，因此高收益且风险可控的主动承伤动作仍可参与比较。环境暴露
导数和两个碰撞检测器的原始结果只保留为诊断账本。

友方作用区同样进入公共效用账本，而不切换到独立的“守塔”或“跟宠物”模式。炮塔和战斗宠物只有在
预测敌人进入其作用范围且仍对玩家形成近身压力时才产生减压价值；猫炮还要求玩家进入其可见激活区。
地雷按一次性机会计分，治疗覆盖随缺失生命提高权重，水母盾只在预测先于玩家截获威胁弹道时计分。
原版玩家和敌人的碰撞层不与构筑物碰撞，因此构筑物不会被误当成能挡路、挡弹或卡怪的实体掩体。

### 武器预测

武器预测读取玩家自身武器的 `timing`、`delivery`、`impact` 和 `rules`，结合最近的合法敌人轨迹计算攻击
时刻、几何命中与事件结果。原版的装填、扩散、贯穿、弹射、近战形态和命中后效果只在机制编译边界变换成
这些量，不成为规划分支。预测是只读结果，只为移动动作提供效用，不选择瞄准目标、触发攻击或修改武器。

### 搜索预算

预算政策使用以下规划负载代理：

```text
敌人轨迹数 + 可见投射物数
+ (敌人数 × 友方作用源数 + 投射物数 × 有效拦截区数) / 8
```

| 等级 | 规划负载 | 基础方向 | 时间采样 | 武器预测上限 |
| --- | ---: | ---: | ---: | ---: |
| 正常 | `< 140` | 16 | 6 | 10 |
| 繁忙 | `140–319` | 12 | 4 | 6 |
| 极端 | `≥ 320` | 8 | 3 | 4 |

暴露场中敌人与友方作用源、投射物与有效拦截区存在交互项，其余筛选成本随动作数、采样数和实体数线性增长；
武器预测只作用于固定短名单。`search_budget` 同时公开原始威胁计数、作用源数、交互负载和总规划
负载。

基础方向之外加入导航价值图的最优首步方向，并单独加入零移动输入。单步动作空间不需要模拟
退火；若以后允许多个自由动作段，组合数会指数增长，届时应优先考虑束搜索或交叉熵方法。

这些等级是计数启发式，不是 Godot 帧耗时测量。`search_budget` 会公开实际等级、计数和上限，供后续
以性能监视器或帧时间反馈替换政策。

## 模块责任

| 模块 | 责任 | 公共边界 |
| --- | --- | --- |
| `bot/control` | 安排重规划、保存当前计划、采样决策账本，并适配原版 `MovementBehavior` | `AutopilotController.get_current_plan()` 提供计划诊断；`get_decision_sample_path()` 提供当前采样文件；`AutopilotMovementBehavior` 是唯一控制输出 |
| `bot/planning` | 管理导航价值图、运动学、速度障碍风险、动作搜索、效用评分和近优选择 | `MovementPlanner.plan()`；其余模块是规划包内部协作者 |
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
| `Builder` | 构造并求解一个复合数据产物 | `build` |
| `Policy` | 根据当前负载或状态分配限制 | `allocate` |
| `Telemetry` | 按既定采样政策持久化诊断记录，不参与被记录的决策 | `start`、`record_decision`、`close` |

数据仍按其产物命名，例如 `attack_model`、`rule_projection`、`behavior_profile` 和 `navigation_graph`；组件名
则使用上表的角色后缀。这样可以区分“投影结果”与执行投影的 `Projector`，以及“导航图”与构造它的
`Builder`。`bot/planning` 当前保持单一目录，因为这些协作者共同服务唯一入口 `MovementPlanner`，并存在
密集的包内依赖；在出现第二个独立规划入口或可单独消费的稳定子协议之前，拆分子目录只会制造未经契约
支持的结构边界。

所有新增能力必须先满足 [玩家权限边界](fair-play.md)。玩家效果的版本字段映射由
`bot/knowledge/player_effects` 拥有，消耗品稳定画像由 `bot/knowledge/pickups` 拥有；公共规则轴及其解释权
属于规划模型，不能随字段数量同步扩张。新增敌人稳定特征或画像规则应放入 `bot/knowledge/enemies`。
新增参与评分的结果维度必须同时定义预测语义和效用权重；新增诊断维度则应明确标注不参与评分。

关键所有权如下：

- `bot/knowledge/allies/ally_mechanic_compiler.gd` 与
  `bot/knowledge/structures/structure_mechanic_compiler.gd` 分别拥有友方实体和构筑物的稳定作用画像。
- `bot/knowledge/weapons/weapon_mechanic_compiler.gd` 拥有目标版本武器状态与资源到 `attack_model` 的映射；
  `bot/planning/weapon_engagement_model.gd` 统一定义聚合交战能力，
  `bot/planning/weapon_attack_predictor.gd` 负责短名单动作的目标几何。
- `bot/planning/battlefield_exposure_model.gd` 拥有环境暴露、位置域碰撞风险、友方减压、挡弹时序和动作诊断；
  `bot/planning/navigation_value_graph_builder.gd` 只在局部动作窗外提供终端价值并求解 Bellman 累计价值，
  三段时间边界由 `bot/planning/movement_planning_timing.gd` 唯一定义，体型、速度与这些时域形成的共享
  空间尺度由 `bot/planning/movement_scale_model.gd` 统一派生。
- `bot/planning/velocity_obstacle_risk_model.gd` 计算局部速度空间交会风险，最终碰撞风险由动作结果预测器与位置域
  证据合并；
  `bot/planning/player_kinematics_model.gd` 负责与原版一致的一阶移动和击退衰减。
- `bot/planning/movement_outcome_predictor.gd` 预测动作结果，`bot/planning/movement_utility_model.gd` 把结果转换为
  效用。`bot/planning/player_rule_outcome_predictor.gd` 负责事件触发几何，
  `bot/planning/player_movement_state_projector.gd` 投影候选移动状态造成的属性差量，
  `bot/planning/player_rule_projector.gd` 将规则归约为正交状态与结果通道；这些模块都不能读取场景节点。
- `bot/observation/observed_world_memory.gd` 聚合每位玩家的观察记忆；实体存在性由
  `bot/observation/remembered_entity_existence_estimator.gd` 估计。观察层只输出语义画像，规划层不读取观察层的
  场景节点或内部实现细节。
- `bot/observation/observed_motion_estimator.gd` 负责跨帧运动测量，
  `bot/planning/observed_motion_predictor.gd` 负责规划期外推；观察层不得反向依赖规划层。
- `bot/planning/search_budget_policy.gd` 单独负责计算降级，便于以后用帧时间反馈替换计数政策。
- `bot/control/decision_telemetry.gd` 拥有采样频率、JSON Lines 编码、落盘和分片策略；它不复制规划公式，
  模型修订号及本次实际参数由 `MovementPlanner` 提供。

## 算法依据与适用边界

- Khatib 的人工势场提供了实时局部避障的运行成本思想，但普通吸引/排斥势场存在局部极小值问题，因此
  本实现不直接沿暴露梯度控制。
- Fiorini–Shiller 的 Velocity Obstacle 与原版“输入直接决定平移速度”的一阶动力学匹配，用于动态
  圆盘交会；玩家可主动承伤，所以实现采用 TTC 连续松弛而不是硬禁用所有碰撞锥内速度。
- Dijkstra/Bellman 最短路原则用于在自适应分层图上累计中途成本，避免只看目标节点的暴露。
- 滚动时域控制负责组合短期运行成本、战斗收益和导航终端价值；离散动作搜索是受限预算的 MPC
  近似，不提供机器人控制意义上的稳定性或安全证明。

主要参考：[Khatib, *Real-Time Obstacle Avoidance for Manipulators and Mobile Robots*
(1986)](https://khatib.stanford.edu/publications/pdfs/Khatib_1986_IJRR.pdf)；[Fiorini & Shiller,
*Motion Planning in Dynamic Environments Using Velocity Obstacles*
(1998)](https://doi.org/10.1177/027836499801700706)；[Dijkstra, *A Note on Two Problems in Connexion with
Graphs* (1959)](https://www.cs.yale.edu/homes/lans/readings/routing/dijkstra-routing-1959.pdf)；[Sethian 的
Eikonal/Fast Marching 工作](https://pmc.ncbi.nlm.nih.gov/articles/PMC39986/)。完整 HJ reachability 可以
给出更强安全集合，但其状态维度和实时求解成本不适合当前逐玩家、逐 0.1 秒规划预算。

## 验证状态

- 原始压力通道、合成暴露和动态权重尚未由实际伤害、无敌帧与游戏内动作回放完成校准。
- 运动估计的平滑、限幅和衰减参数尚未完成游戏内校准。
- 负载等级仍是实体计数启发式，尚未使用 Godot 性能监视器或实测帧时间。
- 观察、规划和控制尚未完成游戏内加载与行为验证。
