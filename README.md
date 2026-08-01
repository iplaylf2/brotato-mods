# Brotato Mods

面向 Brotato 的 Godot Mod Loader 多 mod 仓库。`content/` 保存可放入 Godot 项目或发行包的
mod 内容。恢复工程和原始游戏资源仅用作本地开发参考，不属于仓库内容。

## 仓库结构

```text
content/
├── .import/                    # 仅在 mod 包含自定义资源时存在
└── mods-unpacked/
    └── IPlayLF2-Autopilot/
        ├── README.md
        ├── bot/
        ├── extensions/
        ├── manifest.json
        └── mod_main.gd
```

每个 `content/mods-unpacked/{Namespace}-{ModName}` 目录都是一个独立 mod。新增 mod 时增加同级
目录；`namespace` 与 `name` 组成的 ID 必须和目录名一致。`content/.import/` 只能包含本仓库 mod
自定义资源对应的 Godot 3 导入产物，不能混入原版游戏资源。发行单个 mod 时，只包含该 mod 及其
对应的导入产物。

## Autopilot

`IPlayLF2-Autopilot` 的目标是让 bot 依据玩家可见的外部战场信息、精确的自身状态、局内战斗记忆
和预置机制知识，自主完成战斗移动。当前开发先完成信息采集与建模，确认观察契约后再进入移动控制。

实现通过 `extensions/` 中的 script extension 接入原版主场景；`mod_main.gd` 只负责注册扩展。
架构、观察接口、建模原则和当前覆盖范围见
[Autopilot 开发说明](content/mods-unpacked/IPlayLF2-Autopilot/README.md)。

修改原版行为前，先以目标游戏版本的恢复工程确认控制点。优先使用 Mod Loader script extension，
避免复制整个原版方法，以减少与其他 mod 及后续游戏版本的冲突。

当前 manifest 以 PC 版 Brotato `1.1.15.4` 和 Godot 3 Mod Loader `6.3.0` 为目标。
游戏更新后必须先验证兼容性，再修改对应版本字段。

## 开发环境

Brotato 是 Godot 3 项目；当前开发环境使用 GodotSteam 3.6。编辑、运行和打包 mod 需要：

- [GodotSteam 3.6](https://codeberg.org/godotsteam/godotsteam/releases/tag/v3.28)
- 使用 [GDRETools](https://github.com/GDRETools/gdsdecomp) 恢复的 Brotato Godot 工程
- [Godot Mod Tool 的 `3.x` 分支](https://github.com/GodotModding/godot-mod-tool/tree/3.x)

运行仓库的静态检查还需要 [uv](https://docs.astral.sh/uv/getting-started/installation/)。

恢复工程包含 Brotato 的版权代码与资源，只能作为本地开发材料，不能纳入仓库内容或 mod 发行包。
若需调查或使用 Abyssal Terrors 内容，恢复工程还需要包含 DLC PCK。

将本仓库的 mod 目录链接或复制到恢复工程中的对应位置：

```text
content/mods-unpacked/IPlayLF2-Autopilot/
  -> <recovered-project>/mods-unpacked/IPlayLF2-Autopilot/
```

然后用 GodotSteam 3.6 打开恢复工程。使用 Mod Tool 维护 manifest 并导出 ZIP；这样
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
