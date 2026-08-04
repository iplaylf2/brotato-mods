# Autopilot 模块边界与责任

本文面向修改目录归属、依赖方向或公共入口的维护者。运行链路、观察字段和规划语义由
[架构文档](architecture.md) 定义；信息与控制权限由 [玩家权限边界](fair-play.md) 定义。本文只维护代码
所有权和跨模块契约，不重复算法说明。

## 运行时边界与依赖

| 模块 | 责任 | 公共边界 |
| --- | --- | --- |
| `mod_main.gd` | 安装主场景扩展，接入 Mod Loader 配置并发布启用状态 | `is_enabled()` 与 `enabled_changed`；不创建战斗期观察或规划对象 |
| `extensions/main.gd` | 作为组合根响应玩家生成、启用切换和房间清理，按顺序创建或停止观察服务与控制器 | 主场景上的 `autopilot_observation_service` 与 `autopilot_controller` 只提供诊断入口；不承载观察或规划语义 |
| `bot/control` | 调度重规划、提交与观察状态隔离的规划值快照、估计规划帧预算、以信号量驱动的单一工作线程执行规划、保存当前计划、采样决策账本，并适配原版 `MovementBehavior` | `AutopilotController.initialize()`、`shutdown()` 和计划诊断入口；`AutopilotMovementBehavior` 是唯一控制输出，`PlanningWorker` 是控制包内部协作者 |
| `bot/planning` | 管理导航意图、运动学、碰撞证据、动作搜索、机会与资源定价及最大效用选择 | `MovementPlanner.set_frame_budget_context()` 与 `plan()`；`MovementTimingModel.control_interval_seconds()` 是控制层共享的调度契约，其余组件是规划包内部协作者 |
| `bot/observation` | 读取当前玩家与可见世界，维护局内观察记忆，组装公共观察 | `ObservationService.initialize()` 接入主场景与玩家；`get_observation()` 提供防御性副本；`get_planning_observation()` 截取不含场景节点并与观察状态隔离的规划值快照 |
| `bot/knowledge` | 适配版本数据并编译稳定机制，向观察层提供不含场景节点的语义结果 | 不跨层公开运行时服务，只由观察层调用 |

依赖从组合根向领域边界单向展开：`mod_main.gd → extensions/main.gd`，主场景扩展再依赖 `control` 与
`observation`；`control → observation`、`control → planning`，`observation → knowledge`。`planning` 只接收
已经移除场景节点的观察字典，不反向依赖 `control`、`observation` 或 `knowledge`。控制层对
`MovementTimingModel` 的依赖只共享重规划间隔；时域派生及其解释权仍属于规划包。

所有新增能力必须先满足玩家权限边界。玩家效果的原版字段映射由 `bot/knowledge/player_effects` 拥有，
消耗品稳定画像由 `bot/knowledge/pickups` 拥有；公共规则轴及其解释权属于规划模型，不能随原版字段数量
同步扩张。新增敌人稳定特征或画像规则应放入 `bot/knowledge/enemies`。新增评分维度必须同时定义预测
语义和效用权重；新增诊断维度则应明确不参与评分。

## 规划包的子目录边界

`bot/planning` 根目录是主要协作包：其中大多数组件共同服务规划入口 `MovementPlanner`，并存在密集的包内依赖。
只有可单独消费的稳定子协议进入子目录：

- `motion` 拥有“规范运动观察与稳定响应 → 未来位置和可达包络”的协议，供暴露、交会、事件与动作采样
  共同消费；
- `weapons` 拥有“攻击模型 → 与目标无关的期望攻击容量”的协议，供战斗、机会与生命补充模型消费；
- `health` 拥有“碰撞证据 → 条件生命损失与直接终止风险”和“当前生命、即时威胁与清场前补充 →
  生命库存及单位价值”两段协议，结果供导航风险和动作效用共同消费；
- `engagement` 拥有统一可交战目标投影、敌人完成价值账本、本波共享主路径容量分配、动作条件武器结果
  预测与容量守恒，以及候选终点的武器聚群结果五项协议。

