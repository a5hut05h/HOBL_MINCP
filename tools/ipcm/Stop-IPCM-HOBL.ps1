param(
    [Parameter(Mandatory = $true)]
    [string] $LogPath
)

$ErrorActionPreference = 'Stop'
$statePath = Join-Path $LogPath '.ipcm-session.json'
$cancelPath = Join-Path $LogPath '.ipcm-cancel'

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Output 'No IPCM session is owned by this HOBL result folder.'
    exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$startedAt = [DateTime]::Parse($state.StartedAt)
$loggingStages = @(
    'log_requested',
    'logging',
    'waiting_for_auto_stop',
    'logging_until_hobl_stops',
    'auto_stopped'
)
$loggingStarted = $state.Stage -in $loggingStages

New-Item -Path $cancelPath -ItemType File -Force | Out-Null
if ($state.WorkerProcessId) {
    $worker = Get-Process -Id $state.WorkerProcessId -ErrorAction SilentlyContinue
    if ($worker -and $worker.Id -ne $PID -and $worker.ProcessName -in @('powershell', 'pwsh')) {
        if ($state.WorkerStartedAt) {
            $workerStartedAt = [DateTime]::Parse($state.WorkerStartedAt)
            if ([Math]::Abs(($worker.StartTime - $workerStartedAt).TotalSeconds) -gt 10) {
                $worker = $null
            }
        }
        if ($worker) {
            Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue
            $worker.WaitForExit(5000) | Out-Null
        }
    }
}

if ($state.SessionWatchProcessId) {
    $sessionWatch = Get-Process -Id $state.SessionWatchProcessId -ErrorAction SilentlyContinue
    if (
        $sessionWatch -and
        $sessionWatch.Id -ne $PID -and
        $sessionWatch.ProcessName -in @('powershell', 'pwsh')
    ) {
        if ($state.SessionWatchStartedAt) {
            $sessionWatchStartedAt = [DateTime]::Parse($state.SessionWatchStartedAt)
            if ([Math]::Abs(($sessionWatch.StartTime - $sessionWatchStartedAt).TotalSeconds) -gt 10) {
                $sessionWatch = $null
            }
        }
        if ($sessionWatch) {
            if (-not $sessionWatch.WaitForExit(3000)) {
                Stop-Process -Id $sessionWatch.Id -Force -ErrorAction SilentlyContinue
                $sessionWatch.WaitForExit(5000) | Out-Null
            }
        }
    }
}

$process = Get-Process -Id $state.ProcessId -ErrorAction SilentlyContinue
if ($process -and (
    $process.ProcessName -ne 'IpcmView' -or
    [Math]::Abs(($process.StartTime - $startedAt).TotalSeconds) -gt 10
)) {
    $process = $null
}

function Get-IpcmArtifact([string] $pattern) {
    Get-ChildItem -LiteralPath $LogPath -Filter $pattern -File |
        Where-Object LastWriteTime -ge $startedAt |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

try {
    if ($process) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class IpcmHoblStopWindow
{
    [StructLayout(LayoutKind.Sequential)]
    public struct Point
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr windowHandle);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr windowHandle, int command);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr windowHandle);

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
                if (-not $bounds.IsEmpty -and [IpcmHoblStopWindow]::SetCursorPos(
                    [int]($bounds.Left + ($bounds.Width / 2)),
                    [int]($bounds.Top + ($bounds.Height / 2))
                )) {
                    [IpcmHoblStopWindow]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
                    Start-Sleep -Milliseconds 100
                    [IpcmHoblStopWindow]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
                    return 'ui_automation_mouse'
                }
            }
            if ([IpcmHoblStopWindow]::ClickLogicalClientPoint($windowHandle, $fallbackX, $fallbackY)) {
                return 'coordinate_fallback'
            }
            throw "Could not invoke $name in IPCM."
        }

        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero -and -not (Get-IpcmArtifact 'ipcmview-sum-*.csv')) {
            $returnWindow = [IpcmHoblStopWindow]::GetForegroundWindow()
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                [IpcmHoblStopWindow]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
                [IpcmHoblStopWindow]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
                Start-Sleep -Milliseconds 300
                if ([IpcmHoblStopWindow]::GetForegroundWindow() -eq $process.MainWindowHandle) {
                    break
                }
            }

            if ([IpcmHoblStopWindow]::GetForegroundWindow() -eq $process.MainWindowHandle) {
                $stopMethod = Invoke-IpcmButton $process.MainWindowHandle 'Stop' 410 30
                Write-Output "IPCM Stop requested using $stopMethod."
                if (
                    $returnWindow -ne [IntPtr]::Zero -and
                    $returnWindow -ne $process.MainWindowHandle -and
                    [IpcmHoblStopWindow]::IsWindowVisible($returnWindow)
                ) {
                    [IpcmHoblStopWindow]::ShowWindow($returnWindow, 9) | Out-Null
                    [IpcmHoblStopWindow]::SetForegroundWindow($returnWindow) | Out-Null
                }
            }
        }
    }

    if (-not $loggingStarted) {
        Start-Sleep -Seconds 5
        if ($process -and -not $process.HasExited) {
            $process.CloseMainWindow() | Out-Null
            if (-not $process.WaitForExit(5000)) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Output 'IPCM Preview stopped before Log started; no CSV artifacts were expected.'
        exit 0
    }

    $artifactDeadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $logFile = Get-IpcmArtifact 'ipcmview-log-*.csv'
        $summaryFile = Get-IpcmArtifact 'ipcmview-sum-*.csv'
    } until (($logFile -and $summaryFile) -or (Get-Date) -ge $artifactDeadline)

    if (-not $logFile) {
        throw "The IPCM detailed log was not finalized in $LogPath."
    }
    if (-not $summaryFile) {
        throw "The IPCM summary log was not finalized in $LogPath."
    }

    $previousSizes = @($logFile.Length, $summaryFile.Length)
    Start-Sleep -Seconds 2
    $logFile = Get-Item -LiteralPath $logFile.FullName
    $summaryFile = Get-Item -LiteralPath $summaryFile.FullName
    if ($logFile.Length -ne $previousSizes[0] -or $summaryFile.Length -ne $previousSizes[1]) {
        Start-Sleep -Seconds 2
    }

    Start-Sleep -Seconds 5
    if ($process -and -not $process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        if (-not $process.WaitForExit(5000)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Output "IPCM log finalized: $($logFile.FullName)"
    Write-Output "IPCM summary finalized: $($summaryFile.FullName)"
}
finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $cancelPath -Force -ErrorAction SilentlyContinue
}
