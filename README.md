# 本地文字助手 · Local Text Helper for macOS

一个 macOS 菜单栏工具，用于截图识别文字与数学公式，以及朗读当前选中的中英文文本。

- **截图识别**：在菜单栏选「识别截图中的文字与公式」，拖动框选。用本机 Ollama 的 `qwen3.5:4b` 识别，公式以 LaTeX 输出，结果自动复制到剪贴板。
- **朗读**：先在其他应用里选中文字，再从菜单栏选「朗读所选文字」。使用 macOS 语音，菜单中可以停止。选区读取取决于前台应用的辅助功能支持。

## 从源码构建

需要 macOS 26 或更新版本、支持 macOS 26 的 Xcode 命令行工具与系统 Python 3。截图识别还需要安装 [Ollama](https://ollama.com/download/mac)，并先下载模型。

```sh
ollama pull qwen3.5:4b
sh build.sh
open "build/Local Text Helper.app"
```

按 macOS 提示分别开启屏幕录制或辅助功能权限。权限变更后可能需要重新打开应用。

截图在处理过程中写入临时目录，识别结束后删除。识别请求只发往本机回环地址。模型可能误识别公式中的上下标、希腊字母和矩阵元素，请核对关键公式。

这个公开版聚焦截图 OCR 和系统朗读。
