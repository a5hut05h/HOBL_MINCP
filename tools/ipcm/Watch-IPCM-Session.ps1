param(
    [Parameter(Mandatory = $true)]
    [string] $LogPath,

    [Parameter(Mandatory = $true)]
    [int] $SessionId,

    [Parameter(Mandatory = $true)]
    [int] $HoblProcessId
)

$ErrorActionPreference = 'Stop'
$diagnosticPath = Join-Path $LogPath 'ipcm-session-transfer.json'

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class IpcmSessionWatch
{
    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQuerySessionInformationW(
        IntPtr serverHandle,
        int sessionId,
        int infoClass,
        out IntPtr buffer,
        out int bytesReturned
    );

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr buffer);

    [DllImport("kernel32.dll")]
    public static extern uint WTSGetActiveConsoleSessionId();

    public static int GetConnectState(int sessionId)
    {
        IntPtr buffer;
        int bytesReturned;
        if (!WTSQuerySessionInformationW(IntPtr.Zero, sessionId, 8, out buffer, out bytesReturned))
        {
            throw new InvalidOperationException(
                "WTSQuerySessionInformation failed with error " + Marshal.GetLastWin32Error()
            );
        }

        try
        {
            if (buffer == IntPtr.Zero || bytesReturned < sizeof(int))
            {
                throw new InvalidOperationException("WTS returned no connection state.");
            }
            return Marshal.ReadInt32(buffer);
        }
        finally
        {
            WTSFreeMemory(buffer);
        }
    }
}
'@

function Write-IpcmSessionDiagnostic([string] $Stage, [hashtable] $Details = @{}) {
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

    $event = [ordered]@{
        Stage = $Stage
        Timestamp = (Get-Date).ToString('o')
    }
    foreach ($key in $Details.Keys) {
        $event[$key] = $Details[$key]
    }
    $history += [pscustomobject] $event

    [ordered]@{
        Stage = $Stage
        Timestamp = $event.Timestamp
        SessionId = $SessionId
        History = $history
        Details = $Details
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $diagnosticPath -Encoding UTF8
}

try {
    $lastConnectState = $null
    $disconnectedAt = $null
    $transferCount = 0
    Write-IpcmSessionDiagnostic 'watchdog_started' @{
        ProcessId = $PID
        HoblProcessId = $HoblProcessId
        ActiveConsoleSessionId = [IpcmSessionWatch]::WTSGetActiveConsoleSessionId()
    }

    while (Get-Process -Id $HoblProcessId -ErrorAction SilentlyContinue) {
        $connectState = [IpcmSessionWatch]::GetConnectState($SessionId)
        if ($connectState -ne $lastConnectState) {
            Write-IpcmSessionDiagnostic 'session_state_changed' @{
                ConnectState = $connectState
                PreviousConnectState = $lastConnectState
                ActiveConsoleSessionId = [IpcmSessionWatch]::WTSGetActiveConsoleSessionId()
            }
            $lastConnectState = $connectState
        }

        if ($connectState -eq 4) {
            if (-not $disconnectedAt) {
                $disconnectedAt = Get-Date
                Write-IpcmSessionDiagnostic 'rdp_disconnect_pending' @{
                    GracePeriodSeconds = 10
                    ActiveConsoleSessionId = [IpcmSessionWatch]::WTSGetActiveConsoleSessionId()
                }
            }
            if ((Get-Date) -lt $disconnectedAt.AddSeconds(10)) {
                Start-Sleep -Milliseconds 500
                continue
            }

            $tscon = Join-Path $env:SystemRoot 'System32\tscon.exe'
            if (-not (Test-Path -LiteralPath $tscon -PathType Leaf)) {
                throw "tscon.exe was not found at: $tscon"
            }

            Write-IpcmSessionDiagnostic 'rdp_disconnect_detected' @{
                TsconPath = $tscon
                ActiveConsoleSessionId = [IpcmSessionWatch]::WTSGetActiveConsoleSessionId()
            }
            $transfer = Start-Process `
                -FilePath $tscon `
                -ArgumentList @($SessionId, '/dest:console') `
                -WindowStyle Hidden `
                -Wait `
                -PassThru
            if ($transfer.ExitCode -ne 0) {
                throw "tscon failed with exit code $($transfer.ExitCode)."
            }

            $verificationDeadline = (Get-Date).AddSeconds(10)
            do {
                Start-Sleep -Milliseconds 250
                $connectState = [IpcmSessionWatch]::GetConnectState($SessionId)
                $activeConsoleSessionId = [IpcmSessionWatch]::WTSGetActiveConsoleSessionId()
            } until (
                ($connectState -eq 0 -and $activeConsoleSessionId -eq $SessionId) -or
                (Get-Date) -ge $verificationDeadline
            )
            if ($connectState -ne 0 -or $activeConsoleSessionId -ne $SessionId) {
                throw 'The RDP session did not become the active console session after tscon.'
            }

            $transferCount++
            Write-IpcmSessionDiagnostic 'console_transfer_completed' @{
                ExitCode = $transfer.ExitCode
                ConnectState = $connectState
                ActiveConsoleSessionId = $activeConsoleSessionId
                TransferCount = $transferCount
            }
            $lastConnectState = $connectState
            $disconnectedAt = $null
        }
        else {
            $disconnectedAt = $null
        }

        Start-Sleep -Milliseconds 500
    }

    Write-IpcmSessionDiagnostic 'watchdog_stopped' @{
        Reason = 'hobl_process_exited'
        TransferCount = $transferCount
    }
} catch {
    try {
        Write-IpcmSessionDiagnostic 'watchdog_failed' @{ Error = $_.Exception.Message }
    } catch {
    }
    exit 1
}