根目录只保留组合多个稳定子协议的规划协作者；`engagement` 子目录不拥有候选生成、行为模式或敌人身份
优先级。

## 关键所有权

### 版本知识

- `bot/knowledge/allies/ally_mechanic_compiler.gd` 与
  `bot/knowledge/structures/structure_mechanic_compiler.gd` 分别拥有友方实体和构筑物的稳定作用画像。
- `bot/knowledge/pickups/material_quantity_estimator.gd` 只把可见材料缩放估算为目标版本机制保证的单位下界；
  `bot/knowledge/pickups/consumable_profile_adapter.gd` 适配可见消耗品的稳定恢复与处理画像。二者都不读取
  不可见实体或未来随机结果。
- `bot/knowledge/neutrals/neutral_mechanic_compiler.gd` 拥有可见树木的稳定生命、命中上限与掉落画像；
  `bot/knowledge/projectiles/projectile_motion_compiler.gd` 把可见投射物的稳定运动配置编译为解析运动模型。
- `bot/knowledge/weapons/weapon_mechanic_compiler.gd` 拥有目标版本武器状态与资源到 `attack_model` 的映射；
  `bot/knowledge/stats/stat_metadata.gd` 提供规范属性名和目标版本一级升级增量；
  `bot/knowledge/stats/stat_opportunity_profile_adapter.gd` 适配属性的目标版本机会曲线。
- `bot/knowledge/enemies/enemy_mechanic_compiler.gd` 拥有稳定攻击、接触形状、收益、战场影响与移除后果；
  `bot/knowledge/enemies/enemy_motion_mechanic_compiler.gd` 拥有稳定目标位置响应与冲撞配置。两类缓存都不得
  混入战斗期状态。

### 观察与记忆

- `bot/observation/observed_world_memory.gd` 聚合每位玩家的实体、敌人轨迹与视野覆盖记忆；
  `bot/observation/remembered_entity_existence_estimator.gd` 估计实体存在性。
- `bot/observation/observed_motion_estimator.gd` 负责跨帧运动测量；
  `bot/observation/enemy_attack_timing_observer.gd` 只拥有当前可见敌人的下一轮齐射与冲撞时间窗；
  `bot/observation/visible_world_observer.gd` 从原版统一敌人域观察普通敌人、精英与 Boss，并读取可见敌人的
  当前生命，以及当前敌方投射物和友方角色的碰撞形状。
- 观察层只输出语义画像。它不读取规划结果，规划层也不读取观察层的场景节点或内部实现细节。

### 运动、碰撞与生命

- `bot/planning/movement_timing_model.gd` 唯一定义规划时域及其波次剩余时间裁剪；
  `bot/planning/movement_geometry_model.gd` 统一派生共享空间尺度。
- `bot/planning/motion/observed_motion_predictor.gd` 只负责纯观测运动外推；
  `bot/planning/motion/enemy_motion_predictor.gd` 对稳定目标位置响应作自适应中点积分，并在不适用时改用
  观测运动外推；`bot/planning/motion/projectile_motion_predictor.gd` 解析积分已形成的确定性弹道；
  `bot/planning/motion/enemy_reach_envelope_model.gd` 派生敌人的最大位移和接触支撑半径。
- `bot/planning/local_enemy_interaction_projector.gd` 结合敌人可达包络、压力作用范围与武器锁定距离，构造
  动作预测的敌人空间粗筛。完整观察仍归导航与价值上下文所有。
- `bot/planning/battlefield_influence_model.gd` 拥有环境暴露、普通敌人与投射物的位置域碰撞证据、战斗支援
  伤害与消耗、友方减压、治疗和挡弹时序；
  `bot/planning/velocity_obstacle_collision_model.gd` 拥有投射物与队友 TTC，以及已知冲撞锁定走廊的速度
  空间交会证据。
