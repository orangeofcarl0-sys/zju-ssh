# zju-ssh.ps1 — ZJU SSH 助手 CLI v2.1（全配置驱动：工作站地址/端口/别名/服务器均可配）
# 子命令：init / up / down / doctor / connect / install-task / uninstall-task
# 退出码约定：0=成功，1=失败，2=用法错误（connect 返回 sshpipe 的退出码）
# 共享逻辑在 zju-common.psm1（探测/配置 DPAPI/状态/默认值）；GUI 与本文共用同一套。

param(
    [Parameter(Position = 0)][string]$Cmd = 'doctor',
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [string]$Mode = 'tun',
    [string]$SshUser,
    [string]$VpnUser,
    [string]$VpnPassword,
    [string]$SshHost,
    [int]$SshPort = 0,
    [string]$HostAlias,
    [string]$Server,
    [int]$ZjuPort = 0,
    [string]$ZjuRepo,
    [switch]$NoDownload
)

# 注意：$PSBoundParameters 在函数内指函数自己的绑定（恒空），必须在脚本作用域先记录
$script:VpnUserPassed = $PSBoundParameters.ContainsKey('VpnUser')

$ErrorActionPreference = 'Stop'
# 输出统一 UTF-8：GUI 以重定向方式读取子进程输出，默认 GBK 代码页会把 ✓/✗ 等字符吞成 ?
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $toolDir 'zju-common.psm1') -Force -DisableNameChecking

$bin = Join-Path $toolDir 'bin'
$sshPipe = Join-Path $bin 'sshpipe.exe'
$zc = Join-Path $bin 'zju-connect.exe'
$logsDir = Join-Path $toolDir 'logs'
$cfgLocal = Join-Path $env:LOCALAPPDATA 'zju-ssh\config.json'
$cfgTool = Join-Path $toolDir 'config.json'
$sshConfigPath = Join-Path $env:USERPROFILE '.ssh\config'
$mBegin = '# >>> zju-ssh >>>'
$mEnd = '# <<< zju-ssh <<<'
$idFile = '~/.ssh/id_ed25519'
$taskName = 'ZJU-SSH-Tunnel'

function Get-Cfg { Get-ToolConfig -LocalPath $cfgLocal -ToolPath $cfgTool }

# 单键更新配置（读-改-写，保留其余字段与密码密文）；失败静默——仅用于非关键元数据
function Set-CfgKey([string]$Key, [string]$Value) {
    try {
        $c = Get-ToolConfig -LocalPath $cfgLocal -ToolPath $cfgTool
        if (-not $c) { return }
        $c | Add-Member -NotePropertyName $Key -NotePropertyValue $Value -Force
        Save-ToolConfig -Cfg $c -Path $cfgLocal
    } catch { }
}

# 解析生效值：命令行参数 > 配置文件 > 内置默认
function Resolve-Targets {
    $cfg = Get-Cfg
    $host_ = if ($SshHost) { $SshHost } else { Get-CfgValue -Cfg $cfg -Key 'sshHost' }
    $port = if ($SshPort -gt 0) { $SshPort } else { [int](Get-CfgValue -Cfg $cfg -Key 'sshPort') }
    $alias = if ($HostAlias) { $HostAlias } else { Get-CfgValue -Cfg $cfg -Key 'hostAlias' }
    @{ Host = $host_; Port = $port; Alias = $alias }
}

function Get-ZcArgs([bool]$tun) {
    $cfg = Get-Cfg
    $zport = if ($ZjuPort -gt 0) { $ZjuPort } else { [int](Get-CfgValue -Cfg $cfg -Key 'zjuPort') }
    $a = @('-protocol','atrust','-server',(Get-CfgValue -Cfg $cfg -Key 'server'),'-port',"$zport",
           '-username',$cfg.vpnUser,'-password',$cfg.vpnPassword,
           '-client-data-file',(Join-Path $bin 'client_data.json'))
    if ($tun) { $a += @('-tun-mode','-add-route','-dns-hijack','-fake-ip') }
    return $a
}

