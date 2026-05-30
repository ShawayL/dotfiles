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

# WinRT 类型只在 Windows PowerShell 5.1 (Desktop) 中可用，
# pwsh (Core) 不支持。如果当前是 Core，重新用 powershell.exe 启动。
if ($PSVersionTable.PSEdition -eq 'Core') {
    $myPath = $PSCommandPath
    $psArgs = "-NoProfile -WindowStyle Hidden -File `"$myPath`" -Title `"$Title`" -Message `"$Message`" -BarkToken `"$BarkToken`" -IdleTimeout $IdleTimeout -IdleCheckInterval $IdleCheckInterval -BarkGracePeriod $BarkGracePeriod"
    Start-Process powershell.exe -ArgumentList $psArgs -WindowStyle Hidden
    exit 0
}

try {
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
} catch {}

# --- 焦点检测：终端在前台则跳过 Toast，但不影响 Bark 空闲检测 ---
$skipToast = $false
$fg = [Win32]::GetForegroundWindow()
if ($fg -ne [IntPtr]::Zero) {
    $fgPid = 0
    [Win32]::GetWindowThreadProcessId($fg, [ref]$fgPid) | Out-Null

    if ($fgPid -gt 0) {
        $console = [Win32]::GetConsoleWindow()
        if ($console -ne [IntPtr]::Zero -and $fg -eq $console) { $skipToast = $true }

        if (-not $skipToast) {
            $visited = @{}
            $currentId = $pid
            for ($i = 0; $i -lt 8; $i++) {
                if ($visited.ContainsKey($currentId)) { break }
                $visited[$currentId] = $true
                if ($currentId -eq $fgPid) { $skipToast = $true; break }
                try {
                    $parentId = (Get-CimInstance Win32_Process -Filter "ProcessId=$currentId" -Property ParentProcessId -ErrorAction Stop).ParentProcessId
                } catch { break }
                if ($parentId -le 0 -or $parentId -eq $currentId) { break }
                $currentId = $parentId
            }
        }
    }
}

# --- Toast 发送函数 ---
# 把注册表登记 / 图标生成 / XML 拼装 / 弹出都封装在一起，
# 阶段 2 和阶段 3 都可以复用。
function Send-Toast {
    param([string]$ToastTitle, [string]$ToastMessage)

    try {
        $appId = "Claude.Code.Notify"
        $scriptDir = Split-Path -Parent $PSCommandPath
        $iconFile = "$scriptDir\notify-icon.png"

        # 一次性：在注册表中登记 AppUserModelID（WinRT 要求）
        $regPath = "HKCU:\SOFTWARE\Classes\AppUserModelID\$appId"
        if (-not (Test-Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
            New-ItemProperty -Path $regPath -Name "DisplayName" -Value "Claude Code" -PropertyType String -Force | Out-Null
        }

        # 一次性：生成绿色圆点图标（改颜色改 FromArgb 的三个数字即可）
        if (-not (Test-Path $iconFile)) {
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
        }

        # 告诉 Windows 当前进程的 AppUserModelID
        [Win32]::SetCurrentProcessExplicitAppUserModelID($appId) | Out-Null

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
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {}
}

# --- 阶段 2：即时 Toast（终端在前台则跳过）---
if (-not $skipToast) {
    Send-Toast $Title $Message
}

# --- 空闲等待辅助函数 ---
# 每隔 $IdleCheckInterval 秒检查一次，持续 $WaitSeconds 秒。
# 通过比较"当前空闲时长"与基准值来判断用户是否回来了：
# 如果空闲时长突然缩短，说明有新鼠标/键盘操作。
# 这种比较方式天然免疫 GetTickCount 每 49.7 天溢出回卷的问题。
function Wait-IdleUntilInput {
    param([int]$WaitSeconds, $BaseIdleMs)

    $rounds = [Math]::Ceiling($WaitSeconds / $IdleCheckInterval)
    for ($i = 0; $i -lt $rounds; $i++) {
        Start-Sleep -Seconds $IdleCheckInterval
        $liiNow = New-Object Win32+LASTINPUTINFO
        $liiNow.cbSize = 8
        if ([Win32]::GetLastInputInfo([ref]$liiNow)) {
            $currentIdleMs = [Win32]::GetTickCount() - $liiNow.dwTime
            if ($currentIdleMs -lt $BaseIdleMs) {
                exit 0
            }
        }
    }
}

# --- 阶段 3：空闲检测，超时后先 Toast 挽留，再无人操作才推 Bark ---
# 整段以 BarkToken 是否传入为前提；没传则跳过
if ($BarkToken) {

    # 记录当前空闲时长作为后续检测的基准值
    $lii = New-Object Win32+LASTINPUTINFO
    $lii.cbSize = 8
    [Win32]::GetLastInputInfo([ref]$lii) | Out-Null
    $baseIdleMs = [Win32]::GetTickCount() - $lii.dwTime

    # 如果还不够超时阈值，等待剩余时间
    $timeoutMs = $IdleTimeout * 1000
    if ($baseIdleMs -lt $timeoutMs) {
        $remainSeconds = [int](($timeoutMs - $baseIdleMs) / 1000)
        Wait-IdleUntilInput $remainSeconds $baseIdleMs
    }

    # --- 如果阶段 2 已经弹过 Toast（终端不在前台），直接推 Bark；否则先 Toast 挽留 ---
    if ($skipToast) {
        # 终端在前台 → 之前没弹过 Toast，现在弹一个挽留
        Send-Toast $Title $Message
        if ($BarkGracePeriod -gt 0) {
            Wait-IdleUntilInput $BarkGracePeriod $baseIdleMs
        }
    }

    # 拼装 Bark 推送 URL 并发起 HTTP GET 请求

    $encodedTitle = [uri]::EscapeDataString($Title)
    $encodedMsg   = [uri]::EscapeDataString($Message)

    $barkUrl = "https://api.day.app/${BarkToken}/${encodedTitle}/${encodedMsg}?icon=https://claude.ai/favicon.ico&group=claude"

    $request = [System.Net.HttpWebRequest]::Create($barkUrl)
    $request.Method = "GET"
    $request.Timeout = 10000
    try { $request.GetResponse().Dispose() } catch {}
}
