$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`""
    )
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class IpcmWindow
{
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);
}
'@

function Show-Error([string] $message) {
    [System.Windows.Forms.MessageBox]::Show(
        $message,
        'IPCM automatic logging',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Set-IpcmForeground([IntPtr] $windowHandle) {
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        [IpcmWindow]::ShowWindow($windowHandle, 3) | Out-Null
        [IpcmWindow]::SetForegroundWindow($windowHandle) | Out-Null
        Start-Sleep -Milliseconds 300
        if ([IpcmWindow]::GetForegroundWindow() -eq $windowHandle) {
            break
        }
    }
    if ([IpcmWindow]::GetForegroundWindow() -ne $windowHandle) {
        throw 'Windows would not bring IPCM to the foreground.'
    }
}

function Send-IpcmSequence([IntPtr] $windowHandle, [string[]] $keys) {
    Set-IpcmForeground $windowHandle
    foreach ($key in $keys) {
        [System.Windows.Forms.SendKeys]::SendWait($key)
        Start-Sleep -Milliseconds 250
        if ([IpcmWindow]::GetForegroundWindow() -ne $windowHandle) {
            throw 'IPCM lost keyboard focus while automatic logging was starting.'
        }
    }
}

try {
    $appDirectory = $PSScriptRoot
    $executable = Join-Path $appDirectory 'IpcmView.exe'
    $configPath = Join-Path $appDirectory 'ipcm-conf.json'

    if (Get-Process -Name 'IpcmView' -ErrorAction SilentlyContinue) {
        throw 'IPCM is already running. Close it, then run this launcher again.'
    }

    $settings = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $ipcmSettings = $settings | Where-Object ConfigSection -eq 'IpcmSettings'
    $logDirectory = $ipcmSettings.LogPath
    if (-not $logDirectory -or -not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        throw "The configured IPCM log folder does not exist: $logDirectory"
    }

    $startedAt = Get-Date
    $process = Start-Process -FilePath $executable -WorkingDirectory $appDirectory -WindowStyle Maximized -PassThru
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
    } until ($process.HasExited -or $process.MainWindowHandle -ne [IntPtr]::Zero -or (Get-Date) -ge $deadline)

    if ($process.HasExited) {
        throw 'IPCM closed before its main window was ready.'
    }
    if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
        throw 'IPCM did not open its main window within 20 seconds.'
    }

    [IpcmWindow]::ShowWindow($process.MainWindowHandle, 3) | Out-Null
    [IpcmWindow]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
    Start-Sleep -Seconds 4

    # IPCM starts with no keyboard focus: Open is the first tab stop and Preview is the second.
    Send-IpcmSequence $process.MainWindowHandle @('{TAB}', '{TAB}', '{ENTER}')
    Start-Sleep -Seconds 3

    # Preview resets focus: Open, Pause, Stop, and Log are the next four tab stops.
    Send-IpcmSequence $process.MainWindowHandle @('{TAB}', '{TAB}', '{TAB}', '{TAB}', '{ENTER}')

    $logDeadline = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 500
        $newLog = Get-ChildItem -LiteralPath $logDirectory -Filter 'ipcmview-log-*.csv' -File |
            Where-Object LastWriteTime -ge $startedAt |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    } until ($newLog -or $process.HasExited -or (Get-Date) -ge $logDeadline)

    if (-not $newLog) {
        throw "IPCM opened, but no new log appeared in $logDirectory. Check the FT2232H connection and try again."
    }
}
catch {
    Show-Error $_.Exception.Message
    exit 1
}
