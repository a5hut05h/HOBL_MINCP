param(
    [Parameter(Mandatory = $true)]
    [string] $LogPath
)

$ErrorActionPreference = 'Stop'
$statePath = Join-Path $LogPath '.ipcm-session.json'
$cancelPath = Join-Path $LogPath '.ipcm-cancel'
$diagnosticPath = Join-Path $LogPath 'ipcm-start-diagnostic.json'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class IpcmHoblTimerWindow
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr windowHandle);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr windowHandle, int command);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr windowHandle);

    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
    private static extern uint GetWindowThreadProcessIdNative(IntPtr windowHandle, out uint processId);

    public static uint GetWindowThreadId(IntPtr windowHandle)
    {
        uint processId;
        return GetWindowThreadProcessIdNative(windowHandle, out processId);
    }

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint attachThreadId, uint attachToThreadId, bool attach);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr windowHandle);

    [DllImport("user32.dll")]
    public static extern IntPtr SetFocus(IntPtr windowHandle);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr windowHandle, out Rect rectangle);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr windowHandle, ref Point point);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extraInfo);

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)]
        public MouseInput Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputUnion Data;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, Input[] inputs, int inputSize);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr windowHandle);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    private static bool IsRemoteSession()
    {
        const int SM_REMOTESESSION = 0x1000;
        return GetSystemMetrics(SM_REMOTESESSION) != 0;
    }

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    public static void UnlockForeground()
    {
        const byte VK_MENU = 0x12;
        const uint KEYEVENTF_KEYUP = 0x0002;
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static bool ClickLogicalClientPoint(IntPtr windowHandle, int x, int y)
    {
        Point point = new Point();
        point.X = x;
        point.Y = y;
        if (!ClientToScreen(windowHandle, ref point) || !SetCursorPos(point.X, point.Y))
        {
            return false;
        }

        const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        const uint MOUSEEVENTF_LEFTUP = 0x0004;
        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(100);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
        return true;
    }
}
'@

function Get-IpcmState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }
    Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
}

