# Autopilot 模块边界与责任

本文面向修改目录归属、依赖方向或公共入口的维护者。运行链路、观察字段和规划语义由
[架构文档](architecture.md) 定义；信息与控制权限由 [玩家权限边界](fair-play.md) 定义。本文只维护代码
所有权和跨模块契约，不重复算法说明。

## 运行时边界与依赖

| 模块 | 责任 | 公共边界 |
| --- | --- | --- |
| `mod_main.gd` | 安装主场景与 RunData 扩展，接入 Mod Loader 配置并发布控制/采样启用状态 | `is_enabled()`、`is_sampling_enabled()` 与对应信号；不持有对局或战斗期状态 |
| `extensions/run_data.gd` | 生成整局采样 ID，并随原版对局状态保存和恢复 | 扩展 `RunData.reset()`、`get_state()` 与 `resume_from_state()`；`get_battle_sample_run_id()` 是主场景组合根的只读入口 |
| `extensions/main.gd` | 作为组合根响应玩家生成、设置切换和房间清理，按需创建或停止观察、控制与记录边界 | 主场景公开 `autopilot_observation_service`、`autopilot_controller` 和 `get_current_battle_sample_path()`；不公开采样组件，也不实现观察、规划、存储或整局身份语义 |
| `bot/control` | 调度多速率后台规划并适配原版移动控制 | `AutopilotController` 只在控制开启时存在；`AutopilotMovementBehavior` 是唯一控制输出，两个独立的 `PlanningWorker` 实例是包内协作者 |
| `bot/sampling` | 协调 human/bot 战斗采样并异步写入分段文件 | `BattleSampleRecorder` 只在采样开启时存在；`BattleSampleWriter` 是包内协作者 |
| `bot/planning` | 管理导航意图、运动学、碰撞证据、动作搜索、机会与资源定价，以及候选执行资格与效用选择 | `TacticalMovementPlanner.plan()` 是战术入口，`StrategicNavigationPlanner.plan()` 是战略入口；`PlanningTimingModel` 公开两级调度契约，其余组件是规划包内部协作者 |
| `bot/observation` | 读取当前玩家与可见世界，维护局内观察记忆，组装公共观察 | `ObservationService.initialize()` 接入主场景与玩家；`get_observation()` 提供防御性副本；`get_planning_observation()` 截取不含场景节点并与观察状态隔离的规划值快照 |
| `bot/knowledge` | 适配版本数据并编译稳定机制，向观察层提供不含场景节点的语义结果 | 不跨层公开运行时服务，只由观察层调用 |

`mod_main.gd` 只安装两个同级扩展；`extensions/run_data.gd` 独立拥有整局身份，`extensions/main.gd` 只通过
其公开只读入口取得 ID。战斗期依赖从主场景组合根向 `control`、`sampling` 与 `observation` 单向展开；
`control → observation`、`control → planning`、`sampling → observation`，`observation → knowledge`。
`planning` 只接收已经移除场景节点的观察字典，不反向依赖 `control`、`sampling`、`observation` 或
`knowledge`。控制层对 `PlanningTimingModel` 的依赖只共享多速率调度间隔；时域派生及其解释权仍属于规划包。

所有新增能力必须先满足玩家权限边界。玩家效果的原版字段映射由 `bot/knowledge/player_effects` 拥有，
消耗品稳定画像由 `bot/knowledge/pickups` 拥有；公共规则轴及其解释权属于规划模型，不能随原版字段数量
同步扩张。新增敌人稳定特征或画像规则应放入 `bot/knowledge/enemies`。新增评分维度必须同时定义预测
语义和效用权重；新增诊断维度则应明确不参与评分。

## 规划包的子目录边界

`bot/planning` 根目录是主要协作包。大多数组件共同服务 `TacticalMovementPlanner` 与
`StrategicNavigationPlanner` 两个跨域规划入口，并存在密集的包内
依赖。由多个组件共同定义、且可被不同规划流程单独消费的稳定协议进入子目录：

- `motion` 拥有“规范运动观察与稳定响应 → 未来位置、可达包络与角向机动约束”的协议，供暴露、交会、
  事件与动作采样共同消费；
