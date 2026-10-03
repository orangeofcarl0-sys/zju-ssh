# zju-runner.ps1 — 隧道监督进程（持有内核 stdin，把"验证码收件箱"里的码喂给内核）
# 为什么需要它：zju-connect 遇到 aTrust 二次认证（短信/动态口令/图形码）时会从 stdin 读一行口令。
#   旧实现用 `start /min cmd` 让内核独占一个最小化控制台，用户得自己找那个窗口敲码——
#   而且提权启动用 Start-Process -Wait 会等整棵进程树，只要隧道活着就永不返回（up 卡死）。
#   本进程把内核 stdin 变成受控管道：内核 stdout/stderr 仍直接落盘到日志（GUI 可实时尾随），
#   口令则由 GUI/CLI 写入收件箱文件后由本进程转发。于是"输入验证码"变成界面里一个输入框。
# 用法（由 zju-ssh.ps1 拉起，不直接手跑）：
#   powershell -File zju-runner.ps1 -RunCmd <内核命令行.cmd> -Log <日志> -Inbox <收件箱> -Mode tun|socks
param(
    [Parameter(Mandatory = $true)][string]$RunCmd,
    [Parameter(Mandatory = $true)][string]$Log,
    [Parameter(Mandatory = $true)][string]$Inbox,
    [string]$Status = '',
    [string]$Mode = 'tun'
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# runner 自己的诊断写独立文件：内核日志是 cmd 重定向写入的（GBK/ANSI），
# 若 runner 也往同一文件追加 UTF-8 文本会混编码出乱码，且两个写者互相干扰（GUI 还在尾随该文件）。
$script:RunnerLog = [System.IO.Path]::ChangeExtension($Log, '.runner.log')
function Write-RunnerLog([string]$m) {
    try {
        if ($script:RunnerLog) {
            Add-Content -LiteralPath $script:RunnerLog -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8
        }
    } catch { }
}

$logDir = Split-Path -Parent $Log
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

Write-RunnerLog ("启动（模式 {0}，PID {1}）" -f $Mode, $PID)
if ($Status) {
    try {
        $sd = Split-Path -Parent $Status
        if ($sd -and -not (Test-Path $sd)) { New-Item -ItemType Directory -Force -Path $sd | Out-Null }
        (@{ pid = $PID; mode = $Mode; started = (Get-Date).ToString('s') } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $Status -Encoding UTF8
    } catch { }
}

# exec.cmd 只做重定向：内核输出 → 日志文件。stdin 不在这里处理，由本进程以管道持有
# （cmd /c 不消费 stdin，内核继承到的就是本进程给的那个管道）。
# 必须 @echo off：否则 cmd 会把整条命令行（含 -password 明文）回显进日志文件。
$execCmd = "$RunCmd.exec.cmd"
Set-Content -LiteralPath $execCmd -Value ('@echo off' + "`r`n" + '"' + $RunCmd + '" > "' + $Log + '" 2>&1' + "`r`nexit /b 0") -Encoding ASCII

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $env:ComSpec
$psi.Arguments = '/c ""' + $execCmd + '""'
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.CreateNoWindow = $true

$p = [System.Diagnostics.Process]::Start($psi)

# 轮询收件箱：新增的非空行 → 内核 stdin。行数回退（收件箱被清空）时重置水位。
$consumed = 0
try {
    while (-not $p.HasExited) {
        if (Test-Path -LiteralPath $Inbox) {
            $lines = @(Get-Content -LiteralPath $Inbox -ErrorAction SilentlyContinue)
            if ($lines.Count -lt $consumed) { $consumed = 0 }
            while ($consumed -lt $lines.Count) {
                $code = ([string]$lines[$consumed]).Trim(); $consumed++
                if ($code -ne '') {
                    try {
                        $p.StandardInput.WriteLine($code)
                        $p.StandardInput.Flush()
                        Write-RunnerLog ("已转发口令（{0} 字符）" -f $code.Length)   # 只记长度，不落明文
                    } catch { }
                }
            }
        }
        Start-Sleep -Milliseconds 250
    }
} finally {
    $code = '?'
    try { $code = $p.ExitCode } catch { }
    Write-RunnerLog ("内核进程已退出（退出码 {0}）" -f $code)
    if ($Status) { Remove-Item -LiteralPath $Status -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $execCmd -Force -ErrorAction SilentlyContinue
    # 内核命令行文件含 -password 明文。临时文件（一键连接用）用完即删；
    # 计划任务用的持久文件（logs\kernel-cmd.txt）保留，否则下次开机自启会找不到。
    if ($RunCmd -and ($RunCmd.StartsWith($env:TEMP, [StringComparison]::OrdinalIgnoreCase))) {
        Remove-Item -LiteralPath $RunCmd -Force -ErrorAction SilentlyContinue
    }
}
