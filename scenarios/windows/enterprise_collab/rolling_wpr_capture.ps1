# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [Parameter(Mandatory = $true)]
    [string]$WprpPath,
    [Parameter(Mandatory = $true)]
    [string]$OutputDir,
    [Parameter(Mandatory = $true)]
    [string]$RunName,
    [Parameter(Mandatory = $true)]
    [string]$InstanceName,
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 1440)]
    [int]$IntervalMinutes
)

$ErrorActionPreference = "Continue"
$runOutputDir = Join-Path $OutputDir $RunName
New-Item -ItemType Directory -Path $runOutputDir -Force -ErrorAction Stop | Out-Null
$logFile = Join-Path $runOutputDir "collect_log.txt"

function Write-Log([string]$message) {
    $line = "[$(Get-Date -Format 'yyyyMMdd_HHmmss')] $message"
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $WprpPath)) {
    Write-Log " ERROR - WPRP file not found: $WprpPath"
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal]`
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log " ERROR - Rolling WPR capture requires an elevated DUT remote agent."
    exit 1
}

$savedCount = 0
try {
    Write-Log " INFO - Rolling WPR capture started: provider=$WprpPath, interval=$IntervalMinutes minute(s), instance=$InstanceName"
    while ($true) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $etlPath = Join-Path $runOutputDir "WPR_${timestamp}.etl"

        $cancelOutput = & wpr -cancel -instancename $InstanceName 2>&1
        $cancelExit = $LASTEXITCODE
        if ($cancelExit -ne 0) {
            Write-Log " INFO - No previous WPR instance to cancel (exit=$cancelExit): $($cancelOutput -join ' | ')"
        }

        $startOutput = & wpr -start $WprpPath -filemode -instancename $InstanceName 2>&1
        $startExit = $LASTEXITCODE
        if ($startExit -ne 0) {
            Write-Log " ERROR - wpr -start failed exit=$startExit for $WprpPath`: $($startOutput -join ' | ')"
            exit 1
        }

        Write-Log " INFO - Recording $WprpPath for $IntervalMinutes minute(s), instance=$InstanceName"
        Start-Sleep -Seconds ($IntervalMinutes * 60)

        $stopOutput = & wpr -stop $etlPath -instancename $InstanceName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log " ERROR - wpr -stop failed: $($stopOutput -join ' | ')"
            continue
        }

        $savedCount++
        Write-Log " INFO - Trace saved: $etlPath"
    }
}
catch {
    Write-Log " ERROR - Rolling WPR capture failed at line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)"
}
finally {
    & wpr -cancel -instancename $InstanceName 2>&1 | Out-Null
    Write-Log " INFO - Rolling capture ended; saved segments=$savedCount"
}