- `collision` 拥有“已解析路径交会 → 按来源接触机会”和“尚无受支持轨迹的未来实现 → 未解析交会证据”
  两段协议；它不预测实体运动，也不解释生命损失、终止风险或动作价值；
- `weapons` 拥有“攻击模型 → 与目标无关的期望攻击容量”和“武器组合与目标完成机制 → 目标相关的加权
  锁定区间”两段协议；前者供战斗、波内完成与生命补充模型消费，后者供空间机会模型消费；
- `health` 拥有“接触机会与无时序聚合交会证据 → 条件生命损失与终止风险”、“当前生命、即时威胁与清场前补充 →
  生命库存及单位价值”、“任意来源生命损失与生命库存 → 材料等价成本”三段协议，结果供导航风险、拾取
  机会与动作效用共同消费；
- `pickups` 拥有“规划记忆中的拾取物及其观察层存在证据、运动与玩家未来路径 → 收集圈间隙或连续收集
  事件”的协议，供导航机会、直接材料收益与拾取事件规则共同消费；它消费置信度，不形成存在证据；
- `engagement` 拥有统一可交战目标投影、敌人完成价值账本、本波共享主路径容量分配、锁定后的共享武器
  路径接触、动作条件武器结果预测与容量守恒，以及规则事件完成价值。它向根目录的跨域协调者提供目标
  契约、完成份额和局部战斗结果，不拥有导航轨迹或截止访问价值。

根目录保留跨域协调者，以及尚未形成独立组件族的小型共享模型；例如对局延续价值横跨材料、道具、武器
和死亡后果，不属于任一单独领域。不能只为单个文件建立目录。
`engagement` 子目录不拥有候选生成、行为模式或敌人身份优先级。

## 关键所有权

### 版本知识

- `bot/knowledge/allies/ally_mechanic_compiler.gd` 与
  `bot/knowledge/structures/structure_mechanic_compiler.gd` 分别拥有友方实体和构筑物的稳定作用画像。
- `bot/knowledge/pickups/consumable_profile_adapter.gd` 适配可见消耗品的稳定生命效果与语义特征画像。
- `bot/knowledge/neutrals/neutral_mechanic_compiler.gd` 拥有可见树木的稳定生命、命中上限与死亡奖励画像；
  `bot/knowledge/projectiles/projectile_motion_compiler.gd` 把可见投射物的稳定运动配置编译为解析运动模型。
- `bot/knowledge/collision_shape_radius_adapter.gd` 把原版圆形和矩形 `CollisionShape2D` 及其完整世界变换
  适配为规范碰撞半径。它提供以实体或碰撞节点为中心的两种包围圆；观察器选择中心并形成当帧测量，
  机制编译器不得重复解释形状。
- `bot/knowledge/weapons/weapon_mechanic_compiler.gd` 拥有目标版本武器状态与资源到 `attack_model` 的映射；
  `bot/knowledge/stats/stat_metadata.gd` 提供规范属性名和目标版本一级升级增量；
  `bot/knowledge/stats/stat_opportunity_profile_adapter.gd` 适配属性的目标版本机会曲线。
- `bot/knowledge/pickups/item_box_item_value_profile_adapter.gd` 从原版波次稀有度规则、已解锁道具池和当前
  玩家价格修正生成不消耗随机数的箱子道具价值画像。
- `bot/knowledge/rewards/death_reward_profile_adapter.gd` 从可见单位适配材料数量、可见机制倍率、消耗品
  条件和必掉产物。材料数量使用目标版本的规范 `get_stats_value()` 结算入口；适配器不保留场景节点，也不
  解释目标优先级。
- `bot/knowledge/enemies/enemy_mechanic_compiler.gd` 聚合稳定攻击、接触形状、战场影响与移除后果，并委托
  `bot/knowledge/rewards` 形成当次掉落画像，再附加由敌人内容机制确定的死亡属性变化；
  `bot/knowledge/enemies/enemy_motion_mechanic_compiler.gd` 拥有稳定目标位置响应与冲撞配置。两类缓存都不得
  混入战斗期状态。

### 观察与记忆

