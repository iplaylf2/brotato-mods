# Brotato Mods

面向 Brotato 的 Godot Mod Loader 多 mod 仓库。`content/` 保存可放入 Godot 项目或发行包的
mod 内容。恢复工程和原始游戏资源仅用作本地开发参考，不属于仓库内容。

## 仓库约定

`content/mods-unpacked/` 是 mod 源码入口。其下每个直接子目录都是一个可独立发行的
mod，目录名必须与 `manifest.json` 中的 `{namespace}-{name}` 一致，并包含
`mod_main.gd`。这些规则由仓库的可移植检查验证。

`content/.import/` 只用于本仓库 mod 自定义资源的 Godot 3 导入产物。发行单个 mod 时，
只包含该 mod 及其对应的导入产物；本地恢复工程和原版游戏资源始终排除在仓库与发行包之外。

## Mods

- [Autopilot](content/mods-unpacked/iplaylf2-autopilot/README.md) — 根据玩家可合法获得的信息规划并控制战斗
  移动；其 README 统一提供安装、目标环境与维护文档入口。

修改原版行为前，先以目标游戏版本的恢复工程确认控制点。优先使用 Mod Loader script extension，
避免复制整个原版方法，以减少与其他 mod 及后续游戏版本的冲突。各 mod 的目标环境由其
`manifest.json` 声明，README 负责解释目标环境和验证状态。

## 开发环境

Brotato 是 Godot 3 项目；当前开发环境使用 GodotSteam 3.6。编辑、运行和打包 mod 需要：

- [GodotSteam 3.6](https://codeberg.org/godotsteam/godotsteam/releases/tag/v3.28)
- 使用 [GDRETools](https://github.com/GDRETools/gdsdecomp) 恢复的 Brotato Godot 工程
- [Godot Mod Tool 的 `3.x` 分支](https://github.com/GodotModding/godot-mod-tool/tree/3.x)

运行仓库检查还需要 [uv](https://docs.astral.sh/uv/getting-started/installation/)。GodotSteam/Godot 3.6
可执行文件由开发环境提供，并且必须位于 `PATH` 中。

恢复工程包含 Brotato 的版权代码与资源，只能作为本地开发材料，不能纳入仓库内容或 mod 发行包。
若需调查或使用 Abyssal Terrors 内容，恢复工程还需要包含 DLC PCK。

### 本地配置

完整检查需要目标版本的恢复工程。仓库不约定其存放位置；将 `.env.example` 复制为 Git 已忽略的
`.env`，并把 `BROTATO_PROJECT` 设置为恢复工程的绝对路径。任务会自动读取该文件，但不会覆盖进程
环境中已有的同名变量。

### 编辑与打包

将本仓库的 mod 目录链接或复制到恢复工程中的对应位置：

```text
content/mods-unpacked/iplaylf2-autopilot/
  -> <recovered-project>/mods-unpacked/iplaylf2-autopilot/
```

然后用 GodotSteam 3.6 打开恢复工程。使用 Mod Tool 维护 manifest 并导出 ZIP；这样
自定义图片、字体等资源对应的 Godot 3 `.import` 产物也会被正确收集。

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

本地完整检查在上述检查之后，使用 Godot 3.6 和 `BROTATO_PROJECT` 指向的恢复工程实际编译所有 mod
脚本及其预加载依赖：

```bash
uv run --locked tools/tasks.py lint
```

如果不使用 `.env`，也可以在 PowerShell、cmd 或 POSIX shell 的进程环境中设置 `BROTATO_PROJECT`。
这些任务不依赖 `sh` 或 `make`。自动格式化受管理的源码：

```bash
uv run --locked tools/tasks.py format
```

## 参考资料

- [Godot Mod Loader: Mod Structure](https://wiki.godotmodding.com/guides/modding/mod_structure/)
- [Godot Mod Loader: Mod Files](https://wiki.godotmodding.com/guides/modding/mod_files/)
- [Godot Mod Loader: Script Extensions](https://wiki.godotmodding.com/guides/modding/script_extensions/)
- [Godot Mod Tool](https://wiki.godotmodding.com/guides/modding/tools/mod_tool/)
- [GDScript Toolkit 3.6.0](https://github.com/Scony/godot-gdscript-toolkit/tree/3.6.0)
