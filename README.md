# Codex Desktop Online Updater

这是一个用于 **Windows 版 Codex Desktop** 的 PowerShell 更新脚本。

它用于解决 Codex 桌面端点击“更新”后无法正常完成升级、需要反复点击多次、或因应用未正确退出导致 `0x80070005` 的问题。

脚本会绕过 Codex 自带的最后一段更新安装流程，直接联网获取 OpenAI 官方发布的 Windows MSIX 安装包，并交给 Windows AppX/MSIX 机制完成安装和注册。

---

## 功能

- 自动读取当前已安装的 Codex Desktop 版本
- 自动访问 OpenAI Windows 更新源获取最新版
- 自动下载官方 `ChatGPT-x64.msix`
- 自动校验：
  - 程序包名称
  - 程序包版本
  - CPU 架构
  - SHA256（如果更新源提供）
- 自动关闭 Windows Store / MSIX 版 Codex Desktop
- 不会结束 npm 安装的 Codex CLI
- 使用 Windows `Add-AppxPackage` 完成安装
- 自动验证更新后的版本和状态
- 更新成功后可自动重新启动 Codex
- 支持保留安装包
- 支持仅安装、不自动启动

---

## 适用场景

例如 Codex 更新时出现：

```text
错误 0x80070005:
无法安装，因为需要关闭以下应用:
OpenAI.Codex_2p2nqsd0c76g0!App
```

或者：

```text
程序包未更新，因为受影响的应用仍在运行。
```

以及类似现象：

```text
点击更新
→ 没反应
→ 再点
→ 仍然没更新
→ 反复点击多次后偶尔成功
```

此脚本可以直接完成：

```text
获取最新版
→ 下载官方 MSIX
→ 关闭 Codex Desktop
→ 安装新版
→ 验证版本
→ 重新启动
```

---

## 系统要求

- Windows 10 / Windows 11
- 已安装 Codex Desktop，或准备首次安装 Codex Desktop
- 可以访问 OpenAI 更新 CDN
- Windows PowerShell 5.1
- 管理员权限
- Windows AppX/MSIX 组件工作正常

脚本如果在 PowerShell 7 中运行，会自动切换到 Windows PowerShell 5.1。

---

## 使用方法

将以下两个文件放在同一目录即可：

```text
Update-Codex-Online.ps1
README.md
```

### 默认更新

在 PowerShell 中执行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Update-Codex-Online.ps1"
```

脚本会：

1. 检查当前版本
2. 获取最新版
3. 下载 MSIX
4. 关闭 Codex Desktop
5. 安装新版
6. 验证更新结果
7. 自动重新打开 Codex

---

## 参数

### 不自动启动 Codex

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Update-Codex-Online.ps1" -NoLaunch
```

更新成功后不会自动重新打开 Codex。

---

### 保留下载的安装包

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Update-Codex-Online.ps1" -KeepInstaller
```

默认情况下，更新成功后临时 MSIX 文件会被删除。

使用 `-KeepInstaller` 后，安装包会保留在类似目录：

```text
%TEMP%\CodexDesktopUpdate\<版本号>\ChatGPT-x64.msix
```

---

### 强制重新下载 / 安装

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Update-Codex-Online.ps1" -Force
```

即使本地已经存在对应安装包，也会重新下载。

适合：

- 怀疑之前下载文件损坏
- 想重新安装当前版本
- 调试下载或安装问题

---

### 参数组合

