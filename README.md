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
- **Whisper MLX**：选择后按提示安装约 1 GB 的运行环境。默认使用 `mlx-community/whisper-small-mlx`（约 481 MB），也可以选择 `mlx-community/whisper-large-v3-turbo`（约 1.61 GB）。模型在第一次转写时下载到 `~/Library/Application Support/Transcribe/models`，后续可以离线使用。

Whisper MLX 运行环境位于 `~/Library/Application Support/Transcribe/whisper-runtime`。点击菜单中的“更新 Whisper MLX…”可以更新或修复运行环境。

## 开发命令

```bash
swift build       # Debug 编译
make app          # 生成 release .app
make run          # 生成并启动 .app
```

## 已知限制

- 密码框等安全输入区域不接受模拟输入。
- 某些远程桌面、虚拟机或游戏可能拦截全局快捷键。
- Whisper 模型第一次使用时需要联网下载；模型越大，首次转写等待时间越长。
- 应用采用临时签名；每次删除后重新构建，macOS 可能再次请求权限。