- `bot/observation/observed_world_memory.gd` 聚合每位玩家的实体、敌人轨迹与视野覆盖记忆；
  `bot/observation/visibility_coverage_model.gd` 统一解释无雾矩形视口的保守负可见性证据，
  `bot/observation/enemy_death_product_matcher.gd` 只在机制支持域内已追踪来源候选唯一时，将首次观察的
  必掉产物与失视敌人关联，
  `bot/observation/remembered_entity_existence_estimator.gd` 独占记忆实体的存在证据解释：对拾取物，本地
  收集圈提供确定缺席，玩家自身的吸附范围不改变存在性，只有已合法定位的存活队友可形成视野外拾取
  概率；对静止树木，完整视口覆盖提供确定缺席。
- `bot/observation/observed_motion_estimator.gd` 保留原版为可见实体提供的当帧权威速度，并在缺少权威速度
  时负责跨帧速度测量，同时从合法历史形成加速度趋势；
  `bot/observation/enemy_attack_timing_observer.gd` 只拥有当前可见敌人的下一轮齐射与冲撞时间窗；
  `bot/observation/visible_world_observer.gd` 单次扫描原版统一敌人域，观察普通敌人、精英与 Boss 的视觉状态，
  并单独输出原版持续血条提供的视野外存活和当前生命；对敌方投射物，它以实际命中形状中心形成位置测量，
  再通过碰撞形状适配器取得规范半径；对可见材料，它读取原版结算直接消费的确定数量；对生成警告，
  它直接适配当帧精确倒计时。这些当前事实不由机制编译器或观察记忆重复维护。
- 观察层只输出语义画像。它不读取规划结果，规划层也不读取观察层的场景节点或内部实现细节。
- 规划视图省略已确认不存在的永久历史记录，公共观察仍保留它们；该视图优化不改变规划所消费的当前
  机会或保留字段的语义值。

### 运动、碰撞与生命

- `bot/planning/planning_timing_model.gd` 唯一定义多速率调度、规划时域及其波次剩余时间裁剪；
  `bot/planning/movement_geometry_model.gd` 统一派生共享空间尺度。
- `bot/planning/motion/observed_motion_predictor.gd` 只负责纯观测运动外推；
  `bot/planning/motion/enemy_motion_predictor.gd` 对稳定目标位置响应作自适应中点积分，并在不适用时改用
  观测运动外推；`bot/planning/motion/projectile_motion_predictor.gd` 解析积分已形成的确定性弹道，并统一
  提供该弹道的保守位移与角速度上界，供规划域过滤与动作时间采样共同消费；
  `bot/planning/motion/enemy_reach_envelope_model.gd` 派生敌人的最大位移和接触支撑半径；
  `bot/planning/motion/maneuver_space_model.gd` 计算可达敌人圆盘与已知地图边界遮蔽角区间的并集，不选择路线。
- `bot/planning/local_enemy_interaction_projector.gd` 结合敌人可达包络、压力作用范围与武器锁定距离，构造
  动作预测的敌人空间粗筛。完整观察仍归导航与价值上下文所有。
- `bot/planning/battlefield_influence_model.gd` 拥有环境暴露、普通敌人与投射物的位置域碰撞证据、确定性
  目标定向齐射在弹体生成前的未来射击走廊、敌人与地图边界共同形成的角向机动约束、战斗支援伤害与
  消耗、友方减压、治疗和挡弹时序；
  `bot/planning/collision/unresolved_collision_risk_model.gd` 只拥有尚无受支持解析轨迹的碰撞证据：独立
  控制玩家在当前速度延续假设下的 TTC，以及尚未揭示目标的冲撞分布；已有解析轨迹的实体不得再进入
  该边界；
  `bot/planning/collision/contact_opportunity_projector.gd` 将几何模型已判定的交会及其来源映射为预测
  接触机会契约，不解释生命、风险偏好或动作价值。
- `bot/planning/health/health_loss_value_model.gd` 是不依赖来源预测的叶模块，消费生命库存价值上下文，将任意
  来源的生命损失统一换算为液态生命库存成本；碰撞结果、伤害型拾取和导航机会可以共同依赖它，而不反向
  依赖波次完成或机会模型。
