param(
    [Parameter(Mandatory = $true)]
    [string] $LogPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet('0', '0.5', '1', '2', '3', '5', '10', '15', '20', '30')]
    [string] $Duration,

    [Parameter(Mandatory = $true)]
    [ValidateSet('20', '50', '100', '200', '500', '1000')]
    [string] $SamplePeriod,

    [ValidateSet('false', 'true')]
    [string] $TransferToConsole = 'false'
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
if (-not ('IpcmHoblStartWindowV3' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class IpcmHoblStartWindowV3
{
    private delegate bool EnumWindowsCallback(IntPtr windowHandle, IntPtr parameter);

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

    [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
    private static extern uint GetWindowThreadProcessIdNative(IntPtr windowHandle, out uint processId);

    public static uint GetWindowThreadId(IntPtr windowHandle)
    {
        uint processId;
        return GetWindowThreadProcessIdNative(windowHandle, out processId);
    }

    public static uint GetWindowProcessId(IntPtr windowHandle)
    {
        uint processId;
        GetWindowThreadProcessIdNative(windowHandle, out processId);
        return processId;
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
    public static extern bool GetClientRect(IntPtr windowHandle, out Rect rectangle);

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
    public static extern bool IsWindowVisible(IntPtr windowHandle);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr windowHandle);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    public static bool IsRemoteSession()
    {
        const int SM_REMOTESESSION = 0x1000;
        return GetSystemMetrics(SM_REMOTESESSION) != 0;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr windowHandle, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    public static void UnlockForeground()
    {
        const byte VK_MENU = 0x12;
        const uint KEYEVENTF_KEYUP = 0x0002;
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static bool ClickClientRatio(IntPtr windowHandle, double xRatio, double yRatio)
    {
        const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        const uint MOUSEEVENTF_LEFTUP = 0x0004;
        Rect rectangle;
        if (!GetClientRect(windowHandle, out rectangle))
        {
            return false;
        }

        Point point = new Point();
        point.X = (int)((rectangle.Right - rectangle.Left) * xRatio);
        point.Y = (int)((rectangle.Bottom - rectangle.Top) * yRatio);
        if (!ClientToScreen(windowHandle, ref point) || !SetCursorPos(point.X, point.Y))
        {
            return false;
        }

        mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
        return true;
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

    public static Point GetLogicalClientScreenPoint(IntPtr windowHandle, int x, int y)
    {
        Point point = new Point();
        point.X = x;
        point.Y = y;
        ClientToScreen(windowHandle, ref point);
        return point;
    }

    public static IntPtr FindVisibleWindow(uint processId, string title)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr windowHandle, IntPtr parameter)
        {
            if (!IsWindowVisible(windowHandle) || GetWindowProcessId(windowHandle) != processId)
            {
                return true;
            }

            StringBuilder windowTitle = new StringBuilder(256);
            GetWindowText(windowHandle, windowTitle, windowTitle.Capacity);
            if (windowTitle.ToString().IndexOf(title, StringComparison.OrdinalIgnoreCase) >= 0)
            {
                result = windowHandle;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@
}

function Set-IpcmForeground([IntPtr] $windowHandle) {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        $currentThreadId = [IpcmHoblStartWindowV3]::GetCurrentThreadId()
        $targetThreadId = [IpcmHoblStartWindowV3]::GetWindowThreadId($windowHandle)
        $foregroundWindow = [IpcmHoblStartWindowV3]::GetForegroundWindow()
        $foregroundThreadId = if ($foregroundWindow -ne [IntPtr]::Zero) {
            [IpcmHoblStartWindowV3]::GetWindowThreadId($foregroundWindow)
        } else {
            0
        }
        $attachedForeground = $false
        $attachedTarget = $false

        try {
            if ($foregroundThreadId -ne 0 -and $foregroundThreadId -ne $currentThreadId) {
                $attachedForeground = [IpcmHoblStartWindowV3]::AttachThreadInput(
                    $currentThreadId,
                    $foregroundThreadId,
                    $true
                )
            }
            if ($targetThreadId -ne 0 -and $targetThreadId -ne $currentThreadId) {
                $attachedTarget = [IpcmHoblStartWindowV3]::AttachThreadInput(
                    $currentThreadId,
                    $targetThreadId,
                    $true
                )
            }

            [IpcmHoblStartWindowV3]::UnlockForeground()
            [IpcmHoblStartWindowV3]::ShowWindow($windowHandle, 9) | Out-Null
            [IpcmHoblStartWindowV3]::BringWindowToTop($windowHandle) | Out-Null
            [IpcmHoblStartWindowV3]::SetForegroundWindow($windowHandle) | Out-Null
            [IpcmHoblStartWindowV3]::SetFocus($windowHandle) | Out-Null
        }
        finally {
            if ($attachedTarget) {
                [IpcmHoblStartWindowV3]::AttachThreadInput($currentThreadId, $targetThreadId, $false) | Out-Null
            }
            if ($attachedForeground) {
                [IpcmHoblStartWindowV3]::AttachThreadInput($currentThreadId, $foregroundThreadId, $false) | Out-Null
            }
        }

        Start-Sleep -Milliseconds 300
        if ([IpcmHoblStartWindowV3]::GetForegroundWindow() -eq $windowHandle) {
            return
        }
    }

    throw 'Windows would not activate the IPCM window. Keep the host desktop unlocked and run the HOBL backend in the active user session.'
}

function Get-IpcmButton([IntPtr] $windowHandle, [string] $name) {
    $root = [Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $nameCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::NameProperty,
        $name
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
    [IntPtr] $windowHandle,
    [string] $name,
    [int] $fallbackX,
    [int] $fallbackY
) {
    $button = Get-IpcmButton $windowHandle $name
    if ($button -and $button.Current.IsEnabled) {
        try {
            $pattern = $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
            ([Windows.Automation.InvokePattern] $pattern).Invoke()
            return 'ui_automation_invoke'
        } catch {
        }
        $bounds = $button.Current.BoundingRectangle
        if (-not $bounds.IsEmpty) {
            Set-IpcmForeground $windowHandle
            if ([IpcmHoblStartWindowV3]::SetCursorPos(
                [int]($bounds.Left + ($bounds.Width / 2)),
                [int]($bounds.Top + ($bounds.Height / 2))
            )) {
                [IpcmHoblStartWindowV3]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
                Start-Sleep -Milliseconds 100
                [IpcmHoblStartWindowV3]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
                return 'ui_automation_mouse'
            }
        }
    }
    if ([IpcmHoblStartWindowV3]::ClickLogicalClientPoint($windowHandle, $fallbackX, $fallbackY)) {
        return 'coordinate_fallback'
    }
    throw "Could not invoke $name in IPCM."
}

function Wait-IpcmButtonEnabled(
    [IntPtr] $windowHandle,
    [string] $name,
    [int] $timeoutSeconds
) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    do {
        $button = Get-IpcmButton $windowHandle $name
        if ($button -and $button.Current.IsEnabled) {
            return $true
        }
        Start-Sleep -Milliseconds 250
    } until ((Get-Date) -ge $deadline)
    return $false
}

function Send-IpcmSequence([IntPtr] $windowHandle, [int] $processId, [string[]] $keys) {
    Set-IpcmForeground $windowHandle
    foreach ($key in $keys) {
        [System.Windows.Forms.SendKeys]::SendWait($key)
        Start-Sleep -Milliseconds 250
        $foregroundWindow = [IpcmHoblStartWindowV3]::GetForegroundWindow()
        if ([IpcmHoblStartWindowV3]::GetWindowProcessId($foregroundWindow) -ne $processId) {
            throw 'IPCM lost keyboard focus while log collection was starting.'
        }
    }
}

function Confirm-IpcmDeviceDialog([int] $processId) {
    $deviceDialog = [IpcmHoblStartWindowV3]::FindVisibleWindow($processId, 'Open Device')
    if ($deviceDialog -eq [IntPtr]::Zero) {
        return $false
    }

    Write-IpcmStartDiagnostic 'selecting_cached_device' @{ ProcessId = $processId }
    [IpcmHoblStartWindowV3]::UnlockForeground()
    [IpcmHoblStartWindowV3]::ShowWindow($deviceDialog, 9) | Out-Null
    [IpcmHoblStartWindowV3]::BringWindowToTop($deviceDialog) | Out-Null
    [IpcmHoblStartWindowV3]::SetForegroundWindow($deviceDialog) | Out-Null
    Start-Sleep -Milliseconds 300
    if (-not [IpcmHoblStartWindowV3]::ClickClientRatio($deviceDialog, 0.30, 0.64)) {
        throw 'Could not click the cached IPCM device entry.'
    }
    Start-Sleep -Milliseconds 500
    if (-not [IpcmHoblStartWindowV3]::ClickClientRatio($deviceDialog, 0.86, 0.94)) {
        throw 'Could not click OK in the IPCM device dialog.'
    }
    Start-Sleep -Seconds 3
    if ([IpcmHoblStartWindowV3]::IsWindowVisible($deviceDialog)) {
        Write-IpcmStartDiagnostic 'device_dialog_did_not_close' @{ ProcessId = $processId }
        throw 'IPCM device selection was not accepted; the Open Device dialog remained visible.'
    }
    Write-IpcmStartDiagnostic 'cached_device_confirmed' @{ ProcessId = $processId }
    return $true
}

function Save-IpcmWindowCapture(
    [IntPtr] $windowHandle,
    [string] $fileName
) {
    $rectangle = [IpcmHoblStartWindowV3+Rect]::new()
    if (-not [IpcmHoblStartWindowV3]::GetWindowRect($windowHandle, [ref] $rectangle)) {
        return $null
    }

    $width = $rectangle.Right - $rectangle.Left
    $height = $rectangle.Bottom - $rectangle.Top
    if ($width -le 0 -or $height -le 0) {
        return $null
    }

    Add-Type -AssemblyName System.Drawing
    $capturePath = Join-Path $LogPath $fileName
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen(
            $rectangle.Left,
            $rectangle.Top,
            0,
            0,
            [System.Drawing.Size]::new($width, $height)
        )
        $bitmap.Save($capturePath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    return $capturePath
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'HOBL must be run as Administrator to automate IPCM.'
}

if (Get-Process -Name 'IpcmView' -ErrorAction SilentlyContinue) {
    throw 'IPCM is already running. Close it before starting the HOBL job.'
}

$appDirectory = $PSScriptRoot
$executable = Join-Path $appDirectory 'IpcmView.exe'
$configPath = Join-Path $appDirectory 'ipcm-conf.json'
$deviceDirectory = Join-Path $appDirectory 'devices'

if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "IPCM executable not found: $executable"
}
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "IPCM configuration not found: $configPath"
}
if (-not (Test-Path -LiteralPath $deviceDirectory -PathType Container)) {
    throw "IPCM devices folder not found: $deviceDirectory"
}
if (-not (Test-Path -LiteralPath $LogPath -PathType Container)) {
    throw "HOBL result folder not found: $LogPath"
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$ipcmSettings = $config | Where-Object ConfigSection -eq 'IpcmSettings'
if (-not $ipcmSettings) {
    throw 'The IpcmSettings section is missing from ipcm-conf.json.'
}

$ipcmSettings.LogPath = $LogPath
$ipcmSettings.AutoStopDuration = $Duration
$ipcmSettings.SamplePeriod = $SamplePeriod
$config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8

$startedAt = Get-Date
$statePath = Join-Path $LogPath '.ipcm-session.json'
$cancelPath = Join-Path $LogPath '.ipcm-cancel'
$diagnosticPath = Join-Path $LogPath 'ipcm-start-diagnostic.json'
$timerScript = Join-Path $appDirectory 'Run-IPCM-Timer.ps1'
$process = $null

if (-not (Test-Path -LiteralPath $timerScript -PathType Leaf)) {
    throw "IPCM timer worker not found: $timerScript"
}
Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue

function Write-IpcmStartDiagnostic(
    [string] $Stage,
    [hashtable] $Details = @{}
) {
    $timestamp = (Get-Date).ToString('o')
    $history = @()
    if (Test-Path -LiteralPath $diagnosticPath -PathType Leaf) {
        try {
            $previousDiagnostic = Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json
            if ($previousDiagnostic.History) {
                $history = @($previousDiagnostic.History)
            }
        }
        catch {
        }
    }

    $event = [ordered]@{
        Stage = $Stage
        Timestamp = $timestamp
    }
    foreach ($key in $Details.Keys) {
        $event[$key] = $Details[$key]
    }
    $history += [pscustomobject]$event

    $diagnostic = [ordered]@{
        Stage = $Stage
        Timestamp = $timestamp
        LogPath = $LogPath
        Duration = $Duration
        SamplePeriod = $SamplePeriod
        TransferToConsole = $TransferToConsole
        History = $history
    }
    foreach ($key in $Details.Keys) {
        $diagnostic[$key] = $Details[$key]
    }
    $diagnostic | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $diagnosticPath -Encoding UTF8
}

try {
    Write-IpcmStartDiagnostic 'launching_process'
    $returnWindowHandle = [IpcmHoblStartWindowV3]::GetForegroundWindow().ToInt64()
    $process = Start-Process -FilePath $executable -WorkingDirectory $appDirectory -WindowStyle Maximized -PassThru
    [pscustomobject]@{
        ProcessId = $process.Id
        StartedAt = $startedAt.ToString('o')
        LogPath = $LogPath
        Duration = $Duration
        SamplePeriod = $SamplePeriod
        TransferToConsole = $TransferToConsole
        ReturnWindowHandle = $returnWindowHandle
        Stage = 'process_started'
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-IpcmStartDiagnostic 'process_started' @{ ProcessId = $process.Id }

    $windowDeadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
    } until ($process.HasExited -or $process.MainWindowHandle -ne [IntPtr]::Zero -or (Get-Date) -ge $windowDeadline)

    if ($process.HasExited) {
        throw 'IPCM closed before its main window was ready.'
    }
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
        throw 'IPCM did not open its main window within 20 seconds.'
    }
    Write-IpcmStartDiagnostic 'main_window_ready' @{
        ProcessId = $process.Id
        MainWindowHandle = $process.MainWindowHandle.ToInt64()
    }

    Start-Sleep -Seconds 4
    Confirm-IpcmDeviceDialog $process.Id | Out-Null

    Set-IpcmForeground $process.MainWindowHandle
    $clientRectangle = [IpcmHoblStartWindowV3+Rect]::new()
    [IpcmHoblStartWindowV3]::GetClientRect(
        $process.MainWindowHandle,
        [ref] $clientRectangle
    ) | Out-Null
    $previewScreenPoint = [IpcmHoblStartWindowV3]::GetLogicalClientScreenPoint(
        $process.MainWindowHandle,
        323,
        30
    )
    $beforePreviewCapture = Save-IpcmWindowCapture `
        $process.MainWindowHandle `
        'ipcm-before-preview.png'
    $previewMethod = Invoke-IpcmButton $process.MainWindowHandle 'Preview' 323 30
    Write-IpcmStartDiagnostic 'preview_requested' @{
        ProcessId = $process.Id
        Method = $previewMethod
        ClientX = 323
        ClientY = 30
        WindowDpi = [IpcmHoblStartWindowV3]::GetDpiForWindow($process.MainWindowHandle)
        RemoteSession = [IpcmHoblStartWindowV3]::IsRemoteSession()
        ClientWidth = $clientRectangle.Right - $clientRectangle.Left
        ClientHeight = $clientRectangle.Bottom - $clientRectangle.Top
        ScreenX = $previewScreenPoint.X
        ScreenY = $previewScreenPoint.Y
        BeforeCapture = $beforePreviewCapture
    }

    Start-Sleep -Seconds 1
    $afterPreviewCapture = Save-IpcmWindowCapture `
        $process.MainWindowHandle `
        'ipcm-after-preview.png'
    Write-IpcmStartDiagnostic 'preview_after_capture' @{
        ProcessId = $process.Id
        Capture = $afterPreviewCapture
    }
    $deviceConfirmedAfterPreview = Confirm-IpcmDeviceDialog $process.Id
    if ($deviceConfirmedAfterPreview) {
        $process.Refresh()
        $previewMethod = Invoke-IpcmButton $process.MainWindowHandle 'Preview' 323 30
        Write-IpcmStartDiagnostic 'preview_retried_after_device' @{
            ProcessId = $process.Id
            Method = $previewMethod
            ClientX = 323
            ClientY = 30
        }
        Start-Sleep -Seconds 1
        if (Confirm-IpcmDeviceDialog $process.Id) {
            throw 'IPCM reopened the device dialog after the cached device was confirmed.'
        }
    }

    if (-not (Wait-IpcmButtonEnabled $process.MainWindowHandle 'Pause' 5)) {
        throw 'IPCM did not enter Preview mode; Pause never became enabled.'
    }

    $previewStartedAt = Get-Date
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state.Stage = 'preview_started'
    $state | Add-Member -NotePropertyName PreviewStartedAt -NotePropertyValue $previewStartedAt.ToString('o')
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-IpcmStartDiagnostic 'preview_started' @{ ProcessId = $process.Id }

    if ($returnWindowHandle -ne 0) {
        $returnWindow = [IntPtr]::new($returnWindowHandle)
        if ([IpcmHoblStartWindowV3]::IsWindowVisible($returnWindow)) {
            [IpcmHoblStartWindowV3]::ShowWindow($returnWindow, 9) | Out-Null
            [IpcmHoblStartWindowV3]::SetForegroundWindow($returnWindow) | Out-Null
        }
    }

    $timerArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $timerScript),
        '-LogPath', ('"{0}"' -f $LogPath)
    ) -join ' '
    $timerStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $timerStartInfo.FileName = 'powershell.exe'
    $timerStartInfo.Arguments = $timerArguments
    $timerStartInfo.WorkingDirectory = $appDirectory
    $timerStartInfo.UseShellExecute = $true
    $timerStartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $timerProcess = [Diagnostics.Process]::Start($timerStartInfo)
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $state | Add-Member -NotePropertyName WorkerProcessId -NotePropertyValue $timerProcess.Id
    $state | Add-Member -NotePropertyName WorkerStartedAt -NotePropertyValue $timerProcess.StartTime.ToString('o')
    $state.Stage = 'worker_started'
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-IpcmStartDiagnostic 'worker_started' @{
        ProcessId = $process.Id
        WorkerProcessId = $timerProcess.Id
    }
    Write-Output "IPCM Preview started; Log will start asynchronously after 30 seconds. Process ID: $($process.Id)"
}
catch {
    try {
        Write-IpcmStartDiagnostic 'failed' @{
            Error = $_.Exception.Message
            ProcessId = if ($process) { $process.Id } else { $null }
        }
    }
    catch {
    }
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    throw
}