例如：

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Update-Codex-Online.ps1" -KeepInstaller -NoLaunch
```

表示：

- 保留 MSIX
- 更新后不自动启动 Codex

---

## 更新源

脚本使用 OpenAI Windows Codex Desktop 更新源：

```text
https://persistent.oaistatic.com/codex-app-prod/windows-store-update.json
```

安装包来自：

```text
https://persistent.oaistatic.com/codex-app-prod/
```

脚本只接受：

```text
https://persistent.oaistatic.com/codex-app-prod/...
```

范围内的安装地址。

如果更新源返回其他域名或非 HTTPS 地址，脚本会拒绝下载。

---

## 安装方式

脚本下载的是完整 MSIX 包，然后使用：

```powershell
Add-AppxPackage -Path <msix> -ForceApplicationShutdown
```

完成安装。

与手动注册已 Stage 包的方式不同：

```powershell
Add-AppxPackage -Register AppxManifest.xml
```

本脚本不依赖 Codex 自带更新器是否已经提前 Stage 新版本。

---

## 不会影响 Codex CLI

如果你的 Codex CLI 是通过 npm 安装，例如：

```text
D:\nvm\v24.x.x\node_modules\@openai\codex\...\codex.exe
```

本脚本不会结束它。

脚本只会关闭位于以下路径中的 Codex Desktop 进程：

```text
C:\Program Files\WindowsApps\OpenAI.Codex_*
```

所以：

```text
Codex Desktop
```

和：

```text
npm Codex CLI
```

可以同时存在。

---

## 常见问题

### 1. 提示当前已经是最新版

例如：

```text
当前版本已经是最新版，无需下载。
```

说明当前安装版本已经不低于 OpenAI 更新源公布的版本。

无需处理。

---

### 2. 下载返回 404

可能出现：

```text
curl: (22) The requested URL returned error: 404
```

通常表示：

- 更新清单已经发布新版本
- 但对应 MSIX 尚未同步到 CDN

脚本会直接停止，不会修改现有 Codex。

稍后重新运行即可。

---

### 3. 下载超时

可能出现：

```text
curl: (28) Operation timed out
```

检查：

- 网络连接
- 代理
- Clash / Mihomo / sing-box / v2rayN
- `persistent.oaistatic.com` 是否能正常访问

可以测试：

```powershell
curl.exe -I https://persistent.oaistatic.com/
```

返回 `404` 本身不代表异常，只要 TLS / HTTP 请求能够正常完成即可。

---

### 4. 安装时出现 0x80070005

如果提示：

```text
无法安装，因为需要关闭以下应用:
OpenAI.Codex_2p2nqsd0c76g0!App
```

说明 Codex Desktop 仍然有进程没有退出。

先关闭 Codex，再运行：

```powershell
Get-CimInstance Win32_Process |
Where-Object {
    $_.ExecutablePath -like 'C:\Program Files\WindowsApps\OpenAI.Codex_*'
} |
Select-Object ProcessId,Name,ExecutablePath
```

如果仍然有输出，可以结束这些进程后重新运行脚本。

---

### 5. PowerShell 7 无法加载 Appx 模块

例如：

```text
The 'Get-AppxPackage' command was found in the module 'Appx',
but the module could not be loaded.
```

这是 PowerShell 7 与部分 Windows AppX 模块兼容性问题。

本脚本检测到 PowerShell 7 后会自动切换到：

```text
Windows PowerShell 5.1
```

无需手动处理。

---

### 6. WindowsApps 无权限

脚本会自动请求管理员权限。

如果仍然无法访问，请使用：

```text
以管理员身份运行 PowerShell
```

然后重新执行脚本。

---

## 查看当前 Codex Desktop 版本

```powershell
Get-AppxPackage OpenAI.Codex |
Format-List Name,Version,Status,InstallLocation
```

正常情况下应类似：

```text
Name            : OpenAI.Codex
Version         : 26.x.x.x
Status          : Ok
InstallLocation : C:\Program Files\WindowsApps\OpenAI.Codex_...
```

---

## 查看 AppX 安装日志

如果安装失败，可以查看：

```powershell
Get-WinEvent `
  -LogName "Microsoft-Windows-AppXDeploymentServer/Operational" `
  -MaxEvents 50 |
Where-Object {
    $_.Message -match "OpenAI.Codex|2p2nqsd0c76g0"
} |
Select-Object TimeCreated,Id,LevelDisplayName,Message |
Format-List
```

常见错误：

```text
0x80070005
```

通常表示：

```text
Codex Desktop 仍在运行
```

---

## 安全说明

本脚本：

- 不修改 WindowsApps 权限
- 不删除 Codex 用户数据
- 不卸载旧版后再安装
- 不修改注册表
- 不修改系统代理
- 不修改 npm Codex CLI
- 不绕过 Windows MSIX 签名检查

安装过程仍由 Windows AppX/MSIX 机制完成。

如果下载安装失败，脚本会停止，现有 Codex Desktop 不会被卸载。

---

## 文件

主脚本：

```text
Update-Codex-Online.ps1
```

README：

```text
README.md
```

---

## 建议使用流程

平时不再需要反复点击 Codex 内部的“更新”按钮。

直接运行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File ".\Update-Codex-Online.ps1"
```

即可检查并安装最新版 Codex Desktop。