function Set-IpcmState([string] $Stage, [hashtable] $Details = @{}) {
    $state = Get-IpcmState
    if (-not $state) {
        return
    }
    $state.Stage = $Stage
    foreach ($key in $Details.Keys) {
        if ($state.PSObject.Properties.Name -contains $key) {
            $state.$key = $Details[$key]
        } else {
            $state | Add-Member -NotePropertyName $key -NotePropertyValue $Details[$key]
        }
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Write-IpcmTimerDiagnostic([string] $Stage, [hashtable] $Details = @{}) {
    $timestamp = (Get-Date).ToString('o')
    $history = @()
    if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
        try {
            $previous = Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json
            if ($previous.History) {
                $history = @($previous.History)
            }
        } catch {
        }
    }

    $event = [ordered]@{ Stage = $Stage; Timestamp = $timestamp }
    foreach ($key in $Details.Keys) {
        $event[$key] = $Details[$key]
    }
    $history += [pscustomobject]$event
    [ordered]@{
        Stage = $Stage
        Timestamp = $timestamp
        LogPath = $LogPath
        History = $history
        Details = $Details
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $diagnosticPath -Encoding UTF8
}

function Wait-IpcmDelay([DateTime] $Deadline) {
    while ((Get-Date) -lt $Deadline) {
        if (Test-Path -LiteralPath $cancelPath -PathType Leaf) {
            return $false
        }
        Start-Sleep -Milliseconds 250
    }
    return $true
}

function Get-IpcmProcess($State) {
    $process = Get-Process -Id $State.ProcessId -ErrorAction SilentlyContinue
    if (-not $process -or $process.ProcessName -ne 'IpcmView') {
        return $null
    }
    $startedAt = [DateTime]::Parse($State.StartedAt)
    if ([Math]::Abs(($process.StartTime - $startedAt).TotalSeconds) -gt 10) {
        return $null
    }
    return $process
}

function Set-IpcmForeground([IntPtr] $WindowHandle) {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $currentThreadId = [IpcmHoblTimerWindow]::GetCurrentThreadId()
        $targetThreadId = [IpcmHoblTimerWindow]::GetWindowThreadId($WindowHandle)
        $foregroundWindow = [IpcmHoblTimerWindow]::GetForegroundWindow()
        $foregroundThreadId = if ($foregroundWindow -ne [IntPtr]::Zero) {
            [IpcmHoblTimerWindow]::GetWindowThreadId($foregroundWindow)
        } else {
            0
        }
        $attachedForeground = $false
        $attachedTarget = $false

        try {
            if ($foregroundThreadId -ne 0 -and $foregroundThreadId -ne $currentThreadId) {
                $attachedForeground = [IpcmHoblTimerWindow]::AttachThreadInput(
                    $currentThreadId,
                    $foregroundThreadId,
                    $true
                )
            }
            if ($targetThreadId -ne 0 -and $targetThreadId -ne $currentThreadId) {
                $attachedTarget = [IpcmHoblTimerWindow]::AttachThreadInput(
                    $currentThreadId,
                    $targetThreadId,
                    $true
                )
            }

            [IpcmHoblTimerWindow]::UnlockForeground()
            [IpcmHoblTimerWindow]::ShowWindow($WindowHandle, 9) | Out-Null
            [IpcmHoblTimerWindow]::BringWindowToTop($WindowHandle) | Out-Null
            [IpcmHoblTimerWindow]::SetForegroundWindow($WindowHandle) | Out-Null
            [IpcmHoblTimerWindow]::SetFocus($WindowHandle) | Out-Null
        }
        finally {
            if ($attachedTarget) {
                [IpcmHoblTimerWindow]::AttachThreadInput(
                    $currentThreadId,
                    $targetThreadId,
                    $false
                ) | Out-Null
            }
            if ($attachedForeground) {
                [IpcmHoblTimerWindow]::AttachThreadInput(
                    $currentThreadId,
                    $foregroundThreadId,
                    $false
                ) | Out-Null
            }
        }

        Start-Sleep -Milliseconds 300
        if ([IpcmHoblTimerWindow]::GetForegroundWindow() -eq $WindowHandle) {
            return
        }
    }
    throw 'Windows would not activate IPCM for the delayed Log action.'
}

function Get-IpcmButton([IntPtr] $WindowHandle, [string] $Name) {
    $root = [Windows.Automation.AutomationElement]::FromHandle($WindowHandle)
    $nameCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::NameProperty,
        $Name
    )
    $matches = $root.FindAll([Windows.Automation.TreeScope]::Descendants, $nameCondition)
    foreach ($match in $matches) {
        if ($match.Current.ControlType -eq [Windows.Automation.ControlType]::Button) {
            return $match
        }
    }
    return $null
}

function Invoke-IpcmButton(
    [IntPtr] $WindowHandle,
    [string] $Name,
    [int] $FallbackX,
    [int] $FallbackY
) {
    $button = Get-IpcmButton $WindowHandle $Name
    if ($button -and $button.Current.IsEnabled) {
        try {
            $pattern = $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
            ([Windows.Automation.InvokePattern] $pattern).Invoke()
            return 'ui_automation_invoke'
        } catch {
        }
        $bounds = $button.Current.BoundingRectangle
        if (-not $bounds.IsEmpty) {
            Set-IpcmForeground $WindowHandle
            if ([IpcmHoblTimerWindow]::SetCursorPos(
                [int]($bounds.Left + ($bounds.Width / 2)),
                [int]($bounds.Top + ($bounds.Height / 2))
            )) {
                [IpcmHoblTimerWindow]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
                Start-Sleep -Milliseconds 100
                [IpcmHoblTimerWindow]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
                return 'ui_automation_mouse'
            }
        }
    }
    if ([IpcmHoblTimerWindow]::ClickLogicalClientPoint($WindowHandle, $FallbackX, $FallbackY)) {
        return 'coordinate_fallback'
    }
    throw "Could not invoke $Name in IPCM."
}

