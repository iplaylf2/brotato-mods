# Brotato Mods

面向 Brotato 的 Godot Mod Loader 多 mod 仓库。`content/` 保存可放入 Godot 项目或发行包的
mod 内容。恢复工程和原始游戏资源仅用作本地开发参考，不属于仓库内容。

## 仓库约定

`content/mods-unpacked/` 是 mod 源码入口。其下每个直接子目录都是一个可独立发行的
mod，目录名必须与 `manifest.json` 中的 `{namespace}-{name}` 一致，并包含
`mod_main.gd`。这些规则由仓库的可移植检查验证。

`content/.import/` 只用于本仓库 mod 自定义资源的 Godot 3 导入产物。发行单个 mod 时，
只包含该 mod 及其对应的导入产物；本地恢复工程和原版游戏资源始终排除在仓库与发行包之外。

修改原版行为前，先以目标游戏版本的恢复工程确认控制点。优先使用 Mod Loader script extension，
避免复制整个原版方法，以减少与其他 mod 及后续游戏版本的冲突。各 mod 的目标环境由其
`manifest.json` 声明，README 负责解释目标环境和验证状态。

## Mods

- [Autopilot](content/mods-unpacked/iplaylf2-autopilot/README.md) — 根据玩家可合法获得的信息规划并控制战斗移动

## 开发环境

Brotato 1.1.15.4 基于 Godot 3.7.dev 构建。编辑恢复工程、导入自定义资源和进行游戏内验证需要：

- 与目标游戏构建一致的 Godot 3.7.dev，包含项目使用的 Steam API
- 使用 [GDRETools](https://github.com/GDRETools/gdsdecomp) 恢复的 Brotato Godot 工程
- [Godot Mod Tool 的 `3.x` 分支](https://github.com/GodotModding/godot-mod-tool/tree/3.x)

运行仓库的构建、检查和格式化任务还需要
[uv](https://docs.astral.sh/uv/getting-started/installation/)。脚本编译检查不运行 Steam 功能，可使用
[Godot 3.7-dev1 官方 headless 构建](https://godotengine.org/download/archive/3.7-dev1/)。

恢复工程包含 Brotato 的版权代码与资源，只能作为本地开发材料，不能纳入仓库内容或 mod 发行包。
若需调查或使用 Abyssal Terrors 内容，恢复工程还需要包含 DLC PCK。

### 本地配置

完整 `lint` 通过 `GODOT_EXECUTABLE` 定位 Godot 3.7.dev 可执行文件，通过
`BROTATO_PROJECT` 定位恢复工程。可将 `.env.example` 复制为 `.env` 后填写，也可在运行任务前
直接设置同名环境变量。`.env` 不会覆盖已有的进程环境；其中的相对路径以仓库根目录为基准。

### 编辑 Mod

将本仓库的 mod 目录链接或复制到恢复工程中的对应位置：

```text
content/mods-unpacked/iplaylf2-autopilot/
  -> <recovered-project>/mods-unpacked/iplaylf2-autopilot/
```

然后用与目标游戏一致的 Godot 3.7.dev 打开恢复工程，并使用 Mod Tool 维护 manifest。若 mod 包含自定义
图片、字体等导入资源，保留资源旁的 `.import` 元数据，并将其引用的产物从恢复工程的 `.import/`
复制到仓库的 `content/.import/`。

### 构建发行包

从仓库根目录构建指定 mod：

```bash
uv run --locked tools/tasks.py build iplaylf2-autopilot
```

产物位于 `dist/<namespace>-<name>.zip`。ZIP 内保留 Mod Loader 所需的
`mods-unpacked/<namespace>-<name>/` 路径，可直接作为发行包。构建任务只收集指定 mod 及其
`.import` 元数据引用的导入产物；任何引用的导入产物缺失时，构建会失败并报出对应元数据。

## 检查与格式化

开发工具锁定在 `uv.lock` 中。仓库不是可安装的 Python 包；`tools/tasks.py` 提供跨平台的检查与
格式化入口。先安装依赖并运行不需要游戏文件的可移植检查：

```bash
uv sync --locked
uv run --locked tools/tasks.py lint-portable
```

`lint-portable` 检查每个 mod 的必需文件、manifest JSON 和目录 ID，并使用面向 Godot 3 的 gdtoolkit
检查 GDScript 格式与静态规则，使用 Ruff 检查任务脚本。GitHub CI 只运行这一层，因此不需要恢复工程，
也不会接触游戏文件。

本地完整检查在上述检查之后，确认 `GODOT_EXECUTABLE` 使用 Godot 3.7.dev，再以
`BROTATO_PROJECT` 指向的恢复工程实际编译所有 mod 脚本及其预加载依赖：

```bash
uv run --locked tools/tasks.py lint
```

该任务验证 GDScript 加载与编译，不代替游戏内行为测试。官方 headless 构建不包含目标游戏的
Steam API，恢复工程初始化时可能输出 Steam 单例和无窗口环境的原游戏错误；验证器会另行报告
无法编译的 mod 脚本，并以非零状态退出。

任务入口可在 PowerShell、cmd 或 POSIX shell 中使用，不依赖 `sh` 或 `make`。自动格式化受管理的源码：

```bash
uv run --locked tools/tasks.py format
```

## 参考资料

- [Godot Mod Loader: Mod Structure](https://wiki.godotmodding.com/guides/modding/mod_structure/)
- [Godot Mod Loader: Mod Files](https://wiki.godotmodding.com/guides/modding/mod_files/)
- [Godot Mod Loader: Script Extensions](https://wiki.godotmodding.com/guides/modding/script_extensions/)
- [Godot Mod Tool](https://wiki.godotmodding.com/guides/modding/tools/mod_tool/)
- [GDScript Toolkit 3.6.0](https://github.com/Scony/godot-gdscript-toolkit/tree/3.6.0)（工具版本）
