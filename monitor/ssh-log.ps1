# ssh-log.ps1 — ZJU SSH 连接日志程序（服务端）
# 数据源：sshd 写入的 OpenSSH/Operational 事件通道（无需改 sshd 配置）
# 子命令：
#   view   [-Hours 24] [-User 名字]        解析并展示连接会话表（含时长）
#   csv    <输出路径> [-Hours 168]         导出 CSV
#   active                                 当前 22 端口活动连接
#   watch                                  常驻循环：新事件近实时追加到 CSV（供计划任务调用）
#   install-watcher / uninstall-watcher    注册/移除开机自启看门狗（SYSTEM，需一次 UAC）
# 归档 CSV：C:\ProgramData\zju-ssh\connections.csv

param(
    [Parameter(Position = 0)][string]$Cmd = 'view',
    [Parameter(Position = 1)][string]$Arg1,
    [int]$Hours = 24,
    [string]$User,
    [string]$CsvPath = 'C:\ProgramData\zju-ssh\connections.csv',
    [string]$ExpectedIp = ''
)

$ErrorActionPreference = 'Continue'
$taskName = 'ZJU-SSH-LogWatcher'
$scriptPath = $MyInvocation.MyCommand.Path

# ---- 事件解析：把 sshd 消息行转成结构化记录 ----
function Get-SshEvents { param([datetime]$since, [object[]]$InputEvents)
    $raw = if ($InputEvents) { $InputEvents } else { @(Get-WinEvent -LogName 'OpenSSH/Operational' -ErrorAction SilentlyContinue) }
    $evs = @($raw | Where-Object { $_.TimeCreated -ge $since } | Sort-Object TimeCreated)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in $evs) {
        $m = $e.Message
        $t = $e.TimeCreated
        if ($m -match 'Accepted (publickey|password|keyboard-interactive) for (\S+) from (\S+) port (\d+)') {
            $out.Add([PSCustomObject]@{ Time = $t; Kind = 'Accept'; Auth = $Matches[1]; User = $Matches[2]; Ip = $Matches[3]; Port = [int]$Matches[4]; Raw = $m })
        } elseif ($m -match 'Failed (\S+) for (?:invalid user )?(\S+) from (\S+) port (\d+)') {
            $out.Add([PSCustomObject]@{ Time = $t; Kind = 'Failed'; Auth = $Matches[1]; User = $Matches[2]; Ip = $Matches[3]; Port = [int]$Matches[4]; Raw = $m })
        } elseif ($m -match 'Invalid user (\S+) from (\S+)') {
            $out.Add([PSCustomObject]@{ Time = $t; Kind = 'InvalidUser'; Auth = ''; User = $Matches[1]; Ip = $Matches[2]; Port = 0; Raw = $m })
        } elseif ($m -match 'Disconnected from (\S+) port (\d+)' -or $m -match 'Received disconnect from (\S+) port (\d+)') {
            $out.Add([PSCustomObject]@{ Time = $t; Kind = 'Disconnect'; Auth = ''; User = ''; Ip = $Matches[1]; Port = [int]$Matches[2]; Raw = $m })
        } elseif ($m -match 'Connection closed by (?:authenticating user )?(\S+) from (\S+) port (\d+)') {
            $out.Add([PSCustomObject]@{ Time = $t; Kind = 'PreAuthClose'; Auth = ''; User = $Matches[1]; Ip = $Matches[2]; Port = [int]$Matches[3]; Raw = $m })
        }
    }
    return $out
}

# ---- 会话配对：Accept 入栈，Disconnect 按 port 出栈，算时长 ----
function Get-Sessions($events) {
    $open = @{}
    $sessions = New-Object System.Collections.Generic.List[object]
    foreach ($e in $events) {
        if ($e.Kind -eq 'Accept') { $open[$e.Port] = @{ Start = $e.Time; User = $e.User; Ip = $e.Ip; Auth = $e.Auth } }
        elseif ($e.Kind -eq 'Disconnect' -and $open.ContainsKey($e.Port)) {
            $s = $open[$e.Port]; $open.Remove($e.Port)
            $sessions.Add([PSCustomObject]@{
                Start = $s.Start; End = $e.Time
                Duration = ($e.Time - $s.Start).TotalSeconds
                User = $s.User; Ip = $s.Ip; Auth = $s.Auth
            })
        }
    }
    foreach ($p in $open.Keys) {
        $s = $open[$p]
        $sessions.Add([PSCustomObject]@{
            Start = $s.Start; End = $null; Duration = $null
            User = $s.User; Ip = $s.Ip; Auth = $s.Auth
        })
    }
    return ($sessions | Sort-Object Start)
}