- `bot/planning/health/collision_health_impact_model.gd` 合并位置域和速度空间证据，并按原版当前最短无敌帧
  间隔换算预期生命损失与直接终止风险；
  `bot/planning/health/health_replenishment_forecast_model.gd` 预测清场前可兑现的生命补充；
  `bot/planning/health/health_inventory_value_model.gd` 负责即时生存缓冲、预计生命库存、单位价值，以及把
  动作窗内的条件生命损失换算为即时缓冲成本。
- `bot/planning/player_kinematics_model.gd` 负责与原版一致的一阶移动和击退衰减。

### 机会、规则与动作结果

- `bot/planning/spatial_opportunity_value_model.gd` 计算可见与记忆机会沿候选路径的价值、动态敌人的同时间
  反事实价值差和按统一价值上界聚合的机会候选方向；它只拥有武器射程外的攻击窗口，不重复解释射程内的
  自动选靶。`bot/planning/navigation_intent_planner.gd` 组合空间机会、地图信息和导航时域环境暴露，比较
  导航终点，并公开胜出导航方向与可达机会价值上界最高的方向。
  `bot/planning/map_information_value_model.gd` 计算新观察与再观察价值，不编码探索方向、巡逻路线或地图中心。
- `bot/planning/engagement/engagement_target_projector.gd` 把敌人轨迹与树木投影为统一的可交战
  目标契约；契约公开移动、完成状态、收益、负担、死亡后果与武器响应，不指定目标优先级。
- `bot/planning/weapons/weapon_attack_capacity_model.gd` 定义与目标无关的期望主路径攻击率、单次命中伤害和
  生命偷取率；`bot/planning/engagement/weapon_outcome_forecast_model.gd` 把这些容量与动作路径上的统一可见
  目标投影为局部命中、伤害与完成容量；
  `bot/planning/engagement/weapon_outcome_conservation_model.gd` 独占跨武器、跨路径采样的有限目标容量守恒。
- `bot/planning/engagement/wave_completion_forecast_model.gd` 按统一 `target_id` 分配本波共享主路径容量；
  `bot/planning/engagement/neutral_completion_work_model.gd` 把树木最后一次观测的剩余生命、命中状态和
  玩家的一击完成状态统一解释为有效攻击工作量，供波次容量与局部武器结果共享。
- `bot/planning/engagement/enemy_completion_value_model.gd` 拥有敌人完成状态转移的价值账本；
  `bot/planning/enemy_health_model.gd` 把敌人最后可见生命测量与稳定最大生命先验统一解析为剩余生命。
- `bot/planning/engagement/weapon_cluster_outcome_model.gd` 只计算贯穿、弹射和范围机制可利用的额外目标
  容量，并按候选终点时刻的预计可交战目标几何计价。
- `bot/planning/opportunity_pricing_model.gd` 只换算材料、
  消耗品、树木和击杀掉落，不再拥有敌人威胁或死亡转移；
  `bot/planning/consumable_drop_probability_model.gd` 把稳定掉落画像与当前幸运组合为消耗品及箱子概率；
  `bot/planning/stat_opportunity_pricing_model.gd` 计算属性变化对未来事件机会的边际价值。
- `bot/planning/player_rule_outcome_predictor.gd` 负责事件触发几何；
  `bot/planning/player_movement_state_projector.gd` 投影候选移动状态造成的属性差量；
  `bot/planning/player_rule_projector.gd` 将规则归约为正交状态。这些模块都不能读取场景节点。
- `bot/planning/movement_outcome_predictor.gd` 组合动作结果；`bot/planning/movement_utility_model.gd` 将结果换算
  为效用。预测和评分是两个边界，选择器不拥有二者。
- `bot/planning/movement_action_generator.gd` 从可执行输入空间构造均匀基线，补入导航意图公开的胜出导航
  方向和可达机会价值上界最高的方向，并按规划器提出的细分方向构造新候选；
  `bot/planning/movement_action_selector.gd` 只选择总效用最高的已评分候选；`MovementPlanner` 协调生成、
  预测、评分、细分与选择，不把新行为政策藏进选择器。

### 计算预算与遥测

