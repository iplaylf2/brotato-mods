# Brotato Mods

面向 Brotato 的 Godot Mod Loader 多 mod 仓库。`content/` 保存可放入 Godot 项目或发行包的
mod 内容；仓库不维护自定义构建系统，也不包含 Brotato 恢复后的游戏工程或原始游戏资源。

```text
content/
├── .import/                    # 仅在 mod 包含自定义资源时存在
└── mods-unpacked/
    └── IPlayLF2-Demo/
        ├── manifest.json
        └── mod_main.gd
```

每个 `content/mods-unpacked/{Namespace}-{ModName}` 目录都是一个独立 mod。新增 mod 时增加同级
目录；`namespace` 与 `name` 组成的 ID 必须和目录名一致。`content/.import/` 只能包含本仓库 mod
自定义资源对应的 Godot 3 导入产物，不能混入原版游戏资源。发行单个 mod 时，只包含该 mod 及其
对应的导入产物。

## Demo

`IPlayLF2-Demo` 是占位用的最小生命周期 mod，不代表未来正式 mod 的名称。它不修改存档、输入或
游戏行为；启用后只在 `_init` 和 `_ready` 阶段写入 ModLoader 日志，用于确认 mod 已正确加载。

## 开发方向

首个正式 mod 计划提供自动战斗功能。实现以目标游戏版本的恢复工程为依据：确认控制点后，将
script extension 按原版路径放入 `extensions/`；`mod_main.gd` 只负责注册扩展和其他启动期集成。
修改原版行为时优先使用 Mod Loader script extension，避免复制整个原版方法，以减少与其他 mod
及后续游戏版本的冲突。

当前 manifest 以 PC 版 Brotato `1.1.15.4` 和 Godot 3 Mod Loader `6.3.0` 为目标。
游戏更新后必须先验证兼容性，再修改对应版本字段。

## 开发环境

Brotato 是 Godot 3 项目；当前开发环境使用 GodotSteam 3.6。编辑、运行和打包 mod 需要：

- [GodotSteam 3.6](https://codeberg.org/godotsteam/godotsteam/releases/tag/v3.28)
- 使用 [GDRETools](https://github.com/GDRETools/gdsdecomp) 恢复的 Brotato Godot 工程
- [Godot Mod Tool 的 `3.x` 分支](https://github.com/GodotModding/godot-mod-tool/tree/3.x)

运行仓库的静态检查还需要 [uv](https://docs.astral.sh/uv/getting-started/installation/)。

不要提交恢复后的游戏工程。它包含 Brotato 的版权代码与资源，应放在本仓库之外。若 mod 使用
Abyssal Terrors 内容，恢复工程时还需要包含 DLC PCK。

将本仓库的 mod 目录链接或复制到恢复工程中的相同位置：

```text
content/mods-unpacked/IPlayLF2-Demo/
  -> <recovered-project>/mods-unpacked/IPlayLF2-Demo/
```

然后用 GodotSteam 3.6 打开恢复工程。使用 Mod Tool 创建和编辑 manifest，并导出 ZIP；这样
自定义图片、字体等资源对应的 Godot 3 `.import` 产物也会被正确收集。

## 静态检查

开发工具锁定在 `uv.lock` 中。仓库不是可安装的 Python 包；`tools/tasks.py` 只提供跨平台的静态
检查与格式化入口。

```bash
uv sync --locked
uv run --locked tools/tasks.py lint
```

以上命令可直接在 PowerShell、cmd 或 POSIX shell 中运行，不依赖 `sh` 或 `make`。

`lint` 任务检查每个 mod 是否包含 `manifest.json` 和 `mod_main.gd`、manifest 是否为合法 JSON，
以及 manifest ID 是否与目录名一致；随后使用面向 Godot 3 的 gdtoolkit 检查 GDScript，并使用
Ruff 检查任务脚本本身。自动格式化受管理的源码：

```bash
uv run --locked tools/tasks.py format
```

## 参考资料

- [Godot Mod Loader: Mod Structure](https://wiki.godotmodding.com/guides/modding/mod_structure/)
- [Godot Mod Loader: Mod Files](https://wiki.godotmodding.com/guides/modding/mod_files/)
- [Godot Mod Loader: Script Extensions](https://wiki.godotmodding.com/guides/modding/script_extensions/)
- [Godot Mod Tool](https://wiki.godotmodding.com/guides/modding/tools/mod_tool/)
- [GDScript Toolkit 3.6.0](https://github.com/Scony/godot-gdscript-toolkit/tree/3.6.0)
