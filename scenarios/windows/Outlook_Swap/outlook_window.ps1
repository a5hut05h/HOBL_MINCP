# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Discover", "Complete")]
    [string]$Action,
    [ValidateSet("classic", "new")]
    [string]$Target = "classic",
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

try {
    if ($Action -eq "Discover") {
        $apps = @(Get-StartApps | Where-Object {
            $_.AppID -match 'OUTLOOK\.EXE|Microsoft\.OutlookForWindows_'
        } | Select-Object Name, AppID)
        $windows = @(Get-Process | Where-Object {
            $_.ProcessName -in @("OUTLOOK", "olk") -and $_.MainWindowHandle -ne 0
        } | Select-Object Id, ProcessName, MainWindowTitle)
        @{ Apps = $apps; OpenWindows = $windows } | ConvertTo-Json -Depth 4 -Compress
        exit 0
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class OutlookSwapWindow {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hwnd, StringBuilder name, int capacity);
}
'@

    $processName = if ($Target -eq "classic") { "OUTLOOK" } else { "olk" }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $outlook = $null
    do {
        $candidates = @(Get-Process | Where-Object {
            $_.ProcessName -eq $processName -and $_.MainWindowHandle -ne 0
        })
        if ($Target -eq "classic") {
            $candidates = @($candidates | Where-Object {
                $className = New-Object System.Text.StringBuilder 256
                [void][OutlookSwapWindow]::GetClassName($_.MainWindowHandle, $className, 256)
                $className.ToString() -eq "rctrl_renwnd32"
            })
        }
        if ($candidates.Count -gt 1) {
            throw "Multiple $Target Outlook windows found; refusing to close an arbitrary window."
        }
        if ($candidates.Count -eq 1) {
            $outlook = $candidates[0]
            break
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    if ($null -eq $outlook) {
        throw "No $Target Outlook main window appeared within $TimeoutSeconds seconds. Complete first-run setup and retry."
    }

    $window = $outlook.MainWindowHandle
    Write-Verbose "Using $Target Outlook PID $($outlook.Id), window $window"
    [void][OutlookSwapWindow]::ShowWindowAsync($window, 3)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not [OutlookSwapWindow]::IsZoomed($window)) {
        if (-not [OutlookSwapWindow]::IsWindow($window) -or (Get-Date) -ge $deadline) {
            throw "Could not verify that $Target Outlook was maximized."
        }
        Start-Sleep -Milliseconds 200
    }
    Start-Sleep -Seconds 2
    $outlook.Refresh()
    if ($outlook.MainWindowHandle -ne $window) {
        throw "Outlook changed its main window; refusing to close an unverified window."
    }
    if (-not [OutlookSwapWindow]::IsZoomed($window)) {
        throw "Outlook was no longer maximized after the 2-second hold."
    }
    if (-not $outlook.CloseMainWindow()) {
        throw "Outlook did not accept a graceful close request."
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ([OutlookSwapWindow]::IsWindow($window)) {
        if ((Get-Date) -ge $deadline) {
            throw "Outlook did not close. Resolve any save/sign-in dialog manually; no process was force-killed."
        }
        Start-Sleep -Milliseconds 500
    }
    @{ target = $Target; process_id = $outlook.Id; maximized = $true; closed = $true } |
        ConvertTo-Json -Compress
} catch {
    Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
