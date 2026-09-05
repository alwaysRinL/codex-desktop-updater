param(
    [switch]$NoLaunch,
    [switch]$KeepInstaller,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$PackageName   = 'OpenAI.Codex'
$PackageFamily = 'OpenAI.Codex_2p2nqsd0c76g0'
$FeedUrl       = 'https://persistent.oaistatic.com/codex-app-prod/windows-store-update.json'
$AllowedHost   = 'persistent.oaistatic.com'

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Pause-OnExit {
    if ($Host.Name -eq 'ConsoleHost') {
        Write-Host ""
        [void](Read-Host '按 Enter 退出')
    }
}

function Relaunch-Self([switch]$Admin) {
    $ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $argsList = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`""
    )

    if ($NoLaunch)      { $argsList += '-NoLaunch' }
    if ($KeepInstaller) { $argsList += '-KeepInstaller' }
    if ($Force)         { $argsList += '-Force' }

    if ($Admin) {
        Start-Process -FilePath $ps51 -ArgumentList $argsList -Verb RunAs
    } else {
        Start-Process -FilePath $ps51 -ArgumentList $argsList
    }
    exit
}

try {
    # Windows PowerShell 5.1 对 Appx 模块兼容最好。
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Write-Host '检测到 PowerShell 7，正在切换到 Windows PowerShell 5.1...' -ForegroundColor Yellow
        Relaunch-Self
    }

    # 提升为管理员。
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Host '需要管理员权限，正在请求 UAC...' -ForegroundColor Yellow
        Relaunch-Self -Admin
    }

    # 确保 TLS 1.2 可用。
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    Write-Step '读取当前 Codex Desktop 版本'
    $current = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if ($current) {
        $currentVersion = [version]$current.Version
        Write-Host "当前版本 : $currentVersion"
        Write-Host "当前状态 : $($current.Status)"
        Write-Host "安装路径 : $($current.InstallLocation)"
    } else {
        $currentVersion = [version]'0.0.0.0'
        Write-Host '当前未检测到 OpenAI.Codex，将按全新安装处理。' -ForegroundColor Yellow
    }

    Write-Step '从 OpenAI 更新源获取最新版信息'
    $feed = Invoke-RestMethod `
        -Uri $FeedUrl `
        -Method Get `
        -TimeoutSec 30 `
        -Headers @{ 'User-Agent' = 'Codex-Desktop-Manual-Updater/1.0' }

    if (-not $feed.buildVersion) {
        throw '更新源没有返回 buildVersion。'
    }

    $latestVersion = [version]$feed.buildVersion

    if ($feed.packagePath) {
        $packageUrl = [string]$feed.packagePath
    } else {
        # 官方更新器历史上使用的固定 release 路径。
        $packageUrl = "https://persistent.oaistatic.com/codex-app-prod/releases/$latestVersion/ChatGPT-x64.msix"
    }

    $uri = [Uri]$packageUrl
    if ($uri.Scheme -ne 'https' -or
        $uri.Host -ne $AllowedHost -or
        -not $uri.AbsolutePath.StartsWith('/codex-app-prod/', [StringComparison]::OrdinalIgnoreCase)) {
        throw "更新源返回了非预期下载地址，已拒绝下载：$packageUrl"
    }

    Write-Host "最新版本 : $latestVersion"
    Write-Host "下载地址 : $packageUrl"

    if (-not $Force -and $currentVersion -ge $latestVersion) {
        Write-Host ""
        Write-Host '当前版本已经是最新版，无需下载。' -ForegroundColor Green
        Pause-OnExit
        exit 0
    }

    $workDir = Join-Path $env:TEMP "CodexDesktopUpdate\$latestVersion"
    $msixPath = Join-Path $workDir 'ChatGPT-x64.msix'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    Write-Step '下载 Codex MSIX 安装包'
    if ((Test-Path -LiteralPath $msixPath) -and -not $Force) {
        Write-Host "发现已下载文件，准备校验：$msixPath"
    } else {
        if (Test-Path -LiteralPath $msixPath) {
            Remove-Item -LiteralPath $msixPath -Force
        }

        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($curl) {
            Write-Host '使用 curl.exe 下载（失败自动重试 3 次）...'
            & $curl.Source `
                --location `
                --fail `
                --show-error `
                --connect-timeout 20 `
                --retry 3 `
                --retry-delay 2 `
                --output $msixPath `
                $packageUrl

            if ($LASTEXITCODE -ne 0) {
                throw "下载失败，curl 退出码：$LASTEXITCODE。现有 Codex 不会被修改。"
            }
        } else {
            Write-Host '未找到 curl.exe，改用 Invoke-WebRequest...'
            Invoke-WebRequest `
                -Uri $packageUrl `
                -OutFile $msixPath `
                -UseBasicParsing `
                -TimeoutSec 1800
        }
    }

    if (-not (Test-Path -LiteralPath $msixPath)) {
        throw '下载结束后没有找到 MSIX 文件。'
    }

    $fileInfo = Get-Item -LiteralPath $msixPath
    if ($fileInfo.Length -lt 1MB) {
        throw "下载文件异常小（$($fileInfo.Length) bytes），可能是错误页面或 CDN 尚未发布该包。"
    }

    $sha256 = (Get-FileHash -LiteralPath $msixPath -Algorithm SHA256).Hash
    Write-Host ("文件大小 : {0:N2} MB" -f ($fileInfo.Length / 1MB))
    Write-Host "SHA256   : $sha256"

    # 如果更新源提供 SHA256，则严格比对。
    if ($feed.sha256) {
        $expectedHash = ([string]$feed.sha256).Replace(' ', '').ToUpperInvariant()
        if ($sha256.ToUpperInvariant() -ne $expectedHash) {
            throw "SHA256 校验失败。期望：$expectedHash，实际：$sha256"
        }
        Write-Host 'SHA256 与更新源一致。' -ForegroundColor Green
    }

    Write-Step '校验 MSIX 内部程序包身份'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($msixPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -ieq 'AppxManifest.xml' } | Select-Object -First 1
        if (-not $entry) {
            throw 'MSIX 中没有找到 AppxManifest.xml。'
        }

        $reader = New-Object IO.StreamReader($entry.Open())
        try {
            [xml]$manifestXml = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }

        $identityNode = $manifestXml.Package.Identity
        $msixName     = [string]$identityNode.Name
        $msixVersion  = [version]([string]$identityNode.Version)
        $msixArch     = [string]$identityNode.ProcessorArchitecture

        Write-Host "程序包名 : $msixName"
        Write-Host "包版本   : $msixVersion"
        Write-Host "架构     : $msixArch"

        if ($msixName -ne $PackageName) {
            throw "程序包身份不匹配：期望 $PackageName，实际 $msixName"
        }

        if ($msixVersion -ne $latestVersion) {
            throw "程序包版本与更新源不一致：源=$latestVersion，MSIX=$msixVersion"
        }

        if ($msixArch -and $msixArch -notin @('x64', 'neutral')) {
            throw "下载到的程序包架构不是 x64/neutral：$msixArch"
        }
    }
    finally {
        if ($zip) { $zip.Dispose() }
    }

    Write-Step '关闭 Windows 版 Codex Desktop'
    $windowsAppsPrefix = Join-Path $env:ProgramFiles 'WindowsApps\OpenAI.Codex_'

    $desktopProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $windowsAppsPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )
        }

    if ($desktopProcesses) {
        foreach ($p in $desktopProcesses) {
            Write-Host "关闭: $($p.Name)  PID=$($p.ProcessId)"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
    } else {
        Write-Host '未发现正在运行的 Windows Store/MSIX 版 Codex。'
    }

    # 再确认一次。这里只匹配 WindowsApps 下的 Codex，不会影响 npm Codex CLI。
    $remaining = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $windowsAppsPrefix,
                [StringComparison]::OrdinalIgnoreCase
            )
        }

    if ($remaining) {
        Write-Host '仍有以下桌面版进程未退出：' -ForegroundColor Yellow
        $remaining | Select-Object ProcessId, Name, ExecutablePath | Format-Table -AutoSize
        throw '无法完全关闭 Codex Desktop，已停止安装。'
    }

    Write-Step "安装/更新到 $latestVersion"
    Write-Host 'Windows 将在此步骤验证 MSIX 的程序包签名。'
    Add-AppxPackage `
        -Path $msixPath `
        -ForceApplicationShutdown

    Start-Sleep -Seconds 2

    Write-Step '验证安装结果'
    $after = Get-AppxPackage -Name $PackageName -ErrorAction Stop
    $afterVersion = [version]$after.Version

    Write-Host "安装前 : $currentVersion"
    Write-Host "安装后 : $afterVersion"
    Write-Host "状态   : $($after.Status)"
    Write-Host "路径   : $($after.InstallLocation)"

    if ($afterVersion -ne $latestVersion -or $after.Status -ne 'Ok') {
        throw "安装命令已结束，但版本/状态不符合预期。版本=$afterVersion，状态=$($after.Status)"
    }

    Write-Host ""
    Write-Host "Codex Desktop 已成功更新到 $afterVersion。" -ForegroundColor Green

    if (-not $KeepInstaller) {
        try {
            Remove-Item -LiteralPath $msixPath -Force -ErrorAction Stop
            Write-Host '已删除临时 MSIX 安装包。'
        } catch {
            Write-Host "临时安装包未能删除，可手动删除：$msixPath" -ForegroundColor Yellow
        }
    } else {
        Write-Host "安装包已保留：$msixPath"
    }

    if (-not $NoLaunch) {
        Write-Step '重新启动 Codex Desktop'
        Start-Process explorer.exe "shell:AppsFolder\$PackageFamily!App"
    }
}
catch {
    Write-Host ""
    Write-Host '更新失败：' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($msixPath -and (Test-Path -LiteralPath $msixPath)) {
        Write-Host ""
        Write-Host "已下载文件保留在：$msixPath" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host '最近的 AppXDeploymentServer 事件：' -ForegroundColor Yellow
    try {
        Get-WinEvent `
            -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' `
            -MaxEvents 30 `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Message -match 'OpenAI\.Codex|2p2nqsd0c76g0'
        } |
        Select-Object -First 8 TimeCreated, Id, LevelDisplayName, Message |
        Format-List
    } catch {}

    Pause-OnExit
    exit 1
}
