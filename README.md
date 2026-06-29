# 奇想盒更新器

奇想盒更新器是一个 Windows 小工具，用来自动更新奇想盒相关组件：

- 从 `nikkigallery/Whimbox` 下载最新后端 `whimbox-*.whl`
- 从最近一个带 `whimbox_app-setup-*.exe` 的 Whimbox release 下载 APP 安装器
- 从 `nikkigallery/WhimboxScripts` 下载最新脚本 ZIP
- 安装或跳过已经是目标版本的 APP 和后端
- 覆盖更新奇想盒脚本目录，并尽量通知正在运行的奇想盒刷新脚本

## 怎么使用

### 直接运行

双击运行：

```text
奇想盒更新器.exe
```

如果电脑上已经能识别到奇想盒安装目录，更新器会自动使用已有位置。

如果没有识别到已有安装，更新器会提示输入安装路径：

```text
Install path [D:\APP\whimbox_app]
```

直接按回车会使用推荐默认路径；输入其他完整路径则会安装到指定位置。

### 指定安装路径

命令行运行时可以显式传入安装目录：

```powershell
.\奇想盒更新器.exe -InstallDir "D:\APP\whimbox_app"
```

也可以用环境变量指定：

```powershell
$env:QIXIANG_INSTALL_DIR = "E:\Tools\whimbox_app"
.\奇想盒更新器.exe
```

安装路径优先级如下：

1. 命令行参数 `-InstallDir`
2. 环境变量 `QIXIANG_INSTALL_DIR`
3. 已存在的奇想盒安装目录
4. 推荐默认路径，优先 `D:\APP\whimbox_app`

### 直接运行 PowerShell 源码

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\update_qixiang.ps1
```

无人值守运行时建议加上安装路径和免交互参数：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\update_qixiang.ps1 -InstallDir "D:\APP\whimbox_app" -NoPromptInstallDir -SkipAppLaunch
```

## 其他内容

### 行为说明

- 成功后默认不自动打开奇想盒 APP。
- 如果 APP 版本已经等于最新可用安装器版本，会跳过 APP 安装。
- 如果后端 `whimbox` 版本已经等于最新 wheel 版本，会跳过后端安装。
- 如果最新后端 release 没有 APP 安装器，会自动回退使用最近一个带安装器的 release。
- 失败时会保留命令行窗口，方便查看错误信息。

### 构建 exe

本项目的 exe 是一个很薄的启动器，内部嵌入 `src/update_qixiang.ps1` 并把命令行参数转交给脚本。

在 Windows PowerShell 5.1 或 PowerShell 7 中运行：

```powershell
.\build\build_exe.ps1
```

构建完成后会生成：

```text
奇想盒更新器.exe
```

### 依赖

- Windows 10/11
- PowerShell 5.1 或更高版本
- 网络可访问 GitHub
- 构建 exe 时需要本机可用 .NET Framework C# 编译能力

### 上游项目

- Whimbox: <https://github.com/nikkigallery/Whimbox>
- WhimboxScripts: <https://github.com/nikkigallery/WhimboxScripts>
