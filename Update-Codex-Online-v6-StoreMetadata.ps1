param(
    [switch]$NoLaunch,
    [switch]$KeepInstaller,
    [switch]$Force,
    [int]$RetryCount = 3,
    [int]$RetryDelaySeconds = 3
)

$ErrorActionPreference = 'Stop'

# Codex / ChatGPT Desktop package identity
$PackageName   = 'OpenAI.Codex'
$PackageFamily = 'OpenAI.Codex_2p2nqsd0c76g0'
$ProductId     = '9PLM9XGG6VKS'

# OpenAI manifest is used only for the announced buildVersion.
# The actual MSIX URL is resolved from Microsoft Store metadata.
$OpenAIManifestUrl = 'https://persistent.oaistatic.com/codex-app-prod/windows-store-update.json'

# Microsoft Store metadata endpoints
$DisplayCatalogBaseUrl = 'https://displaycatalog.mp.microsoft.com/v7.0/products'
$Fe3Endpoint            = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
$Fe3SecuredEndpoint     = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx/secured'

$DeviceAttributes = 'OSArchitecture=AMD64;DeviceFamily=Windows.Desktop;App=WU;AppVer=10.0.22621.1;OSVersion=10.0.22621.1;InstallationType=Client;IsDeviceRetailDemo=0;'

# Baseline Windows Store / Windows Update detectoids used when asking FE3
# for a normal Windows Desktop x64 app package.
$BaselineInstalledUpdateIds = @(
    1,2,3,11,19,544,549,2359974,5169044,8788830,23110993,23110994,
    54341900,54343656,59830006,59830007,59830008,60484010,
    62450018,62450019,62450020,66027979,66053150,97657898,
    98822896,98959022,98959023,98959024,98959025,98959026,
    104433538,104900364,105489019,117765322,129905029,130040031,
    132387090,132393049,138537048,140377312,143747671,158941041,
    158941042,158941043,158941044,159123858,159130928,164836897,
    164847386,164848327,164852241,164852246,164852252,164852253
)

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
        '-ExecutionPolicy','Bypass',
        '-File',"`"$PSCommandPath`"",
        '-RetryCount',$RetryCount,
        '-RetryDelaySeconds',$RetryDelaySeconds
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

function XmlEscape([string]$Value) {
    if ($null -eq $Value) { return '' }
    return [Security.SecurityElement]::Escape($Value)
}

function Format-SoapDate([DateTimeOffset]$Value) {
    return $Value.UtcDateTime.ToString(
        "yyyy-MM-dd'T'HH:mm:ss.fff'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    )
}

function New-SecurityHeader {
    $created = [DateTimeOffset]::UtcNow
    $expires = $created.AddMinutes(5)

    return @"
<o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
  <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
    <Created>$(Format-SoapDate $created)</Created>
    <Expires>$(Format-SoapDate $expires)</Expires>
  </Timestamp>
  <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA"
      xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"
      xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
    <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL">
      <User />
    </TicketType>
  </wuws:WindowsUpdateTicketsToken>
</o:Security>
"@
}

function New-SoapEnvelope(
    [string]$Action,
    [string]$To,
    [string]$Body
) {
    $messageId = [Guid]::NewGuid().ToString()

    return @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing"
            xmlns:s="http://www.w3.org/2003/05/soap-envelope">
  <s:Header>
    <a:Action s:mustUnderstand="1">$(XmlEscape $Action)</a:Action>
    <a:MessageID>urn:uuid:$messageId</a:MessageID>
    <a:To s:mustUnderstand="1">$(XmlEscape $To)</a:To>
    $(New-SecurityHeader)
  </s:Header>
  <s:Body>
    $Body
  </s:Body>
</s:Envelope>
"@
}

function Invoke-Soap(
    [string]$Url,
    [string]$Action,
    [string]$Body
) {
    $soap = New-SoapEnvelope -Action $Action -To $Url -Body $Body

    $headers = @{
        'MS-CV' = (([Guid]::NewGuid().ToString('N')).Substring(0,16) + '.0')
    }

    $response = Invoke-WebRequest `
        -Uri $Url `
        -Method Post `
        -Headers $headers `
        -ContentType 'application/soap+xml; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($soap)) `
        -UseBasicParsing `
        -TimeoutSec 120

    return $response.Content
}

function Find-PropertyRecursive($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }

    if ($Object -is [string] -or
        $Object -is [ValueType]) {
        return $null
    }

    if ($Object -is [Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -eq $Name) {
                return $Object[$key]
            }
            $found = Find-PropertyRecursive $Object[$key] $Name
            if ($null -ne $found) { return $found }
        }
        return $null
    }

    if ($Object -is [Collections.IEnumerable] -and
        -not ($Object -is [Management.Automation.PSCustomObject])) {
        foreach ($item in $Object) {
            $found = Find-PropertyRecursive $item $Name
            if ($null -ne $found) { return $found }
        }
        return $null
    }

    foreach ($prop in $Object.PSObject.Properties) {
        if ($prop.Name -eq $Name) {
            return $prop.Value
        }

        $found = Find-PropertyRecursive $prop.Value $Name
        if ($null -ne $found) { return $found }
    }

    return $null
}

function Resolve-WuCategoryId {
    $url = '{0}/{1}?market=US&languages=en-US,en,neutral' -f `
        $DisplayCatalogBaseUrl,
        [Uri]::EscapeDataString($ProductId)

    Write-Host "DisplayCatalog: $url"

    $catalog = Invoke-RestMethod `
        -Uri $url `
        -Method Get `
        -Headers @{
            'User-Agent' = 'Codex-Desktop-PowerShell-Updater/5.0'
            'MS-CV'      = (([Guid]::NewGuid().ToString('N')).Substring(0,16) + '.0')
        } `
        -TimeoutSec 60

    $wuCategoryId = Find-PropertyRecursive $catalog 'WuCategoryId'

    if ([string]::IsNullOrWhiteSpace([string]$wuCategoryId)) {
        throw "Microsoft DisplayCatalog 没有返回 ProductId $ProductId 的 WuCategoryId。"
    }

    return [string]$wuCategoryId
}