- `bot/control/physics_frame_budget_monitor.gd` 独占 Godot 性能监视与物理回调峰值估计，向规划
  边界公开帧预算上下文；`bot/control/planning_worker.gd` 独占工作线程、信号量、互斥交接和回收，并在该
  线程创建、配置、执行和释放规划器；`bot/control/autopilot_controller.gd` 只提交值快照与预算上下文，
  独占调度、失败时释放控制与结果提交。规划器不访问场景节点或可变观察状态。
- `bot/planning/planning_compute_budget_policy.gd` 把帧预算上下文转换成统一最终截止与连续预算压力，并维护
  额外工作的耗时估计；`bot/planning/planning_search_work_allocator.gd` 把预算压力映射为导航额外评价和
  移动细分额度，并公开固定导航基线。两者都不拥有局部动作基线、导航机会或行为效用。
- `bot/planning/projectile_reachability_filter.gd` 只拥有投射物的规划域可达性过滤；
  `bot/planning/adaptive_direction_refiner.gd` 只根据已评分方向提出下一角区间中点，候选构造、评价和停止
  策略仍归调用方。
- `bot/control/decision_telemetry.gd` 拥有采样频率、JSON Lines 编码、落盘和分片策略；`MovementPlanner`
  拥有规划结果及诊断语义。采样器删除重复机制画像并降低同步刷新频率；规划视图省略已确认不存在的永久
  历史记录，公共观察仍保留它们。两项优化都不改变规划所消费的当前机会或保留字段的语义值。

## 组件角色命名

目录表达依赖与所有权，文件后缀表达组件角色：

| 后缀 | 稳定语义 | 入口动词 |
| --- | --- | --- |
| `Observer` | 读取当前合法状态并形成观察 | `observe` |
| `Adapter` | 按来源或事件域把目标版本存储契约翻译成规范契约 | `adapt` |
| `Compiler` | 分析运行时对象及其资源，把多个具体机制编译为正交规划语义 | `compile` |
| `Profiler` | 融合稳定机制与局内证据形成画像 | `build_profile`、`accumulate_evidence` |
| `Estimator` | 从既有观察估计不可直接测量的当前量 | `estimate` 或状态化 `update` |
| `Predictor` | 沿时间或候选动作推演未来结果 | `predict` 或 `accumulate_outcome` |
| `Projector` | 将同一组已知规则或状态映射到候选表示，不模拟世界演化 | `project` |
| `Model` | 封装可复用的领域关系或评价规律 | 领域动词 |
| `Generator` | 按已给空间与画像构造候选集合，不拥有评价或选择 | `generate`、`make_*` |
| `Selector` | 从已评分候选中选择结果，不拥有预测或评分 | `select` |
| `Planner` | 协调候选生成、预测、评价与选择，产出完整决策 | `plan` |
| `Worker` | 在受同步协议保护的后台拥有任务执行生命周期，不拥有任务语义或结果应用 | `start`、`submit`、`poll`、`shutdown` |
| `Monitor` | 读取运行时监视值，维护平滑状态并公开上下文 | `observe_*`、`build_context` |
| `Filter` | 按明确判据产生输入子集，并公开过滤诊断 | `filter` |
| `Refiner` | 根据已评价候选提出更细的搜索候选，不拥有评价或停止策略 | `propose_*` |
| `Allocator` | 把既有资源信号映射为某一计算维度的本轮额度，不拥有资源测量或行为价值 | `allocate` |
| `Policy` | 根据资源上下文形成计算预算或其他可调策略 | 领域动词，或 `set_frame_budget_context`、`allocate`、`observe_*` |
| `Telemetry` | 按既定采样政策持久化诊断记录，不参与被记录的决策 | `start`、`record_decision`、`close` |

数据按产物命名，例如 `attack_model`、`rule_projection`、`behavior_profile` 和 `navigation_intent`；组件使用
上表的角色后缀。这样可以区分投影结果与执行投影的 `Projector`，以及导航意图与生成它的
`NavigationIntentPlanner`。