- `bot/planning/health/contact_damage_state_model.gd` 按时间顺序从接触机会推进当前生命、当前无敌剩余时间、
  受伤后变长无敌时间、闪避和命中保护的状态分布；
  `bot/planning/health/collision_health_impact_model.gd` 仅组合该逐次状态结果与尚无逐次时刻的未解析交会证据；
  `bot/planning/health/health_replenishment_forecast_model.gd` 预测清场前可兑现的生命补充；
  `bot/planning/health/health_inventory_value_model.gd` 负责风险尺度、即时生存缓冲、预计生命库存和单位价值。
  即时命中储备覆盖下一控制期内敌人与完整玩家动作集合的联合可达域，不只覆盖静止玩家。
- `bot/planning/movement_action_selector.gd` 只排除存在替代动作时已落入下一提交期的确定终止，随后
  最大化公共效用。完整预测窗的即时缓冲消耗和终止风险分别形成生命库存与对局延续价值成本；提交期
  风险只拥有执行资格。选择器不拥有风险偏好、逃跑方向或敌人类别策略。
- `bot/planning/player_kinematics_model.gd` 负责与原版一致的一阶移动和击退衰减。

### 机会、规则与动作结果

- `bot/planning/spatial_opportunity_value_model.gd` 是跨拾取物、规则事件、生成警告与可交战目标的空间机会
  协调者。它统一计算未来玩家状态相对同刻零输入反事实的截止访问差，拥有访问势能、不可达机会剪枝和
  按价值上界形成的预算内搜索方向；目标投影与完成份额仍由 `engagement` 提供。它不猜测警告结果，
  也不解释自动选靶次序或局部攻击结果。
- `bot/planning/map_information_value_model.gd` 只计算候选路径相对当前位置新增或恢复的规范化视口覆盖；
  它不拥有每视口单价，也不编码探索方向、巡逻路线或地图中心。
- `bot/planning/navigation_intent_planner.gd` 将空间机会、地图覆盖变化和导航时域环境暴露组合为轨迹价值，
  并只公开经过完整轨迹评价后胜出的导航方向。地图覆盖变化使用
  `bot/planning/movement_utility_model.gd` 在本次规划上下文中形成的每视口信息单价；该单价比较基础下限、
  当前可见机会均值与潜在恢复机会的补给库存价值，并由本波剩余比例裁剪。导航器不重复解释生命稀缺性。
- `bot/planning/engagement/engagement_target_projector.gd` 把敌人轨迹与树木投影为统一的可交战
  目标契约；契约公开移动、完成状态、收益、负担、死亡后果与武器响应，不指定目标优先级。
- `bot/planning/weapons/weapon_attack_capacity_model.gd` 定义与目标无关的期望主路径攻击率、单次命中伤害和
  生命偷取率，供 `engagement`、`health` 与同目录模型复用。
- `bot/planning/weapons/weapon_targeting_interval_model.gd` 在不解释目标价值或路线的前提下，保留每把武器的
  最小与最大锁定距离，并针对生命目标按主路径伤害率、针对命中上限目标按主路径命中率归一化区间份额；
  根目录的 `spatial_opportunity_value_model.gd` 消费这些区间。
- `bot/planning/engagement/weapon_outcome_forecast_model.gd` 独立把攻击容量与动作路径上的统一可见目标投影为
  局部命中、伤害与完成容量。
- `bot/planning/engagement/weapon_path_contact_model.gd` 统一解释锁定后主路径与额外直接路径的几何接触份额，
  不拥有锁定准入、攻击容量或目标价值。
- `bot/planning/engagement/weapon_outcome_conservation_model.gd` 独占跨武器、跨路径采样点的敌人攻击工作
  累计与有限目标容量结算，并单独约束树木总收获价值；敌人的剩余生命、离散完成代理和价值始终属于同一
  `target_id`。
- `bot/planning/engagement/wave_completion_forecast_model.gd` 按统一 `target_id` 分配本波共享主路径容量；
  `bot/planning/engagement/damage_completion_work_model.gd` 统一把剩余生命和单次伤害换算为离散击打工作量，
  并把首个已知攻击机会之后按长期速率累计的连续容量换算为截止前完成代理；
  `bot/planning/engagement/neutral_completion_work_model.gd` 把树木最后一次观测的剩余生命、命中状态和
  玩家的一击完成状态统一解释为有效攻击工作量，供波次容量与局部武器结果共享。
- `bot/planning/engagement/enemy_completion_value_model.gd` 拥有敌人完成状态转移的价值账本；
  `bot/planning/enemy_health_model.gd` 把敌人最后可见生命测量与稳定最大生命先验统一解析为剩余生命。