function Get-Fe3Cookie {
    $now = [DateTimeOffset]::UtcNow

    $body = @"
<GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
  <oldCookie></oldCookie>
  <lastChange>2015-10-21T17:01:07.1472913Z</lastChange>
  <currentTime>$(Format-SoapDate $now)</currentTime>
  <protocolVersion>1.40</protocolVersion>
</GetCookie>
"@

    $content = Invoke-Soap `
        -Url $Fe3Endpoint `
        -Action 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie' `
        -Body $body

    [xml]$xml = $content
    $node = $xml.SelectSingleNode("//*[local-name()='EncryptedData']")

    if ($null -eq $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) {
        throw 'Microsoft FE3 GetCookie 没有返回 EncryptedData。'
    }

    return $node.InnerText
}

function Get-StoreSyncXml(
    [string]$Cookie,
    [string]$WuCategoryId
) {
    $installedIds = ($BaselineInstalledUpdateIds | ForEach-Object {
        "<int>$_</int>"
    }) -join ''

    $expiration = Format-SoapDate ([DateTimeOffset]::UtcNow.AddDays(1))

    $body = @"
<SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
  <cookie>
    <Expiration>$expiration</Expiration>
    <EncryptedData>$(XmlEscape $Cookie)</EncryptedData>
  </cookie>
  <parameters>
    <ExpressQuery>false</ExpressQuery>
    <InstalledNonLeafUpdateIDs>$installedIds</InstalledNonLeafUpdateIDs>
    <OtherCachedUpdateIDs></OtherCachedUpdateIDs>
    <SkipSoftwareSync>false</SkipSoftwareSync>
    <NeedTwoGroupOutOfScopeUpdates>true</NeedTwoGroupOutOfScopeUpdates>
    <FilterAppCategoryIds>
      <CategoryIdentifier>
        <Id>$(XmlEscape $WuCategoryId)</Id>
      </CategoryIdentifier>
    </FilterAppCategoryIds>
    <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
    <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
    <ComputerSpec />
    <ExtendedUpdateInfoParameters>
      <XmlUpdateFragmentTypes>
        <XmlUpdateFragmentType>Extended</XmlUpdateFragmentType>
      </XmlUpdateFragmentTypes>
      <Locales>
        <string>en-US</string>
        <string>en</string>
      </Locales>
    </ExtendedUpdateInfoParameters>
    <ClientPreferredLanguages>
      <string>en-US</string>
    </ClientPreferredLanguages>
    <ProductsParameters>
      <SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
      <DeviceAttributes>$DeviceAttributes</DeviceAttributes>
      <CallerAttributes>Interactive=1;IsSeeker=0;</CallerAttributes>
      <Products />
    </ProductsParameters>
  </parameters>
</SyncUpdates>
"@

    return Invoke-Soap `
        -Url $Fe3Endpoint `
        -Action 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates' `
        -Body $body
}

