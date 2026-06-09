param(
    [string]$Title = "Claude Code",                 # 通知标题
    [string]$Message = "",                          # 通知正文
    [string]$BarkToken = "",                        # Bark 推送 Token（不传则跳过手机推送）
    [ValidateRange(0, 86400)]
    [int]$IdleTimeout = 60,                         # 闲置超时（秒），超过后判定人已离开
    [ValidateRange(1, 300)]
    [int]$IdleCheckInterval = 2,                    # 闲置检测间隔（秒），每隔 N 秒查一次鼠标/键盘
    [ValidateRange(0, 300)]
    [int]$BarkGracePeriod = 10                      # 挽留等待（秒），弹完 Toast 后再等 N 秒，0=不等直接推
)

# ==== 日志开关 ====
$EnableLogging = $true                         # $true=写日志, $false=关闭
$ScriptDir = Split-Path -Parent $PSCommandPath
$LogFile = Join-Path $ScriptDir "notify.log"
$LogPid = $pid                                  # 当前进程 PID，方便跨进程追踪

function Write-Log {
    param([string]$Stage, [string]$Message)
    if (-not $EnableLogging) { return }
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    "$ts [$LogPid] [$Stage] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

Write-Log "INIT" "==== 脚本启动 ===="
Write-Log "INIT" "参数: Title=[$Title] Message=[$Message] BarkToken=[$($BarkToken -replace '.','*')] IdleTimeout=$IdleTimeout IdleCheckInterval=$IdleCheckInterval BarkGracePeriod=$BarkGracePeriod"
Write-Log "INIT" "PSEdition=$($PSVersionTable.PSEdition) PSVersion=$($PSVersionTable.PSVersion) PID=$pid"

# WinRT 类型只在 Windows PowerShell 5.1 (Desktop) 中可用，
# pwsh (Core) 不支持。如果当前是 Core，重新用 powershell.exe 启动。
if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Log "RELAUNCH" "当前为 pwsh Core，重启动到 powershell.exe (Desktop) 以启用 WinRT Toast"
    $myPath = $PSCommandPath
    # 转义参数中的双引号，防止命令行解析错误
    # Windows 命令行中，引号内的 " 需写成 ""
    $escapedTitle = $Title -replace '"', '""'
    $escapedMessage = $Message -replace '"', '""'
    $escapedBarkToken = $BarkToken -replace '"', '""'
    $psArgs = "-NoProfile -WindowStyle Hidden -File `"$myPath`" -Title `"$escapedTitle`" -Message `"$escapedMessage`" -BarkToken `"$escapedBarkToken`" -IdleTimeout $IdleTimeout -IdleCheckInterval $IdleCheckInterval -BarkGracePeriod $BarkGracePeriod"
    Write-Log "RELAUNCH" "Start-Process powershell.exe -ArgumentList $psArgs"
    Start-Process powershell.exe -ArgumentList $psArgs -WindowStyle Hidden
    Write-Log "RELAUNCH" "Core 进程退出 (exit 0)"
    exit 0
}

try {
    Write-Log "ADDTYPE" "正在加载 Win32 P/Invoke 类型..."
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
}
'@
    Write-Log "ADDTYPE" "Win32 类型加载成功"
} catch {
    Write-Log "ADDTYPE" "ERROR: Win32 类型加载失败: $_"
    Write-Log "ADDTYPE" "Win32 类型不可用，脚本无法继续，退出"
    exit 1
}

# --- 阶段 1：焦点检测，终端在前台则跳过 Toast，但不影响 Bark 空闲检测 ---
Write-Log "PHASE1" "==== 阶段 1: 焦点检测 ===="
Write-Log "PHASE1" "开始焦点检测..."
$skipToast = $false
$fg = [Win32]::GetForegroundWindow()
Write-Log "PHASE1" "GetForegroundWindow() = $fg"
if ($fg -ne [IntPtr]::Zero) {
    $fgPid = 0
    [Win32]::GetWindowThreadProcessId($fg, [ref]$fgPid) | Out-Null
    Write-Log "PHASE1" "前台窗口 PID = $fgPid"

    if ($fgPid -gt 0) {
        $console = [Win32]::GetConsoleWindow()
        Write-Log "PHASE1" "GetConsoleWindow() = $console, 当前进程 PID = $pid"
        if ($console -ne [IntPtr]::Zero -and $fg -eq $console) {
            $skipToast = $true
            Write-Log "PHASE1" "前台窗口 == Console 窗口 → skipToast=true (终端在前台)"
        }

        if (-not $skipToast) {
            Write-Log "PHASE1" "前台窗口不是 Console，沿进程树上溯查找 (最多 8 层)..."
            $visited = @{}
            $currentId = $pid
            for ($i = 0; $i -lt 8; $i++) {
                if ($visited.ContainsKey($currentId)) { break }
                $visited[$currentId] = $true
                $matchLabel = if ($currentId -eq $fgPid) { 'MATCH' } else { 'no' }
                Write-Log "PHASE1" "  第 $($i+1) 层: PID=$currentId, 比对 fgPid=$fgPid → $matchLabel"
                if ($currentId -eq $fgPid) { $skipToast = $true; break }
                try {
                    $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$currentId" -Property ParentProcessId -ErrorAction Stop).ParentProcessId
                } catch {
                    Write-Log "PHASE1" "  获取父进程失败: $_"
                    break
                }
                if ($parentId -le 0 -or $parentId -eq $currentId) {
                    Write-Log "PHASE1" "  父进程无效 ($parentId)，停止上溯"
                    break
                }
                $currentId = $parentId
            }
            Write-Log "PHASE1" "进程树上溯结果: skipToast=$skipToast"
        }
    }
} else {
    Write-Log "PHASE1" "GetForegroundWindow 返回 Zero (无法获取前台窗口)"
}
Write-Log "PHASE1" "焦点检测完成: skipToast=$skipToast"

# --- Toast 发送函数 ---
# 把注册表登记 / 图标生成 / XML 拼装 / 弹出都封装在一起，
# 阶段 2 和阶段 3 都可以复用。
function Send-Toast {
    param([string]$ToastTitle, [string]$ToastMessage)

    Write-Log "TOAST" "Send-Toast 被调用: Title=[$ToastTitle] Message=[$ToastMessage]"
    try {
        $appId = "Claude.Code.Notify"
        $scriptDir = Split-Path -Parent $PSCommandPath
        $iconFile = "$scriptDir\notify-icon.png"

        # 一次性：在注册表中登记 AppUserModelID（WinRT 要求）
        $regPath = "HKCU:\SOFTWARE\Classes\AppUserModelID\$appId"
        if (-not (Test-Path $regPath)) {
            Write-Log "TOAST" "注册表项不存在，正在创建: $regPath"
            New-Item -Path $regPath -Force | Out-Null
            New-ItemProperty -Path $regPath -Name "DisplayName" -Value "Claude Code" -PropertyType String -Force | Out-Null
            Write-Log "TOAST" "注册表项创建完成"
        } else {
            Write-Log "TOAST" "注册表项已存在，跳过创建"
        }

        # 一次性：生成绿色圆点图标（改颜色改 FromArgb 的三个数字即可）
        if (-not (Test-Path $iconFile)) {
            Write-Log "TOAST" "图标文件不存在，正在生成: $iconFile"
            Add-Type -AssemblyName System.Drawing
            $bmp = New-Object System.Drawing.Bitmap(64, 64)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode = "HighQuality"
            $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(82, 196, 26))
            $g.FillEllipse($brush, 6, 6, 52, 52)
            $brush.Dispose()
            $g.Dispose()
            $bmp.Save($iconFile, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            Write-Log "TOAST" "图标生成完成"
        } else {
            Write-Log "TOAST" "图标文件已存在，跳过生成"
        }

        # 告诉 Windows 当前进程的 AppUserModelID
        [Win32]::SetCurrentProcessExplicitAppUserModelID($appId) | Out-Null
        Write-Log "TOAST" "SetCurrentProcessExplicitAppUserModelID($appId) 完成"

        # WinRT Toast 通知
        $escapeXml = { param($s) $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' }
        $safeTitle = & $escapeXml $ToastTitle
        $safeMsg = & $escapeXml $ToastMessage
        $iconUri = "file:///" + ($iconFile -replace '\\', '/')

        $template = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text id="1">$safeTitle</text>
            <text id="2">$safeMsg</text>
            <image placement="appLogoOverride" src="$iconUri" />
        </binding>
    </visual>
</toast>
"@

        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        Write-Log "TOAST" "XML 加载成功，正在 Show()..."
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        Write-Log "TOAST" "Toast 通知已弹出"
    } catch {
        Write-Log "TOAST" "ERROR: Toast 发送失败: $_"
    }
}

# --- 阶段 2：即时 Toast（终端在前台则跳过）---
Write-Log "PHASE2" "==== 阶段 2: 即时 Toast ===="
if (-not $skipToast) {
    Write-Log "PHASE2" "skipToast=false → 发送即时 Toast"
    Send-Toast $Title $Message
} else {
    Write-Log "PHASE2" "skipToast=true → 跳过即时 Toast (终端在前台)"
}

# --- 空闲等待辅助函数 ---
# 每隔 $IdleCheckInterval 秒检查一次，持续 $WaitSeconds 秒。
# 通过比较"当前空闲时长"与基准值来判断用户是否回来了：
# 如果空闲时长突然缩短，说明有新鼠标/键盘操作。
# 这种比较方式天然免疫 GetTickCount 每 49.7 天溢出回卷的问题。
function Wait-IdleUntilInput {
    param([int]$WaitSeconds, $BaseIdleMs)

    $rounds = [Math]::Ceiling($WaitSeconds / $IdleCheckInterval)
    Write-Log "IDLEWAIT" "开始空闲等待: WaitSeconds=$WaitSeconds, CheckInterval=$IdleCheckInterval, 总轮次=$rounds, BaseIdleMs=$BaseIdleMs"
    for ($i = 0; $i -lt $rounds; $i++) {
        Start-Sleep -Seconds $IdleCheckInterval
        $liiNow = New-Object Win32+LASTINPUTINFO
        $liiNow.cbSize = 8
        if ([Win32]::GetLastInputInfo([ref]$liiNow)) {
            $currentIdleMs = [Win32]::GetTickCount() - $liiNow.dwTime
            $statusLabel = if ($currentIdleMs -lt $BaseIdleMs) { '用户回归, 退出' } else { '继续等待' }
            Write-Log "IDLEWAIT" "  轮次 $($i+1)/${rounds}: currentIdleMs=${currentIdleMs}, BaseIdleMs=${BaseIdleMs} -> ${statusLabel}"
            if ($currentIdleMs -lt $BaseIdleMs) {
                Write-Log "IDLEWAIT" "检测到用户输入，脚本正常退出"
                exit 0
            }
        } else {
            Write-Log "IDLEWAIT" "  轮次 $($i+1)/${rounds}: GetLastInputInfo 失败"
        }
    }
    Write-Log "IDLEWAIT" "空闲等待超时 ($WaitSeconds 秒)，继续下一步"
}

# --- 阶段 3：空闲检测，超时后先 Toast 挽留，再无人操作才推 Bark ---
# 整段以 BarkToken 是否传入为前提；没传则跳过
Write-Log "PHASE3" "==== 阶段 3: 空闲检测 + Bark 推送 ===="
if ($BarkToken) {
    Write-Log "PHASE3" "BarkToken 已提供，开始空闲检测"

    # 记录当前空闲时长作为后续检测的基准值
    $lii = New-Object Win32+LASTINPUTINFO
    $lii.cbSize = 8
    if ([Win32]::GetLastInputInfo([ref]$lii)) {
        Write-Log "PHASE3" "GetLastInputInfo 成功: dwTime=$($lii.dwTime)"
    } else {
        Write-Log "PHASE3" "WARN: GetLastInputInfo 失败"
    }
    $baseIdleMs = [Win32]::GetTickCount() - $lii.dwTime
    Write-Log "PHASE3" "GetTickCount()=$([Win32]::GetTickCount()), baseIdleMs=$baseIdleMs, timeoutMs=$($IdleTimeout * 1000)"

    # 如果还不够超时阈值，等待剩余时间
    $timeoutMs = $IdleTimeout * 1000
    if ($baseIdleMs -lt $timeoutMs) {
        $remainSeconds = [int](($timeoutMs - $baseIdleMs) / 1000)
        Write-Log "PHASE3" "空闲时长 ($baseIdleMs ms) < 超时阈值 ($timeoutMs ms), 需等待 ${remainSeconds}s 后进入超时"
        Wait-IdleUntilInput $remainSeconds $baseIdleMs
    } else {
        Write-Log "PHASE3" "空闲时长 ($baseIdleMs ms) >= 超时阈值 ($timeoutMs ms), 已超时，直接进入挽留/Bark阶段"
    }

    # --- 如果阶段 2 已经弹过 Toast（终端不在前台），直接推 Bark；否则先 Toast 挽留 ---
    if ($skipToast) {
        Write-Log "PHASE3" "skipToast=true → 终端之前在前台，发送挽留 Toast"
        # 终端在前台 → 之前没弹过 Toast，现在弹一个挽留
        Send-Toast $Title $Message
        if ($BarkGracePeriod -gt 0) {
            Write-Log "PHASE3" "BarkGracePeriod=$BarkGracePeriod > 0, 进入挽留等待"
            Wait-IdleUntilInput $BarkGracePeriod $baseIdleMs
        } else {
            Write-Log "PHASE3" "BarkGracePeriod=0, 跳过挽留等待"
        }
    } else {
        Write-Log "PHASE3" "skipToast=false → 终端之前不在前台 (已弹过 Toast)，直接推 Bark"
    }

    # 拼装 Bark 推送 URL 并发起 HTTP GET 请求

    $encodedTitle = [uri]::EscapeDataString($Title)
    $encodedMsg   = [uri]::EscapeDataString($Message)

    $barkUrl = "https://api.day.app/${BarkToken}/${encodedTitle}/${encodedMsg}?icon=https://github.com/ShawayL/dotfiles/blob/main/.claude/notify-icon.png?raw=true&group=claude"
    Write-Log "BARK" "请求 Bark API: $barkUrl"

    $request = [System.Net.HttpWebRequest]::Create($barkUrl)
    $request.Method = "GET"
    $request.Timeout = 10000
    try {
        $response = $request.GetResponse()
        Write-Log "BARK" "Bark 推送成功: HTTP $($response.StatusCode)"
        $response.Dispose()
    } catch {
        Write-Log "BARK" "ERROR: Bark 推送失败: $_"
    }
} else {
    Write-Log "PHASE3" "BarkToken 为空，跳过阶段 3"
}
Write-Log "PHASE3" "==== 脚本结束 ===="
