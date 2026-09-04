# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceName,
    [Parameter(Mandatory = $true)]
    [string]$RunName
)

$escapedRunName = [regex]::Escape($RunName)
$captureProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine -match "rolling_wpr_capture\.ps1" -and
        $_.CommandLine -match $escapedRunName
    }

foreach ($captureProcess in $captureProcesses) {
    Stop-Process -Id $captureProcess.ProcessId -Force -ErrorAction SilentlyContinue
}

wpr -cancel -instancename $InstanceName 2>$null | Out-Null
Write-Host (" INFO - Stopped rolling WPR capture instance={0}, processes={1}" -f $InstanceName, @($captureProcesses).Count)