function Restore-ForegroundWindow([IntPtr] $WindowHandle) {
    if ($WindowHandle -eq [IntPtr]::Zero -or -not [IpcmHoblTimerWindow]::IsWindowVisible($WindowHandle)) {
        return
    }
    [IpcmHoblTimerWindow]::UnlockForeground()
    [IpcmHoblTimerWindow]::ShowWindow($WindowHandle, 9) | Out-Null
    [IpcmHoblTimerWindow]::SetForegroundWindow($WindowHandle) | Out-Null
}

function Save-IpcmWindowCapture([IntPtr] $WindowHandle, [string] $FileName) {
    $rectangle = [IpcmHoblTimerWindow+Rect]::new()
    if (-not [IpcmHoblTimerWindow]::GetWindowRect($WindowHandle, [ref] $rectangle)) {
        return $null
    }
    $width = $rectangle.Right - $rectangle.Left
    $height = $rectangle.Bottom - $rectangle.Top
    if ($width -le 0 -or $height -le 0) {
        return $null
    }

    $capturePath = Join-Path $LogPath $FileName
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rectangle.Left, $rectangle.Top, 0, 0, [System.Drawing.Size]::new($width, $height))
        $bitmap.Save($capturePath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    return $capturePath
}

function Get-IpcmArtifact([string] $Pattern, [DateTime] $StartedAt) {
    Get-ChildItem -LiteralPath $LogPath -Filter $Pattern -File |
        Where-Object LastWriteTime -ge $StartedAt |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

try {
    $ownershipDeadline = (Get-Date).AddSeconds(5)
    do {
        Start-Sleep -Milliseconds 100
        $state = Get-IpcmState
    } until (
        ($state -and $state.WorkerProcessId -eq $PID) -or
        (Get-Date) -ge $ownershipDeadline
    )
    if (-not $state) {
        exit 0
    }
    if ($state.WorkerProcessId -ne $PID) {
        throw 'The IPCM timer worker could not confirm ownership of the session state.'
    }
    $process = Get-IpcmProcess $state
    if (-not $process) {
        throw 'The IPCM process owned by this timer worker is no longer running.'
    }

    $previewStartedAt = [DateTime]::Parse($state.PreviewStartedAt)
    Set-IpcmState 'waiting_for_log'
    Write-IpcmTimerDiagnostic 'waiting_for_log' @{ ProcessId = $process.Id }
    if (-not (Wait-IpcmDelay $previewStartedAt.AddSeconds(30))) {
        exit 0
    }

    $process.Refresh()
    if ($process.HasExited -or $process.MainWindowHandle -eq [IntPtr]::Zero) {
        throw 'IPCM closed before the delayed Log action.'
    }

    $returnWindow = [IpcmHoblTimerWindow]::GetForegroundWindow()
    Set-IpcmForeground $process.MainWindowHandle
    $beforeCapture = Save-IpcmWindowCapture $process.MainWindowHandle 'ipcm-before-log.png'
    Set-IpcmState 'log_requested' @{ LogRequestedAt = (Get-Date).ToString('o') }
    $logMethod = Invoke-IpcmButton $process.MainWindowHandle 'Log' 454 30
    Write-IpcmTimerDiagnostic 'log_action_requested' @{
        ProcessId = $process.Id
        Method = $logMethod
    }
    Start-Sleep -Seconds 1
    $afterCapture = Save-IpcmWindowCapture $process.MainWindowHandle 'ipcm-after-log.png'
    Restore-ForegroundWindow $returnWindow

    $logStartedAt = Get-Date
    $logDeadline = $logStartedAt.AddSeconds(15)
    do {
        if (Test-Path -LiteralPath $cancelPath -PathType Leaf) {
            exit 0
        }
        Start-Sleep -Milliseconds 500
        $logFile = Get-IpcmArtifact 'ipcmview-log-*.csv' $logStartedAt.AddSeconds(-2)
    } until (($logFile -and $logFile.Length -gt 0) -or $process.HasExited -or (Get-Date) -ge $logDeadline)

    if (-not $logFile -or $logFile.Length -eq 0) {
        throw "IPCM opened, but no new log appeared in $LogPath."
    }

    Set-IpcmState 'logging' @{
        LogStartedAt = $logStartedAt.ToString('o')
        DetailedLog = $logFile.FullName
    }
    Write-IpcmTimerDiagnostic 'logging_started' @{
        ProcessId = $process.Id
        Method = $logMethod
        DetailedLog = $logFile.FullName
        BeforeCapture = $beforeCapture
        AfterCapture = $afterCapture
    }

    $durationMinutes = [double]::Parse($state.Duration, [Globalization.CultureInfo]::InvariantCulture)
    if ($durationMinutes -eq 0) {
        Set-IpcmState 'logging_until_hobl_stops'
        exit 0
    }

    $autoStopDeadline = $logStartedAt.AddMinutes($durationMinutes).AddSeconds(30)
    Set-IpcmState 'waiting_for_auto_stop'
    do {
        if (Test-Path -LiteralPath $cancelPath -PathType Leaf) {
            exit 0
        }
        Start-Sleep -Milliseconds 500
        $summaryFile = Get-IpcmArtifact 'ipcmview-sum-*.csv' $logStartedAt
        $logFile = Get-IpcmArtifact 'ipcmview-log-*.csv' $logStartedAt.AddSeconds(-2)
    } until (($logFile -and $summaryFile) -or $process.HasExited -or (Get-Date) -ge $autoStopDeadline)

    if (-not $summaryFile) {
        $process.Refresh()
        if (-not $process.HasExited -and $process.MainWindowHandle -ne [IntPtr]::Zero) {
            $returnWindow = [IpcmHoblTimerWindow]::GetForegroundWindow()
            Set-IpcmForeground $process.MainWindowHandle
            $stopMethod = Invoke-IpcmButton $process.MainWindowHandle 'Stop' 410 30
            Restore-ForegroundWindow $returnWindow
            Write-IpcmTimerDiagnostic 'auto_stop_fallback_requested' @{
                ProcessId = $process.Id
                Method = $stopMethod
            }
        }

        $fallbackDeadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 500
            $summaryFile = Get-IpcmArtifact 'ipcmview-sum-*.csv' $logStartedAt
            $logFile = Get-IpcmArtifact 'ipcmview-log-*.csv' $logStartedAt.AddSeconds(-2)
        } until (($logFile -and $summaryFile) -or (Get-Date) -ge $fallbackDeadline)
    }

    if (-not $logFile -or -not $summaryFile) {
        throw "IPCM logs were not finalized in $LogPath."
    }

    $previousSizes = @($logFile.Length, $summaryFile.Length)
    Start-Sleep -Seconds 2
    $logFile = Get-Item -LiteralPath $logFile.FullName
    $summaryFile = Get-Item -LiteralPath $summaryFile.FullName
    if ($logFile.Length -ne $previousSizes[0] -or $summaryFile.Length -ne $previousSizes[1]) {
        Start-Sleep -Seconds 2
    }

    Set-IpcmState 'auto_stopped' @{
        DetailedLog = $logFile.FullName
        SummaryLog = $summaryFile.FullName
    }
    Write-IpcmTimerDiagnostic 'auto_stopped' @{
        ProcessId = $process.Id
        DetailedLog = $logFile.FullName
        SummaryLog = $summaryFile.FullName
    }

    Start-Sleep -Seconds 5
    if (-not $process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        if (-not $process.WaitForExit(5000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Write-IpcmTimerDiagnostic 'closed_after_grace' @{ ProcessId = $process.Id }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue
} catch {
    try {
        Set-IpcmState 'worker_failed' @{ WorkerError = $_.Exception.Message }
        Write-IpcmTimerDiagnostic 'worker_failed' @{ Error = $_.Exception.Message }
    } catch {
    }
    exit 1
}
