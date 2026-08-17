# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
#
# start_percentile_stress.ps1 - Launcher for percentile_stress.py on the DUT.
#
# Architecture-agnostic: pyenv-win resolves the right python.exe (x64 or arm64)
# based on whatever was installed by perf_stress_prep.ps1.
#
# Called from code_1EN194J.py via a single PowerShell invocation - all pyenv
# resolution, diagnostics, and Start-Process happen here so the host side does
# not have to escape nested quotes through cmd->powershell.
#
# Launches python.exe via Shell.Application::ShellExecute so the child runs
# outside our elevated PowerShell token chain and inherits normal user-mode
# QoS (instead of the HOBL command handler's Important/HighQoS band, which
# previously pinned the stress spinner to P-cores at Pri-8).
#
# Diagnostics tee to $LogFile on the DUT for post-mortem.
# Exit codes:
#   0 = at least one new python.exe appeared within 1.5s of ShellExecute
#   1 = pyenv-win not installed / wrong path - re-run perf_stress_prep.ps1
#   2 = ShellExecute threw, or no new python.exe appeared (check log + percentile_stress.py)

param(
    [Parameter(Mandatory=$true)]
    [string]$ScriptPath,

    [Parameter(Mandatory=$true)]
    [ValidateSet('0','25','50','65','75','85')]
    [string]$TargetCpu,

    [string]$LogFile = "C:\hobl_bin\percentile_stress_launch.log"
)

$ErrorActionPreference = 'Continue'

function Write-Step {
    param([string]$Message)
    $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $Message
    Write-Host $line
    try {
        Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    } catch {}
}

Write-Step ' === percentile_stress launcher start ==='
Write-Step (' ScriptPath = ' + $ScriptPath)
Write-Step (' TargetCpu  = ' + $TargetCpu)
Write-Step (' Architecture = ' + $env:PROCESSOR_ARCHITECTURE)

# --- pyenv-win path resolution (works for x64 and arm64 DUTs identically) ---
$shims = Join-Path $env:USERPROFILE '.pyenv\pyenv-win\shims'
$pbin  = Join-Path $env:USERPROFILE '.pyenv\pyenv-win\bin'
Write-Step (' shims=' + $shims + ' exists=' + (Test-Path $shims))
Write-Step (' pbin =' + $pbin  + ' exists=' + (Test-Path $pbin))

if (-not (Test-Path $shims) -or -not (Test-Path $pbin)) {
    Write-Step ' ERROR - pyenv-win not installed on this DUT. Re-run perf_stress_prep.ps1.'
    exit 1
}

$env:PATH = $shims + ';' + $pbin + ';' + $env:PATH

$py = (& pyenv which python 2>$null)
Write-Step (" pyenv which python returned: [" + $py + "]")
if (-not $py -or -not (Test-Path $py)) {
    Write-Step ' ERROR - pyenv which python returned no valid path. Prep pyenv install incomplete.'
    exit 1
}

$pyVer = (& $py --version 2>&1)
Write-Step (' python version: ' + $pyVer)

# Validate the script we are about to run actually exists
if (-not (Test-Path $ScriptPath)) {
    Write-Step (' ERROR - script not found: ' + $ScriptPath)
    exit 1
}

# --- Launch ---
# Launch via Shell.Application::ShellExecute. This routes through Explorer.exe
# (the shell), which spawns python.exe outside our elevated PowerShell token
# chain. Net effect: python.exe and its mp.Process children come up with normal
# user-mode QoS instead of inheriting the HOBL command handler's Important/
# HighQoS band (which previously pinned the stress spinner to P-cores at Pri-8
# and contended with foreground Word/Edge boots).
# Same pattern used for the EC SimpleTimer fix.
# Cost: ShellExecute returns void (no PID), so the post-launch liveness probe
# snapshots python.exe PIDs before/after and reports the delta.
Write-Step (' launching via Shell.Application::ShellExecute (de-elevates QoS)')
Write-Step (' command: ' + $py + ' ' + $ScriptPath + ' --target-cpu ' + $TargetCpu)

$beforePids = @(Get-Process -Name python -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
Write-Step (' python PIDs before launch: ' + ($beforePids -join ','))

# ShellExecute args: file, parameters, dir, verb, showCmd (0 = SW_HIDE).
$shellArgs = '"' + $ScriptPath + '" --target-cpu ' + $TargetCpu
try {
    $shell = New-Object -ComObject Shell.Application
    $shell.ShellExecute($py, $shellArgs, $null, 'open', 0)
} catch {
    Write-Step (' ERROR - Shell.Application::ShellExecute threw: ' + $_.Exception.Message)
    exit 2
}

Start-Sleep -Milliseconds 1500
$afterPids = @(Get-Process -Name python -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$newPids   = $afterPids | Where-Object { $beforePids -notcontains $_ }
Write-Step (' python PIDs after launch:  ' + ($afterPids -join ','))
Write-Step (' new python PIDs:           ' + ($newPids   -join ','))

if ($newPids.Count -gt 0) {
    Write-Step (' PERCENTILE_STRESS_RUNNING pid=' + ($newPids -join ','))
    exit 0
} else {
    Write-Step (' ERROR - no new python.exe appeared within 1.5s of ShellExecute')
    Write-Step ('   To capture stderr for debugging, manually run on the DUT:')
    Write-Step ('   & "' + $py + '" "' + $ScriptPath + '" --target-cpu ' + $TargetCpu)
    exit 2
}