function Show-Table($sessions) {
    if (-not $sessions -or $sessions.Count -eq 0) { Write-Host '（区间内无成功登录会话）'; return }
    $rows = foreach ($s in $sessions) {
        $dur = if ($null -ne $s.Duration) {
            if ($s.Duration -ge 1) { [string][int]$s.Duration + 's' } else { '<1s' }
        } else { '进行中' }
        [PSCustomObject]@{
            开始   = $s.Start.ToString('MM-dd HH:mm:ss')
            时长   = $dur
            用户   = $s.User
            来源   = $s.Ip
            认证   = $s.Auth
        }
    }
    $rows | Format-Table -AutoSize | Out-Host
}

function Append-Csv($events) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CsvPath) | Out-Null
    if (-not (Test-Path $CsvPath)) {
        'Time,Kind,User,Auth,Ip,Port,Detail' | Set-Content -Path $CsvPath -Encoding UTF8
    }
    foreach ($e in $events) {
        $detail = ($e.Raw -replace '"', "'")
        Add-Content -Path $CsvPath -Value ('"{0}","{1}","{2}","{3}","{4}","{5}","{6}"' -f `
            $e.Time.ToString('yyyy-MM-dd HH:mm:ss'), $e.Kind, $e.User, $e.Auth, $e.Ip, $e.Port, $detail) -Encoding UTF8
    }
}

function Invoke-View {
    $since = (Get-Date).AddHours(-1 * $Hours)
    $events = Get-SshEvents $since
    if ($User) { $events = $events | Where-Object { $_.User -eq $User } }
    $sessions = Get-Sessions $events
    Write-Host ("=== 最近 {0} 小时的 SSH 会话（账户: {1}）===" -f $Hours, $(if ($User) { $User } else { '全部' }))
    Show-Table $sessions
    $fails = @($events | Where-Object { $_.Kind -eq 'Failed' -or $_.Kind -eq 'InvalidUser' -or $_.Kind -eq 'PreAuthClose' })
    Write-Host ("失败/未认证尝试: {0} 次；会话: {1} 个" -f $fails.Count, @($sessions).Count)
}

function Invoke-Csv {
    $since = (Get-Date).AddHours(-1 * $Hours)
    $events = Get-SshEvents $since
    if ($User) { $events = $events | Where-Object { $_.User -eq $User } }
    Append-Csv $events
    Write-Host ('已导出 ' + @($events).Count + ' 条事件到 ' + $CsvPath)
}

function Invoke-Active {
    Write-Host '=== 当前 22 端口活动连接 ==='
    $conns = Get-NetTCPConnection -LocalPort 22 -State Established -ErrorAction SilentlyContinue
    if (-not $conns) { Write-Host '（无）'; return }
    $conns | ForEach-Object {
        [PSCustomObject]@{
            本地 = $_.LocalAddress + ':' + $_.LocalPort
            远端 = $_.RemoteAddress + ':' + $_.RemotePort
            建立时间 = $_.CreationTime.ToString('MM-dd HH:mm:ss')
        }
    } | Format-Table -AutoSize | Out-Host
}

function Invoke-Watch {
    # 常驻：每 10 秒拉取增量事件写入 CSV（供 ZJU-SSH-LogWatcher 计划任务调用）
    # 同时巡检工作站 IP：期望 IP（-ExpectedIp）不在任何网卡上时记录漂移（IP 固定守护）
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $CsvPath) | Out-Null
    New-Item -ItemType Directory -Force -Path 'C:\ProgramData\zju-ssh' | Out-Null
    $last = (Get-Date).AddMinutes(-1)
    $script:ipDriftLogged = $false
    Write-Host ("[watch] 启动，归档: " + $CsvPath + "，期望 IP: " + $ExpectedIp)
    while ($true) {
        try {
            $raw = @(Get-WinEvent -FilterHashtable @{LogName='OpenSSH/Operational'; StartTime=$last} -ErrorAction Stop)
            $parsed = @(Get-SshEvents -since $last -InputEvents $raw)
            if ($parsed.Count -gt 0) {
                Append-Csv $parsed
                $newLast = ($parsed | Sort-Object TimeCreated | Select-Object -Last 1).Time
                if ($null -ne $newLast) { $last = $newLast }
            }
        } catch {
            Write-Host ('[watch] ' + $_.Exception.Message)
        }
        try {
            $curIp = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $ExpectedIp })
            if (-not $curIp -and -not $script:ipDriftLogged) {
                $script:ipDriftLogged = $true
                Add-Content -Path 'C:\ProgramData\zju-ssh\ip-changes.log' -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " 工作站 IP 漂移：网卡上未找到期望的 $ExpectedIp（可能被改回 DHCP 或网络重编址）")
                Write-Host '[watch] 警告：工作站 IP 漂移！'
            } elseif ($curIp) {
                $script:ipDriftLogged = $false
            }
        } catch { }
        Start-Sleep -Seconds 10
    }
}

function Invoke-IpStatus {
    Write-Host ('期望的工作站 IP: ' + $ExpectedIp)
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notmatch '^169' } |
        Select-Object InterfaceAlias, IPAddress, PrefixOrigin | Format-Table -AutoSize | Out-Host
}
function Invoke-InstallWatcher {
    # 用 8.3 短路径消除 /tr 值里的引号嵌套；把 schtasks 行写进临时 .cmd 再自提权运行
    $fso = New-Object -ComObject Scripting.FileSystemObject
    $sp = $fso.GetFolder((Split-Path -Parent $scriptPath)).ShortPath
    if ($sp -match '\s') { throw "脚本路径含空格且无 8.3 短路径，请把本工具挪到无空格目录" }
    if (-not $ExpectedIp) { throw '未提供工作站 IP：请用 -ExpectedIp <IP> 指定（IP 巡检依赖它）' }
    $line = 'schtasks /create /tn ' + $taskName + ' /tr "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' + $sp + '\ssh-log.ps1 watch -ExpectedIp ' + $ExpectedIp + '" /ru SYSTEM /rl HIGHEST /sc onstart /f'
    $cmdFile = Join-Path $env:TEMP 'zju-watch-install.cmd'
    $logFile = Join-Path $env:TEMP 'zju-watch-install.log'
    $body = $line + ' > "' + $logFile + '" 2>&1' + "`r`nexit /b 0"
    Set-Content -Path $cmdFile -Value $body -Encoding ASCII
    Write-Host '[install-watcher] 即将弹出 UAC 注册 SYSTEM 看门狗任务...'
    Start-Process -FilePath $cmdFile -Verb RunAs -Wait
    Start-Sleep -Milliseconds 500
    $created = $false
    if (Test-Path $logFile) {
        $errText = Get-Content $logFile -Raw
        if ($errText -and $errText.Trim()) { Write-Host ('[install-watcher] 提权侧输出: ' + $errText.Trim()) }
        $created = ($errText -match '成功')
    }
    if ($created) { Write-Host ('[install-watcher] 已注册。重启后自动运行；立即启动可运行 install-watcher 的提权 /run（见下方），归档: ' + $CsvPath) }
    else { Write-Host '[install-watcher] 注册失败，手动以管理员运行:'; Write-Host $line }
    # 立即启动（SYSTEM 任务需提权 /run）
    $runCmd = Join-Path $env:TEMP 'zju-watch-run.cmd'
    Set-Content -Path $runCmd -Value ('schtasks /run /tn ' + $taskName + ' > "' + $logFile + '" 2>&1' + "`r`nexit /b 0") -Encoding ASCII
    Start-Process -FilePath $runCmd -Verb RunAs -Wait
    Start-Sleep -Seconds 4
    if (Test-Path $logFile) {
        $runText = Get-Content $logFile -Raw
        if ($runText -match '成功') { Write-Host '[install-watcher] 看门狗已启动' }
    }
}

function Invoke-UninstallWatcher {
    Start-Process powershell -Verb RunAs -Wait -ArgumentList ('-NoProfile -Command "schtasks /delete /tn ' + $taskName + ' /f"')
    Write-Host '[uninstall-watcher] 已执行'
}

switch ($Cmd.ToLowerInvariant()) {
    'view'             { Invoke-View }
    'csv'              { Invoke-Csv }
    'active'           { Invoke-Active }
    'watch'            { Invoke-Watch }
    'install-watcher'  { Invoke-InstallWatcher }
    'uninstall-watcher'{ Invoke-UninstallWatcher }
    'ip-status'        { Invoke-IpStatus }
    default            { Write-Host "用法: ssh-log.ps1 view|csv <路径>|active|watch|install-watcher|uninstall-watcher [-Hours n] [-User 名字]"; exit 2 }
}
