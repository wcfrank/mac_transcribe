# Transcribe

一个面向 Apple Silicon Mac 的轻量菜单栏语音输入工具，支持 Apple 系统语音识别和本地 Whisper MLX。

运行后，按住键盘右侧的 **Option（⌥）** 键说话，松开后，识别结果会自动输入到当前光标所在的位置。默认使用 Apple 设备端语音识别，也可以从菜单切换到 Whisper MLX。

## 环境要求

- Apple Silicon Mac（M1 或更新）
- macOS 13 或更新版本
- Xcode Command Line Tools / Xcode 16 或更新版本
- 使用 Whisper MLX 时需要 [uv](https://docs.astral.sh/uv/)；可运行 `brew install uv`

## 构建和运行

```bash
make run
```

应用会被构建到 `dist/Transcribe.app` 并启动。也可以双击该应用运行。

首次启动时请允许：

1. 麦克风权限
2. 语音识别权限（仅 Apple 引擎需要）
3. 辅助功能权限（用于监听按键并把文字输入到当前光标位置）

使用 Apple 引擎时，请在“系统设置 → 键盘 → 听写”中打开 macOS 听写。Apple 的设备端语音识别模型由该系统功能提供；听写关闭时，该引擎不会启动。Whisper MLX 不依赖系统听写。

授予辅助功能权限后，如果菜单栏仍提示缺少权限，请退出并重新打开应用，或点击菜单中的“检查与申请权限…”。

## 使用

1. 把光标放在任意可输入文字的位置。
2. 按住键盘右侧的 Option 键。
3. 对着麦克风说话。
4. 松开 Option 键，等待菜单栏图标恢复为麦克风，文字会出现在光标位置。

点击菜单栏麦克风图标可以切换识别引擎、语言和模型：

- **Apple 语音识别**：默认要求在设备端运行。关闭“Apple：仅使用本地识别”后，系统可能使用 Apple 的在线语音识别服务。
- **Whisper MLX**：选择后先设置存储位置，再安装约 1 GB 的运行环境。运行环境和模型都会保存在所选目录中。

Whisper 模型必须先从菜单明确下载，下载完成前应用不会开始录音或转写。模型菜单会显示每个模型的下载状态：

| 模型 | 下载大小 | 适用情况 |
| --- | ---: | --- |
| Tiny | 74.4 MB | 速度最快、资源占用最低 |
| Base | 144 MB | 快速、轻量 |
| Small | 481 MB | 速度与准确率均衡，默认推荐 |
| Medium | 1.52 GB | 更高准确率 |
| Large V2 | 3.08 GB | 旧版高精度模型 |
| Large V3 Turbo | 1.61 GB | 兼顾速度与高准确率 |
| Large V3 | 3.08 GB | 最高准确率、资源占用最大 |

所选存储目录包含：

- `whisper-runtime`：MLX Python 运行环境
- `uv-python` 和 `uv-cache`：由 uv 管理的 Python 与安装缓存
- `models`：已下载的 Whisper 模型

可以随时从菜单选择“设置 Whisper 存储位置…”。更改位置不会移动旧目录中的文件；应用只使用新位置中已经安装的运行环境和已经完整下载的模型。

## 开发命令

```bash
swift build       # Debug 编译
make app          # 生成 release .app
make run          # 生成并启动 .app
```

## 已知限制

- 密码框等安全输入区域不接受模拟输入。
- 某些远程桌面、虚拟机或游戏可能拦截全局快捷键。
- Whisper 运行环境和模型下载时需要联网；模型越大，下载时间越长。
- 如果存储位置位于外置硬盘，使用 Whisper 前需要确保硬盘已连接。
- 应用采用临时签名；每次删除后重新构建，macOS 可能再次请求权限。