- `bot/planning/engagement/rule_event_value_model.gd` 统一把拾取等规则事件的空间伤害与状态转换换算为
  有限敌人完成价值，供局部动作结果与导航拾取机会共享；它不发现事件、识别角色、估计跨时刻保留价值
  或选择路线。
- `bot/planning/pickups/pickup_collection_geometry_model.gd` 统一拥有收集圈边界、未来点位间隙，以及移动
  拾取物与玩家分段路径的连续交会；导航查询点位间隙，直接收益和事件规则查询连续收集事件。
- `bot/planning/pickups/pickup_collection_projector.gd` 以规划记忆作为拾取物唯一输入，消费观察层给出的
  存在置信度，一次形成候选路径收集事件；动作基础收益与规则后果共享该事件集合，不分别扫描可见世界。
- `bot/planning/opportunity_pricing_model.gd` 把地面材料、地面消耗品、实体死亡奖励与树木保留后果换算为
  材料等价边际价值，并分别把消耗品生命损失与确定属性变化委托给生命损失和属性机会定价；它不拥有敌人
  威胁或死亡转移机制。
- `bot/planning/death_reward_probability_model.gd` 把死亡奖励画像与当前波次、潮汐波和幸运组合为材料、
  消耗品及箱子的当前概率。
- `bot/planning/stat_opportunity_pricing_model.gd` 按属性机会曲线和剩余机会时域，计算属性变化对未来事件
  机会的边际价值。
- `bot/planning/run_continuation_value_model.gd` 用当前持有材料和已有道具、武器的公共价格代理估计死亡会
  清除的对局延续价值。该跨域模型不解释碰撞几何、生命损失或动作风险。
- `bot/planning/player_rule_outcome_predictor.gd` 负责把拾取收集和受击等事件证据解释为规则后果；
  `bot/planning/player_movement_state_projector.gd` 投影候选移动状态造成的属性差量；
  `bot/planning/player_rule_projector.gd` 将规则归约为正交状态。这些模块都不能读取场景节点。
- `bot/planning/movement_outcome_predictor.gd` 组合动作结果；`bot/planning/movement_utility_model.gd` 将结果换算
  为效用，并在规划上下文中形成每视口信息单价。其中，局部与导航环境暴露使用剩余导航时域内一单位
  生命损失的价值，补给储备、潜在恢复信息和波次尺度敌人负担使用补给库存价值；动作生命损失使用按
  剩余时域裁剪的即时缓冲价值，完整预测窗的 `forecast_terminal_health_risk` 按同窗对局延续价值计价；
  `committed_terminal_health_risk` 只拥有执行资格。预测和评分是两个边界，
  选择器不拥有二者。
- `bot/planning/movement_action_generator.gd` 从可执行输入空间构造均匀基线，补入导航意图公开的胜出导航
  方向，并按规划器提出的细分方向构造新候选；它还从时间模型取得只随波末裁剪的近端动作比较时域，并按
  玩家位移和解析曲线弹相位派生统一时间采样；敌人与投射物数量不扩张该时域；
  `bot/planning/movement_action_selector.gd` 从已评分候选中排除可避免的提交期确定终止碰撞，再选择总效用
  最高者；
  `bot/planning/actuation_state_projector.gd` 统一把值快照推进到后台结果预计抵达执行器的时刻，消费当前仍
  生效的移动输入与运动预测，不解释风险偏好；`TacticalMovementPlanner` 协调生效时刻投影、生成、预测、
  评分、细分与选择，不把新行为政策藏进选择器。

### 控制与计算预算

- `bot/control/physics_frame_budget_monitor.gd` 独占 Godot 性能监视与物理回调峰值估计，向规划
  边界公开帧预算上下文；`bot/control/planning_worker.gd` 独占单个工作线程、信号量、互斥交接和回收，
  控制器分别为战术与战略实例化它。`bot/control/autopilot_controller.gd` 只提交值快照、当前仍生效的
  移动输入、请求创建时刻、容量份额与预算上下文，独占两级调度、战略指导的来源帧/期限检查、失败时释放
  控制与战术结果提交。两个线程不共享规划器实例；规划器不访问场景节点或可变观察状态。