# ---- init 子步骤 1：编译 sshpipe（仅 socks 模式需要）----
function Build-Sshpipe {
    $csc = @("$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
             "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $csc) { throw '未找到 .NET Framework csc.exe（Windows 10/11 应自带）' }
    $src = Join-Path $toolDir 'sshpipe.cs'
    $needBuild = (-not (Test-Path $sshPipe)) -or
                 ((Get-Item $src).LastWriteTime -gt (Get-Item $sshPipe -ErrorAction SilentlyContinue).LastWriteTime)
    if ($needBuild) {
        $outArg = '/out:"' + $sshPipe + '"'
        & $csc /nologo $outArg /target:exe $src
        if ($LASTEXITCODE -ne 0) { throw 'sshpipe 编译失败' }
    }
    Write-Ok 'sshpipe.exe 就绪'
}

# ---- init 子步骤 2：下载 zju-connect（返回版本号，失败返回 ''）----
function Install-ZjuConnect {
    if (Test-Path $zc) { Write-Ok 'zju-connect 已存在'; return (Get-Cfg).zjuVersion }
    if ($NoDownload) { Write-Ok '按需跳过下载：首次“一键连接（up）”时会自动下载，也可手动下载放入 bin\'; return (Get-Cfg).zjuVersion }
    # 解压目录里可能没有 bin\（发布 zip 不含空目录）：不先建目录，Copy-Item 会报"路径不存在"被误读成网络问题
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    # 下载链零 API 依赖：GitHub releases permalink 直链 + 国内镜像回退。
    # 原实现先查 api.github.com（未认证 60 次/小时，校园网出口是全组共享 IP，配额必然撞 403），且直链常被墙——双坑都已实测。
    # 内核通道 zjuChannel：nightly（默认）= 上游持续构建、含 aTrust 二次认证（RADIUS Access-Challenge）等修复；
    # stable = 正式 release。学校 aTrust 当前需要二次认证支持，故默认 nightly；nightly 全链失败再退 stable。
    $repo = if ($ZjuRepo) { $ZjuRepo } else { 'Mythologyli/zju-connect' }
    $channel = Get-CfgValue -Cfg (Get-Cfg) -Key 'zjuChannel'
    if ($channel -ne 'stable') { $channel = 'nightly' }
    $asset = 'zju-connect-windows-amd64.zip'
    $paths = if ($channel -eq 'nightly') { @("releases/download/nightly/$asset", "releases/latest/download/$asset") }
             else { @("releases/latest/download/$asset") }
    # 首选源的完整地址：下载全失败时给用户手动方案用（820c137 重构时丢了这行，报错里 URL 恒为空）
    $direct = "https://github.com/$repo/$($paths[0])"
    # 直链与镜像前缀必须分别拼：直链基址已含 github.com，镜像则要求"前缀 + github.com/..."，
    # 统一用 base + "github.com/$repo/..." 会把直链拼成 github.com/github.com/... 而恒 404
    $urls = @()
    foreach ($p in $paths) {
        $urls += "https://github.com/$repo/$p"
        foreach ($m in @('https://ghproxy.cn/', 'https://gh-proxy.com/')) { $urls += ($m + "github.com/$repo/$p") }
    }
    $urls = @($urls | Select-Object -Unique)
    $zip = Join-Path $env:TEMP $asset
    $ok = $false
    $lastMod = ''
    foreach ($u in $urls) {
        $src = if ($u -notmatch '^https://github\.com') { ($u -split '/')[2] + ' 镜像' }
               elseif ($u -match '/download/nightly/') { 'GitHub nightly' }
               else { 'GitHub stable' }
        Write-Host ("[init] 下载 zju-connect（{0}，通道 {1}）..." -f $src, $channel)
        try {
            Invoke-WebRequest -Uri $u -OutFile $zip -TimeoutSec 120 -UseBasicParsing
            if ((Get-Item $zip).Length -gt 1MB) { Write-Ok ("下载成功（" + $src + "）"); $ok = $true; break }
            Write-Warn2 '下载内容异常（过小），换下一个源'
        } catch {
            Write-Warn2 ("该源失败（" + $_.Exception.Message.Substring(0, [Math]::Min(80, $_.Exception.Message.Length)) + "），换下一个源")
        }
    }
    if (-not $ok) {
        Write-Warn2 ("全部下载源失败。手动方案：浏览器打开 " + $direct + "（或任一镜像前缀 + 该地址），解压出 zju-connect*.exe 放入 bin\ 后重试")
        return (Get-Cfg).zjuVersion
    }
    # 记下资产 Last-Modified：nightly 是滚动构建、版本号恒为 nightly，doctor 只能靠日期判断有无更新
    try { $lastMod = [string](Invoke-WebRequest -Uri $direct -Method Head -TimeoutSec 10 -UseBasicParsing).Headers['Last-Modified'] } catch { }
    try {
        Expand-Archive -Path $zip -DestinationPath (Join-Path $env:TEMP 'zjc-extract') -Force
        $exe = Get-ChildItem (Join-Path $env:TEMP 'zjc-extract') -Recurse -Filter 'zju-connect*.exe' | Select-Object -First 1
        if (-not $exe) { throw '压缩包中未找到 zju-connect*.exe' }
        Copy-Item $exe.FullName $zc -Force
        Remove-Item (Join-Path $env:TEMP 'zjc-extract') -Recurse -Force -ErrorAction SilentlyContinue
        Set-CfgKey -Key 'zjuChannel' -Value $channel
        if ($lastMod) { Set-CfgKey -Key 'zjuAssetDate' -Value $lastMod }
        # nightly 无版本号（滚动构建），记通道名即可；doctor 靠 zjuAssetDate 判断更新
        if ($channel -eq 'nightly') { Set-CfgKey -Key 'zjuVersion' -Value 'nightly' }
        Write-Ok 'zju-connect 已安装就绪'
        return (Get-Cfg).zjuVersion
    } catch {
        Write-Warn2 ("安装失败（" + $_.Exception.Message + "）——手动解压最新版 zip 放入 bin\ 亦可")
        return (Get-Cfg).zjuVersion
    }
}

# ---- init 子步骤 3：写/合并 ~/.ssh/config（行级状态机，对损坏标记安全）----
function Write-SshConfig([string]$Mode, [string]$SshUser, [hashtable]$t) {
    $lines = if (Test-Path $sshConfigPath) { Get-Content $sshConfigPath } else { @() }
    $keep = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($l in $lines) {
        if ($l -match ('^\s*' + [regex]::Escape($mBegin))) { $inBlock = $true; continue }
        if ($inBlock) { if ($l -match ('^\s*' + [regex]::Escape($mEnd))) { $inBlock = $false }; continue }
        $keep.Add($l)
    }
    $blockBody = "Host $($t.Alias)`n    HostName $($t.Host)`n    Port $($t.Port)`n    User $SshUser`n    IdentityFile $idFile"
    if ($Mode -eq 'socks') {
        $pipePath = ($bin -replace '\\', '/')
        $blockBody += "`n    ProxyCommand `"$pipePath/sshpipe.exe`" auto %h %p"
    }
    $blockBody += "`n    ServerAliveInterval 60`n    ServerAliveCountMax 3"
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($l in $keep) { $out.Add($l) }
    $out.Add($mBegin)
    foreach ($l in ($blockBody -split "`n")) { $out.Add($l) }
    $out.Add($mEnd)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sshConfigPath) | Out-Null
    Set-Content -Path $sshConfigPath -Value ($out -join "`r`n") -Encoding ASCII
    # 收紧 ssh 配置 ACL（仅当前用户+SYSTEM）：既满足 OpenSSH 的权限校验，
    # 也自愈历史损坏（如被其他进程写入带多余 ACE 的文件）
    icacls $sshConfigPath /inheritance:r /grant "${env:USERNAME}:F" /grant "NT AUTHORITY\SYSTEM:F" | Out-Null
    Write-Ok ("已写入 " + $sshConfigPath)
}

# GUI 子进程等无头场景没有可交互控制台，Read-Host 会永久挂起：带此包装时安全跳过（返回空走跳过分支）
function Read-HostSafe([string]$msg) {
    if ($env:ZJU_SSH_NONINTERACTIVE) { return '' }
    return (Read-Host $msg)
}
function Read-HostSafeSecure([string]$msg) {
    if ($env:ZJU_SSH_NONINTERACTIVE) { return $null }
    $sec = Read-Host $msg -AsSecureString
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Invoke-Init {
    Write-Host ("=== zju-ssh init（模式: " + $Mode + "）===")
    if ($Mode -ne 'tun' -and $Mode -ne 'socks') { throw "Mode 必须为 tun 或 socks" }
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    if ($Mode -eq 'socks') { Build-Sshpipe }

    # 下载放到最后：先把配置落盘（GitHub 不通/下载失败不应丢掉用户输入的配置）
    $old = Get-Cfg
    if (-not $SshHost) { $SshHost = Read-HostSafe '工作站地址（必填，工作站的内网 IP 或主机名）' }
    if (-not $SshHost -and $old) { $SshHost = [string]$old.sshHost }
    if (-not $SshHost) { throw '工作站地址不能为空（-SshHost 或交互输入）' }
    if (-not $SshUser) { $SshUser = Read-HostSafe 'ZJU 上的 SSH 账户名（管理员开通时告知）' }
    if (-not $SshUser -and $old) { $SshUser = [string]$old.sshUser }
    if (-not $SshUser) { throw 'SSH 账户名不能为空' }
    # 密码可经环境变量传入（GUI 使用；避免出现在子进程命令行里），读取后立即清除
    if (-not $VpnPassword -and $env:ZJU_SSH_VPNPASS) {
        $VpnPassword = $env:ZJU_SSH_VPNPASS
        Remove-Item Env:\ZJU_SSH_VPNPASS -ErrorAction SilentlyContinue
    }
    # -VpnUser 显式传空 = 明确跳过校外通道配置（无头场景）；未传时回落旧配置/交互输入
    if (-not $script:VpnUserPassed) {
        if ($old -and $old.vpnUser) { $VpnUser = [string]$old.vpnUser }
        else { $VpnUser = Read-HostSafe '本人上网账号（学号/工号；回车=暂不配置校外通道）' }
    }
    if ($VpnUser -and -not $VpnPassword) {
        if ($old -and $old.vpnPassword) { $VpnPassword = [string]$old.vpnPassword }
        else { $VpnPassword = Read-HostSafeSecure '上网密码（不回显）' }
    }
    $zjuVersion = if ($old) { [string]$old.zjuVersion } else { '' }
    Save-ToolConfig -Cfg ([PSCustomObject]@{
        server = if ($Server) { $Server } else { Get-CfgValue -Cfg $old -Key 'server' }
        port = if ($ZjuPort -gt 0) { $ZjuPort } else { [int](Get-CfgValue -Cfg $old -Key 'zjuPort') }
        vpnUser = $VpnUser; vpnPassword = $VpnPassword
        sshHost = if ($SshHost) { $SshHost } else { Get-CfgValue -Cfg $old -Key 'sshHost' }
        sshPort = if ($SshPort -gt 0) { $SshPort } else { [int](Get-CfgValue -Cfg $old -Key 'sshPort') }
        hostAlias = if ($HostAlias) { $HostAlias } else { Get-CfgValue -Cfg $old -Key 'hostAlias' }
        mode = $Mode; sshUser = $SshUser; zjuVersion = $zjuVersion
        theme = Get-CfgValue -Cfg $old -Key 'theme'
    }) -Path $cfgLocal
    Write-Ok ("配置已保存（密码以 DPAPI 加密，仅本机当前用户可解）: " + $cfgLocal)

    # 下载放在配置保存之后：失败只提示，不影响已保存的配置；首次 up 会自动补装
    $tag = Install-ZjuConnect
    if ($tag -and $tag -ne $zjuVersion) {
        $c2 = Get-ToolConfig -LocalPath $cfgLocal -ToolPath $cfgTool
        if ($c2) {
            $c2 | Add-Member -NotePropertyName zjuVersion -NotePropertyValue $tag -Force
            Save-ToolConfig -Cfg $c2 -Path $cfgLocal
        }
    }

    $t = Resolve-Targets
    Write-SshConfig -Mode $Mode -SshUser $SshUser -t $t

    Write-Host ''
    Write-Host '[init] 完成。接下来：'
    if ($Mode -eq 'tun') {
        Write-Host "  1) 可选：运行 install-task（一次 UAC）→ 开机自动建隧道；不注册也能用，一键连接时 UAC 授权即可"
        Write-Host "  2) 密钥: ssh-keygen -t ed25519 -C `"名字@zju`"（若未有），公钥发给管理员"
        Write-Host "  3) 任何网络下: ssh $($t.Alias)；自检: doctor"
    } else {
        Write-Host "  1) 密钥: ssh-keygen -t ed25519 -C `"名字@zju`"（若未有），公钥发给管理员"
        Write-Host "  2) 用 Git Bash 的 ssh 连接: ssh $($t.Alias)（Windows 自带 ssh.exe 的 ProxyCommand 有断流 bug）"
        Write-Host "  3) 自检: doctor"
    }
}

# 隧道超时时的额外指引：稳定版内核不含 ZJU 当前所需的 aTrust 二次认证修复，
# 若用户手动切过 stable，超时最可能就是这个原因——直接点名 nightly 通道（handoff §20 遗留项）
function Get-ChannelHint {
    $channel = Get-CfgValue -Cfg (Get-Cfg) -Key 'zjuChannel'
    if ($channel -eq 'stable') { return '；若日志显示认证挑战/协议相关失败，把配置 zjuChannel 改回 nightly（含 aTrust 二次认证修复）后删除 bin\zju-connect.exe 重连' }
    return ''
}

function Invoke-Up {
    $cfg = Get-Cfg
    if (-not $cfg) { throw '未初始化：先运行 init' }
    if (-not $cfg.vpnUser -or -not $cfg.vpnPassword) { throw '未配置上网账号，校外隧道不可用；校内直连不受影响' }
    if ($old = Get-ZjuProc) {
        # 短路前给出可操作信息：僵尸/卡死进程（例如停在认证质询）会一直"已在运行"，必须先停再连
        Write-Ok ("zju-connect 已在运行（PID {0}，{1} 启动）" -f $old.Id, $old.StartTime.ToString('HH:mm'))
        Write-Host '[up] 若隧道实际未通或疑似卡死：点「停止校外隧道」结束它，再重新一键连接'
        return
    }
    if (-not (Test-Path $zc)) {
        Write-Host '[up] bin\zju-connect.exe 不存在，自动下载（首次约 10-30 秒）...'
        Install-ZjuConnect | Out-Null
    }
    if (-not (Test-Path $zc)) { throw ("缺少 " + $zc + " —— 自动下载失败（多为当前网络到 GitHub 不通）：回校园网重试，或手动下载放入 bin\") }
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    if ($cfg.mode -eq 'tun') {
        # 解耦设计：连接不依赖"开机自启"注册——任务在则静默复用（无 UAC），不在则当场 UAC 拉起隧道。
        # 需要管理员是 Windows 对 TUN 虚拟网卡的要求；"注册自启"只是可选的持久化功能，不是连接前置条件。
        $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        # 任务指向的内核路径随注册时的目录而定：换了新解压目录后旧任务会拉起旧内核（或死路径），
        # 表现为"已在运行但永远不通"。路径不匹配时改走直接提权启动，并提示重注册。
        if ($t) {
            $tExe = [string]($t.Actions[0].Execute).Trim('"')
            if ($tExe -ieq $zc) {
                Write-Host '[up] 通过计划任务启动 TUN 隧道...'
                $prevEa = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
                schtasks /run /tn $taskName | Out-Null
                $runOk = ($LASTEXITCODE -eq 0)
                $ErrorActionPreference = $prevEa
                if (-not $runOk) { throw '[up] 计划任务启动失败（schtasks /run）——重跑 install-task 注册或运行 doctor 排查' }
            } else {
                Write-Warn2 ("已注册的开机自启任务指向旧路径（" + $tExe + "）——本次改为直接提权启动；如需自启，请在当前目录重跑 install-task")
                Start-ZjuTunElevated
            }
        } else {
            Start-ZjuTunElevated
        }
        Write-Host '[up] 等待隧道建立（最多 60s，下方实时转发 zju-connect 日志）...'
        if (Wait-ZjuReady { Get-ZjuProc }) { Write-Ok 'zju-connect 已运行（TUN）'; return }
        throw ('[up] 启动超时——看上方 zju-connect 日志定位（账号/密码/验证码/协议），或运行 doctor' + (Get-ChannelHint))
    }
    # SOCKS 也走最小化可交互控制台：认证挑战（短信/动态口令/图形码）的消息会实时进 GUI 日志，
    # 用户点开任务栏 "zju-tunnel" 窗口输入即可；WindowStyle Hidden 的无 stdin 子进程会在挑战时挂死
    $zcArgs = Get-ZcArgs $false
    $outLog = Join-Path $logsDir 'zju-out.log'
    $runCmd = Join-Path $env:TEMP ('zju-socks-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
    Set-Content -Path $runCmd -Value ('"' + $zc + '" ' + ($zcArgs -join ' ') + ' > "' + $outLog + '" 2>&1' + "`r`nexit /b 0") -Encoding ASCII
    Start-Process -FilePath $env:ComSpec -ArgumentList ('/c "' + $runCmd + '"') -WindowStyle Minimized
    Write-Host '[up] 等待 SOCKS5 就绪（最多 60s，下方实时转发 zju-connect 日志）...'
    if (Wait-ZjuReady { Test-SocksReady }) { Write-Ok 'SOCKS5 127.0.0.1:1080 就绪'; return }
    throw ('[up] 启动超时——看上方 zju-connect 日志定位（账号/密码/验证码/协议变更），或看 logs\zju-out.log' + (Get-ChannelHint))
}

# ---- zju-connect 运行日志（TUN=提权侧重定向；SOCKS=父进程重定向）——建立过程实时转发、事后可排障 ----
function Get-ZjuLogFile {
    $cfg = Get-Cfg
    if ($cfg -and $cfg.mode -eq 'tun') { return (Join-Path $logsDir 'zju-tun.log') }
    return (Join-Path $logsDir 'zju-out.log')
}

function Get-ZjuLogTail {
    $f = Get-ZjuLogFile
    if (-not (Test-Path $f)) { return '' }
    $l = @(Get-Content $f -Tail 1 -ErrorAction SilentlyContinue)
    if ($l) { return [string]$l[0] }
    return ''
}

# TUN 提权启动：UAC → 最小化控制台运行 zju-connect，输出重定向到运行日志（GUI 实时跟踪 + 事后排障依据）
function Start-ZjuTunElevated {
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
    $tunLog = Join-Path $logsDir 'zju-tun.log'
    $runCmd = Join-Path $env:TEMP ('zju-run-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
    Set-Content -Path $runCmd -Value ('"' + $zc + '" ' + ((Get-ZcArgs $true) -join ' ') + ' > "' + $tunLog + '" 2>&1' + "`r`nexit /b 0") -Encoding ASCII
    $elCmd = Join-Path $env:TEMP ('zju-elev-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
    Set-Content -Path $elCmd -Value ('start "zju-tunnel" /min "' + $runCmd + '"' + "`r`nexit /b 0") -Encoding ASCII
    Write-Host '[up] 请求管理员权限启动隧道（UAC 弹窗请点“是”）...'
    try { Start-Process -FilePath $elCmd -Verb RunAs -Wait }
    catch { throw '[up] 已取消管理员授权，隧道未启动（创建 TUN 虚拟网卡需要管理员权限）' }
    Start-Sleep -Milliseconds 800   # 等提权侧把日志文件建起来
}

# 等待隧道就绪：逐秒探测，每 5s 报进度，实时转发 zju-connect 最新日志行（建立过程不再鸦雀无声）
function Wait-ZjuReady([scriptblock]$ready) {
    $start = Get-Date
    $deadline = $start.AddSeconds(60)
    $script:lastTail = ''
    while ((Get-Date) -lt $deadline) {
        if (& $ready) { return $true }
        Start-Sleep -Seconds 1
        $el = [int]((Get-Date) - $start).TotalSeconds
        if ($el -ge 3 -and $el % 5 -eq 0) { Write-Host ("[up] 建立中… {0}s/60s" -f $el) }
        $tail = Get-ZjuLogTail
        if ($tail -and $tail -ne $script:lastTail) { $script:lastTail = $tail; Write-Host ('  · ' + $tail) }
    }
    return $false
}

function Invoke-Down {
    $proc = Get-ZjuProc
    if ($proc) {
        try {
            $proc | Stop-Process -Force
            Write-Ok 'zju-connect 已停止'
        } catch {
            # TUN 隧道以管理员权限运行，非提权会话停不掉：提权 taskkill（一次 UAC）
            Write-Host '[down] 隧道以管理员权限运行，请求提权停止（UAC）...'
            $log = Join-Path $env:TEMP 'zju-stop.log'
            Invoke-ElevatedScript -body 'taskkill /f /im zju-connect.exe' -logFile $log | Out-Null
            if (Get-ZjuProc) { Write-Warn2 '停止未生效——请手动结束 zju-connect.exe 后重试' }
            else { Write-Ok 'zju-connect 已停止（提权）' }
        }
    } else { Write-Host '[down] zju-connect 未在运行' }
}

function Invoke-Doctor {
    # 版本号必须经模块函数取（$script:ToolVersion 在脚本作用域不可见，直接引用恒为空）
    Write-Host ('=== zju-ssh doctor v' + (Get-ToolVersion) + ' ===')
    $cfg = Get-Cfg
    $t = Resolve-Targets
    if ($cfg) { Write-Ok ("配置: " + $(if (Test-Path $cfgLocal) { $cfgLocal } else { $cfgTool }) + "  模式: " + $cfg.mode + "  schema: v" + $cfg.schemaVersion) }
    else { Write-Err2 '未初始化——运行 init（使用内置默认值亦可，但建议 init）' }
    if ($cfg -and $cfg.vpnUser) { Write-Ok ("校外通道账号: " + $cfg.vpnUser) } else { Write-Warn2 '未配置上网账号——校外隧道不可用（校内不受影响）' }
    if ($t.Host) { Write-Ok ("工作站目标: " + $t.Host + ":" + $t.Port + "  ssh 别名: " + $t.Alias) }
    else { Write-Warn2 '未配置工作站地址（init 时用 -SshHost 填写，或在 GUI 高级区填写）' }
    if ($cfg -and $cfg.mode -eq 'socks') { Write-Host ('[' + $(if (Test-Path $sshPipe) {'✓'} else {'✗'}) + '] bin\sshpipe.exe') }
    if ($cfg -and (Test-Path $zc)) {
        $repo = Get-CfgValue -Cfg $cfg -Key 'zjuRepo'
        $channel = Get-CfgValue -Cfg $cfg -Key 'zjuChannel'
        if ($channel -ne 'stable') { $channel = 'nightly' }
        if ($channel -eq 'nightly') {
            # 版本检查也零 API 依赖：api.github.com 未认证配额按出口 IP 计（校园网全组共享必撞 403），
            # 故只用资产文件的 Last-Modified 判断更新——nightly 是滚动构建，版本号恒为 nightly，只能比日期。
            $headUrl = "https://github.com/$repo/releases/download/nightly/zju-connect-windows-amd64.zip"
            try {
                $lm = [string](Invoke-WebRequest -Uri $headUrl -Method Head -TimeoutSec 10 -UseBasicParsing).Headers['Last-Modified']
                if ($lm) {
                    $prev = [string](Get-CfgValue -Cfg $cfg -Key 'zjuAssetDate')
                    if ($prev -and $prev -ne $lm) { Write-Warn2 ("nightly 内核有更新（$prev → $lm）——重跑 init 或删除 bin\zju-connect.exe 后重连以更新") }
                    else { Write-Ok ("zju-connect nightly 内核日期 $lm") }
                } else { Write-Ok 'zju-connect nightly 通道（资产日期未知）' }
            } catch { Write-Warn2 'zju-connect 版本检查跳过（网络不可达）' }
        } else {
            if ($cfg.zjuVersion -and $cfg.zjuVersion -notmatch 'nightly') { Write-Ok ("zju-connect 稳定版 $($cfg.zjuVersion)") }
            else { Write-Ok 'zju-connect stable 通道（手动放入的 bin\ 内核，版本未知）' }
        }
    }
    Write-Host ('[' + $(if (Test-Path $zc) {'✓'} else {'✗'}) + '] bin\zju-connect.exe')
    $state = if ($t.Host) { Get-ConnectionState -SshHost $t.Host -SshPort $t.Port } else { 'unset' }
    $stateText = switch ($state) {
        'zju'   { '✓ 直连 ' + $t.Host + ':' + $t.Port + '（校内网络）' }
        'tunnel'   { '! 校外隧道运行中（SOCKS）' }
        'starting' { '! 隧道进程启动中' }
        'unset'    { '! 未配置工作站地址' }
        default    { '✗ 无直连（校外或断网）' }
    }
    Write-Host ('[' + ($stateText.Substring(0, 1)) + '] ' + $stateText.Substring(2))
    if ($cfg -and $cfg.mode -eq 'tun') {
        $taskOk = $false
        try { schtasks /query /tn $taskName 2>$null | Out-Null; $taskOk = ($LASTEXITCODE -eq 0) } catch { $taskOk = $false }
        Write-Host ('[' + $(if ($taskOk) {'✓'} else {'!'}) + '] 开机自启计划任务 ' + $(if ($taskOk) {'已注册'} else {'未注册（可选功能：注册后开机自动建隧道；不注册也能一键连接，届时 UAC 授权）'}))
    }
    $cfgText = if (Test-Path $sshConfigPath) { Get-Content $sshConfigPath -Raw } else { '' }
    Write-Host ('[' + $(if ($cfgText -and $cfgText.Contains($mBegin)) {'✓'} else {'✗'}) + '] ~/.ssh/config 含 zju 配置块')
    if ($cfg -and $cfg.mode -eq 'socks') {
        Write-Host '[i] socks 模式请使用 Git Bash 的 ssh（Windows 自带 ssh.exe 的 ProxyCommand 有断流 bug）'
    } else {
        Write-Host '[i] 当前模式适配所有客户端（Windows 自带 ssh.exe / Git Bash / VS Code）'
    }
    Write-Host ''
    Write-Host ("端到端自测:  ssh " + $t.Alias + ' "whoami && hostname"')
}

function Invoke-Connect($h, $p) {
    if (-not (Test-Path $sshPipe)) { throw 'socks 模式助手缺失：先运行 init' }
    & $sshPipe auto $h $p
    exit $LASTEXITCODE
}

function Invoke-ElevatedScript([string]$body, [string]$logFile) {
    $cmdFile = Join-Path $env:TEMP ('zju-elevate-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.cmd')
    Set-Content -Path $cmdFile -Value ($body + ' > "' + $logFile + '" 2>&1' + "`r`nexit /b 0") -Encoding ASCII
    Write-Host '[elevate] 即将弹出 UAC...'
    Start-Process -FilePath $cmdFile -Verb RunAs -Wait
    Start-Sleep -Milliseconds 500
    $out = if (Test-Path $logFile) { Get-Content $logFile -Raw } else { '' }
    return $out
}

function Invoke-InstallTask {
    $cfg = Get-Cfg
    if (-not $cfg -or -not $cfg.vpnPassword) { throw '先 init 配置上网账号' }
    $zcArgs = (Get-ZcArgs $true) -join ' '
    $tr = '\"' + $zc + '\" ' + $zcArgs
    $body = 'schtasks /create /tn ' + $taskName + ' /tr "' + $tr + '" /sc onlogon /rl highest /f'
    $log = Join-Path $env:TEMP 'zju-task-install.log'
    $out = Invoke-ElevatedScript -body $body -logFile $log
    Write-Host ('[install-task] 提权侧输出: ' + $out.Trim())
    if ($out -match '成功') { Write-Ok '开机自启任务已注册（登录后自动建立校外隧道）' }
    else { throw '注册失败，见上方提权侧输出' }
}

function Invoke-UninstallTask {
    $log = Join-Path $env:TEMP 'zju-task-uninstall.log'
    $out = Invoke-ElevatedScript -body ('schtasks /delete /tn ' + $taskName + ' /f') -logFile $log
    if ($out -match '成功') { Write-Ok '开机自启任务已移除' } else { Write-Host ('[uninstall-task] ' + $out.Trim()) }
}

switch ($Cmd.ToLowerInvariant()) {
    'init'           { Invoke-Init }
    'up'             { Invoke-Up }
    'down'           { Invoke-Down }
    'doctor'         { Invoke-Doctor }
    'connect'        { if (-not $Arg1 -or -not $Arg2) { Write-Err2 'connect 需要 <host> <port>'; exit 2 }; Invoke-Connect $Arg1 $Arg2 }
    'install-task'   { Invoke-InstallTask }
    'uninstall-task' { Invoke-UninstallTask }
    default          { Write-Host "用法: zju-ssh init|up|down|doctor|connect|install-task|uninstall-task"; exit 2 }
}
exit 0