function Get-StorePackageCandidate([string]$SyncXml) {
    [xml]$doc = $SyncXml
    $nodes = $doc.SelectNodes("//*[local-name()='Xml']")

    $candidates = @()

    foreach ($node in $nodes) {
        $fragment = [Net.WebUtility]::HtmlDecode($node.InnerText)

        if ($fragment.IndexOf('AppxMetadata',[StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }
        if ($fragment.IndexOf('SecuredFragment',[StringComparison]::OrdinalIgnoreCase) -lt 0) {
            continue
        }

        $identityTag = [regex]::Match(
            $fragment,
            '<UpdateIdentity\b[^>]*>',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $appxTag = [regex]::Match(
            $fragment,
            '<AppxMetadata\b[^>]*>',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $identityTag.Success -or -not $appxTag.Success) {
            continue
        }

        $idMatch = [regex]::Match(
            $identityTag.Value,
            'UpdateID="(?<v>[^"]+)"',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $revisionMatch = [regex]::Match(
            $identityTag.Value,
            'RevisionNumber="(?<v>[^"]+)"',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $monikerMatch = [regex]::Match(
            $appxTag.Value,
            'PackageMoniker="(?<v>[^"]+)"',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        $typeMatch = [regex]::Match(
            $appxTag.Value,
            'PackageType="(?<v>[^"]+)"',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $idMatch.Success -or
            -not $revisionMatch.Success -or
            -not $monikerMatch.Success) {
            continue
        }

        $moniker = $monikerMatch.Groups['v'].Value

        if ($moniker -notmatch '^OpenAI\.Codex_(?<ver>\d+(?:\.\d+){3})_x64__') {
            continue
        }

        $candidates += [pscustomobject]@{
            PackageMoniker = $moniker
            PackageType    = if ($typeMatch.Success) { $typeMatch.Groups['v'].Value } else { '' }
            UpdateId       = $idMatch.Groups['v'].Value
            RevisionNumber = $revisionMatch.Groups['v'].Value
            Version        = [version]$Matches['ver']
        }
    }

    $candidate = $candidates |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $candidate) {
        throw 'Microsoft FE3 没有返回匹配 OpenAI.Codex x64 的程序包。'
    }

    return $candidate
}

function Resolve-MicrosoftPackageUrl(
    [string]$UpdateId,
    [string]$RevisionNumber
) {
    $body = @"
<GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
  <updateIDs>
    <UpdateIdentity>
      <UpdateID>$(XmlEscape $UpdateId)</UpdateID>
      <RevisionNumber>$(XmlEscape $RevisionNumber)</RevisionNumber>
    </UpdateIdentity>
  </updateIDs>
  <infoTypes>
    <XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType>
    <XmlUpdateFragmentType>FileDecryption</XmlUpdateFragmentType>
  </infoTypes>
  <deviceAttributes>$DeviceAttributes</deviceAttributes>
</GetExtendedUpdateInfo2>
"@

    $content = Invoke-Soap `
        -Url $Fe3SecuredEndpoint `
        -Action 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2' `
        -Body $body

    [xml]$doc = $content
    $urls = @()

    foreach ($node in $doc.SelectNodes("//*[local-name()='Url']")) {
        $text = $node.InnerText.Trim()
        $uri = $null

        if ([Uri]::TryCreate($text,[UriKind]::Absolute,[ref]$uri)) {
            $urls += $text
        }
    }

    $url = $urls |
        Sort-Object Length -Descending |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Microsoft FE3 没有为 $UpdateId/$RevisionNumber 返回下载 URL。"
    }

    $resolvedUri = [Uri]$url
    $cdnHost = $resolvedUri.Host.ToLowerInvariant()

    # FE3 package payloads normally come from Microsoft Delivery CDN.
    # Keep the check broad enough for official delivery subdomains.
    if (-not (
        $cdnHost -eq 'delivery.mp.microsoft.com' -or
        $cdnHost.EndsWith('.delivery.mp.microsoft.com')
    )) {
        throw "FE3 返回了非预期的下载主机：$cdnHost"
    }

    return $url
}

function Download-File(
    [string]$Url,
    [string]$Destination
) {
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue

    if (-not $curl) {
        throw '系统未找到 curl.exe。Windows 10/11 正常情况下应自带 curl.exe。'
    }

    $part = "$Destination.part"

    for ($i = 1; $i -le [Math]::Max(1,$RetryCount); $i++) {
        if (Test-Path -LiteralPath $part) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        }

        Write-Host "下载尝试 $i/$([Math]::Max(1,$RetryCount)) ..."

        & $curl.Source `
            --location `
            --fail `
            --show-error `
            --connect-timeout 20 `
            --max-time 1800 `
            --output $part `
            $Url

        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $part)) {
            Move-Item -LiteralPath $part -Destination $Destination -Force
            return
        }

        if ($i -lt [Math]::Max(1,$RetryCount)) {
            Start-Sleep -Seconds ([Math]::Max(0,$RetryDelaySeconds))
        }
    }

    throw "MSIX 下载失败，curl 最后退出码：$LASTEXITCODE"
}

function Get-MsixIdentity([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entry = $zip.Entries |
            Where-Object { $_.FullName -ieq 'AppxManifest.xml' } |
            Select-Object -First 1

        if (-not $entry) {
            throw 'MSIX 中没有找到 AppxManifest.xml。'
        }

        $reader = New-Object IO.StreamReader($entry.Open())
        try {
            [xml]$manifest = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }

        $identity = $manifest.Package.Identity

        return [pscustomobject]@{
            Name         = [string]$identity.Name
            Version      = [version]([string]$identity.Version)
            Architecture = [string]$identity.ProcessorArchitecture
            Publisher    = [string]$identity.Publisher
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Stop-CodexDesktop {
    Write-Step '关闭 Windows 版 Codex / ChatGPT Desktop'

    $prefix = Join-Path $env:ProgramFiles 'WindowsApps\OpenAI.Codex_'

    $processes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $prefix,
                [StringComparison]::OrdinalIgnoreCase
            )
        }

    if ($processes) {
        foreach ($p in $processes) {
            Write-Host "关闭: $($p.Name)  PID=$($p.ProcessId)"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
    } else {
        Write-Host '未发现正在运行的 Windows MSIX 版 Codex。'
    }

    $remaining = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $prefix,
                [StringComparison]::OrdinalIgnoreCase
            )
        }

    if ($remaining) {
        $remaining |
            Select-Object ProcessId,Name,ExecutablePath |
            Format-Table -AutoSize
        throw '仍有 Codex Desktop 进程未退出，已停止安装。'
    }
}

try {
    # Appx module is most reliable under Windows PowerShell 5.1.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Write-Host '检测到 PowerShell 7，正在切换到 Windows PowerShell 5.1...' -ForegroundColor Yellow
        Relaunch-Self
    }

    # Elevate.
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $isAdmin) {
        Write-Host '需要管理员权限，正在请求 UAC...' -ForegroundColor Yellow
        Relaunch-Self -Admin
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {}

    Write-Step '读取当前 Codex Desktop 版本'
    $current = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue

    if (-not $current) {
        throw '没有检测到已安装的 OpenAI.Codex。此脚本当前只用于更新现有 Codex Desktop。'
    }

    $currentVersion = [version]$current.Version
    Write-Host "当前版本 : $currentVersion"
    Write-Host "当前状态 : $($current.Status)"
    Write-Host "安装路径 : $($current.InstallLocation)"

    Write-Step '读取 OpenAI 公布的 Windows 目标版本（可选参考）'
    $announcedVersion = $null

    try {
        $openAIManifest = Invoke-RestMethod `
            -Uri $OpenAIManifestUrl `
            -Method Get `
            -Headers @{
                'Cache-Control' = 'no-cache'
                'Pragma'        = 'no-cache'
                'User-Agent'    = 'Codex-Desktop-PowerShell-Updater/5.0'
            } `
            -TimeoutSec 30

        if ($openAIManifest.buildVersion) {
            $announcedVersion = [version]([string]$openAIManifest.buildVersion)
            Write-Host "OpenAI buildVersion : $announcedVersion"
        } else {
            Write-Host 'OpenAI 清单当前未返回 buildVersion；继续以 Microsoft Store 元数据为准。' -ForegroundColor Yellow
        }

        if ($openAIManifest.packagePath) {
            Write-Host 'OpenAI 清单包含 packagePath，但本脚本不会依赖它。'
        } else {
            Write-Host 'OpenAI 清单没有 packagePath（正常）；将从 Microsoft Store 元数据解析真实 MSIX。'
        }
    }
    catch {
        Write-Host "读取 OpenAI 清单失败：$($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '继续以 Microsoft Store 元数据为准。' -ForegroundColor Yellow
    }

    Write-Step '从 Microsoft Store DisplayCatalog 获取 Codex 产品元数据'
    $wuCategoryId = Resolve-WuCategoryId
    Write-Host "WuCategoryId : $wuCategoryId"

    Write-Step '查询 Microsoft FE3，解析最新 x64 Codex MSIX'
    $cookie   = Get-Fe3Cookie
    $syncXml  = Get-StoreSyncXml -Cookie $cookie -WuCategoryId $wuCategoryId
    $package  = Get-StorePackageCandidate -SyncXml $syncXml

    Write-Host "Store 包名 : $($package.PackageMoniker)"
    Write-Host "Store 版本 : $($package.Version)"
    Write-Host "Update ID  : $($package.UpdateId)"
    Write-Host "Revision   : $($package.RevisionNumber)"

    if ($announcedVersion -and $package.Version -ne $announcedVersion) {
        Write-Host ""
        Write-Host "注意：OpenAI buildVersion=$announcedVersion，而 Microsoft Store 当前解析到 $($package.Version)。" -ForegroundColor Yellow
        Write-Host '脚本将以 Microsoft Store 当前实际可下载的签名包为准。' -ForegroundColor Yellow
    }

    if (-not $Force -and $package.Version -le $currentVersion) {
        Write-Host ""
        Write-Host "当前版本 $currentVersion 已经不低于 Microsoft Store 可下载版本 $($package.Version)。" -ForegroundColor Green
        Pause-OnExit
        exit 0
    }

    Write-Step '向 Microsoft FE3 获取临时官方 CDN 下载地址'
    $packageUrl = Resolve-MicrosoftPackageUrl `
        -UpdateId $package.UpdateId `
        -RevisionNumber $package.RevisionNumber

    $displayUrl = $packageUrl
    if ($displayUrl.Length -gt 180) {
        $displayUrl = $displayUrl.Substring(0,180) + '...'
    }
    Write-Host "Microsoft CDN : $displayUrl"

    $workDir = Join-Path $env:TEMP "CodexDesktopUpdate\$($package.Version)"
    $msixPath = Join-Path $workDir ($package.PackageMoniker + '.Msix')
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null

    Write-Step "下载 Codex MSIX $($package.Version)"
    if (-not (Test-Path -LiteralPath $msixPath) -or $Force) {
        if (Test-Path -LiteralPath $msixPath) {
            Remove-Item -LiteralPath $msixPath -Force
        }
        Download-File -Url $packageUrl -Destination $msixPath
    } else {
        Write-Host "使用已存在的安装包：$msixPath"
    }

    $file = Get-Item -LiteralPath $msixPath
    if ($file.Length -lt 1MB) {
        throw "下载文件异常小：$($file.Length) bytes"
    }

    Write-Step '校验 MSIX 身份'
    $msixIdentity = Get-MsixIdentity -Path $msixPath
    $sha256 = (Get-FileHash -LiteralPath $msixPath -Algorithm SHA256).Hash

    Write-Host "Name      : $($msixIdentity.Name)"
    Write-Host "Version   : $($msixIdentity.Version)"
    Write-Host "Arch      : $($msixIdentity.Architecture)"
    Write-Host ("Size      : {0:N2} MB" -f ($file.Length / 1MB))
    Write-Host "SHA256    : $sha256"

    if ($msixIdentity.Name -ne $PackageName) {
        throw "MSIX 包名不匹配：期望 $PackageName，实际 $($msixIdentity.Name)"
    }

    if ($msixIdentity.Version -ne $package.Version) {
        throw "MSIX 版本不匹配：Store=$($package.Version)，MSIX=$($msixIdentity.Version)"
    }

    if ($msixIdentity.Architecture -and
        $msixIdentity.Architecture -notin @('x64','neutral')) {
        throw "MSIX 架构不是 x64/neutral：$($msixIdentity.Architecture)"
    }

    Stop-CodexDesktop

    Write-Step "安装 Codex Desktop $($package.Version)"
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

    if ($afterVersion -ne $package.Version -or $after.Status -ne 'Ok') {
        throw "安装完成，但验证失败：版本=$afterVersion，状态=$($after.Status)"
    }

    Write-Host ""
    Write-Host "Codex Desktop 已成功更新到 $afterVersion。" -ForegroundColor Green

    if ($KeepInstaller) {
        Write-Host "安装包已保留：$msixPath"
    } else {
        try {
            Remove-Item -LiteralPath $msixPath -Force -ErrorAction Stop
            Write-Host '已删除临时 MSIX。'
        } catch {
            Write-Host "临时 MSIX 未能删除：$msixPath" -ForegroundColor Yellow
        }
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
        Select-Object -First 8 TimeCreated,Id,LevelDisplayName,Message |
        Format-List
    } catch {}

    Pause-OnExit
    exit 1
}