- `bot/planning/planning_compute_budget_policy.gd` 以半个控制窗为预算上限，把帧预算上下文转换成统一最终
  截止，再乘所属规划环的容量份额，并在线程内独立维护延迟估计、连续预算压力和额外工作耗时；
  `bot/planning/planning_search_work_allocator.gd` 通过独立入口把预算压力映射为战略导航评价或战术移动
  细分额度，并在四至八个均匀方向间分配战略导航基线。两者都不拥有局部动作基线、导航机会或行为效用；
  由碰撞几何派生的局部动作格点不随预算缩减。`StrategicNavigationPlanner` 独占长时域价值场，
  `TacticalMovementPlanner` 独占可执行动作、碰撞、生命与选择；两者分别把自身估计与实际排队时间合成
  总延迟，再调用各自的 `ActuationStateProjector`。
- `bot/planning/projectile_reachability_filter.gd` 只拥有投射物的规划域可达性过滤；弹道积分与位移上界仍由
  `bot/planning/motion/projectile_motion_predictor.gd` 提供；
  `bot/planning/adaptive_direction_refiner.gd` 只根据已评分方向提出下一角区间中点，候选构造、评价和停止
  策略仍归调用方。

### 战斗采样

- `bot/sampling/battle_sample_recorder.gd` 拥有 human 定时准入、bot 决策准入、控制来源切换和波次分段
  生命周期；
  它只读取公共观察，或接收控制器已经取得的观察与规划结果，不另建场景读取入口。
- `bot/sampling/battle_sample_writer.gd` 拥有波次与玩家固定上下文提取、独占写入线程、JSON Lines 编码、
  画像压缩、刷新和落盘策略。存储失败时，该边界停止接受记录并保留可回收的线程生命周期，不把记录
  失败提升为移动控制失败。它省略敌人轨迹中重复的稳定机制画像与行为证据，但保留每条样本当时的玩家
  效果规则，以及解释路径风险所需的攻击因果字段和当前攻击时间窗；冲撞画像明确保留触发距离、速度、
  持续时间、目标分布和 `next_charge_attack_window`。采样压缩只改变持久化投影，不改变
  规划输入或字段语义。`TacticalMovementPlanner` 仍独占可执行计划与战术诊断语义。

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
| `Planner` | 协调候选生成、预测、评价与选择，产出完整决策或指导 | `plan` |
| `Worker` | 在受同步协议保护的后台拥有任务执行生命周期，不拥有任务语义或结果应用 | `start`、`submit`、`poll`、`shutdown` |
| `Monitor` | 读取运行时监视值，维护平滑状态并公开上下文 | `observe_*`、`build_context` |
| `Filter` | 按明确判据产生输入子集，并公开过滤诊断 | `filter` |
| `Matcher` | 按明确支持关系关联两个已观察集合，不补造来源归属 | `match_*` |
| `Refiner` | 根据已评价候选提出更细的搜索候选，不拥有评价或停止策略 | `propose_*` |
| `Allocator` | 把既有资源信号映射为某一计算维度的本轮额度，不拥有资源测量或行为价值 | `allocate` |
| `Policy` | 根据资源上下文形成计算预算或其他可调策略 | 领域动词，或 `set_frame_budget_context`、`allocate`、`observe_*` |
| `Recorder` | 协调样本准入、来源和分段生命周期，不解释或改变被记录的决策 | `initialize`、`record_*`、`switch_*`、`shutdown` |
| `Writer` | 异步转换并持久化已经准入的记录，不参与采样准入或被记录的决策 | `start`、`record_*`、`close` |

数据按产物命名，例如 `attack_model`、`rule_projection`、`behavior_profile` 和 `navigation_intent`；组件使用
上表的角色后缀。这样可以区分投影结果与执行投影的 `Projector`，以及导航意图与生成它的
`NavigationIntentPlanner`。

多速率规划使用三层固定术语：`navigation_intent` 是战略搜索直接产生的方向价值结果；
`strategic_navigation_guidance` 是跨线程传递的完整值信封，包含该意图、来源帧和战略计算账本；
`strategic_navigation_guidance_diagnostics` 是战术计划持久化的信封摘要，不重复保存意图。通用
`PlanningWorker` 的结果信封使用中性的 `output`，不能把战略指导误称为 `plan`。
