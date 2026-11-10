# 本地文字助手 · Local Text Helper for macOS

macOS 菜单栏助手。开启辅助功能权限后，在其他应用中选中文字，浮动面板会显示以下操作：

- **英文润色**：把选区译成自然英文，或润色已有英文。
- **译为中文**：把选区译成简体中文。
- **智能清理**：清理多余空格、断行和标点，核对字词与数字是否保留。
- **加入 To Do**：提取任务标题和截止日期，预览并确认后写入 Microsoft To Do。
- **朗读**：使用 macOS 系统语音朗读中文和英文。也可以从菜单栏停止。

前三项使用本机 Ollama。结果可以编辑、复制，或在应用支持时替换原选区。选区读取和替换取决于前台应用的辅助功能支持。可从菜单栏暂停浮动面板。

菜单栏的「识别截图中的文字与公式」支持框选截图，使用本机 Ollama 识别文字并以 LaTeX 输出公式，结果自动复制到剪贴板。

## 从源码构建

需要 macOS 26 或更新版本、支持 macOS 26 的 Xcode 命令行工具与系统 Python 3。翻译、清理、截图识别和任务提取还需要安装 [Ollama](https://ollama.com/download/mac)，并先下载模型。

```sh
ollama pull qwen3.5:4b
sh build.sh
open "build/Local Text Helper.app"
```

从菜单栏选择「启用选区功能」并按系统提示开启辅助功能权限。使用截图功能时另需屏幕录制权限。权限变更后可能需要重新打开应用。

## 可选 · 连接 Microsoft To Do

安装 [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/install-powershell-on-macos)，然后在仓库目录运行：

```sh
pwsh -NoProfile -Command 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
pwsh -NoProfile -File ./graph_todo.ps1 -Operation connect
```

按提示在 Microsoft 官方登录页面完成设备登录。默认使用个人 Microsoft 账号。工作或学校账号可用 `-Tenant organizations` 重试，能否授权取决于组织策略。应用使用委托权限 `Tasks.ReadWrite`，写入登录账号的默认 Tasks 列表。登录过期时可重新运行连接命令。

任务先在本机提取。预览中有歧义时，请修改原文或缩小选区后重试。确认后，任务标题和截止日期会发给 Microsoft Graph。授权缓存、账号与列表绑定以及用于防重复提交的记录均保存在本机。

## 数据处理

模型请求使用本机回环地址。截图在处理过程中写入临时目录，识别结束后删除。模型可能误识别公式符号或日期，请在使用前核对预览。
