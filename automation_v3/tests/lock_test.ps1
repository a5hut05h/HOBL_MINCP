# Isolated lock tests; no production tasks, configurations, or plans are changed.
param([string]$WorkerLockPath = '')
$ErrorActionPreference = 'Stop'
$common = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\common.ps1'
. $common
if ($WorkerLockPath) {
    $workerLock = Enter-HoblV3Lock -Path $WorkerLockPath -JobId 'test-job' -RunId 'crash-test'
    [System.IO.File]::WriteAllText("$WorkerLockPath.ready", 'ready')
    try { Start-Sleep -Seconds 120 } finally { Exit-HoblV3Lock $workerLock }
    return
}
$root = Join-Path $env:TEMP ('hobl-v3-lock-test-' + [guid]::NewGuid().ToString('N'))
$path = Join-Path $root 'worker.lock'
$lock = $null
$legacy = $null
$child = $null
function Assert-LockStatus([string]$Expected) {
    $actual = Get-HoblV3LockStatus -Path $path
    if ($actual -ne $Expected) { throw "Expected lock status $Expected, got $actual." }
}
try {
    Assert-LockStatus 'Free'
    New-Item -ItemType Directory -Path $root | Out-Null
    foreach ($payload in @('', 'invalid metadata', "$PID|reused-start-time|job|run|token")) {
        [System.IO.File]::WriteAllText($path, $payload)
        Assert-LockStatus 'Stale'
        Assert-HoblV3RemovalLock -Path $path -JobId 'test-job'
        $lock = Enter-HoblV3Lock -Path $path -JobId 'test-job' -RunId 'test-run'
        Assert-LockStatus 'Held'
        $rejected = $false
        try { Assert-HoblV3RemovalLock -Path $path -JobId 'test-job' } catch { $rejected = $true }
        if (-not $rejected) { throw 'Removal accepted an active worker lock.' }
        $rejected = $false
        try { $null = Enter-HoblV3Lock -Path $path -JobId 'test-job' -RunId 'competitor' } catch { $rejected = $true }
        if (-not $rejected) { throw 'Concurrent acquisition succeeded.' }
        Assert-LockStatus 'Held'
        Exit-HoblV3Lock $lock
        $lock = $null
        Assert-LockStatus 'Free'
    }

    $legacy = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
    Assert-LockStatus 'Held'
    $rejected = $false
    try { $null = Enter-HoblV3Lock -Path $path -JobId 'test-job' -RunId 'legacy-competitor' } catch { $rejected = $true }
    if (-not $rejected) { throw 'Acquisition replaced a live legacy lock.' }
    $legacy.Dispose()
    $legacy = $null
    Assert-LockStatus 'Stale'
    Remove-Item -LiteralPath $path

    $childOutput = Join-Path $root 'child-output.txt'
    $childErrors = Join-Path $root 'child-errors.txt'
    $child = Start-Process -FilePath (Get-Command powershell.exe -ErrorAction Stop).Source -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-WorkerLockPath',"`"$path`"") -PassThru -WindowStyle Hidden -RedirectStandardOutput $childOutput -RedirectStandardError $childErrors
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $child.HasExited -and -not (Test-Path -LiteralPath "$path.ready")) {
        Start-Sleep -Milliseconds 100
    }
    if ((Get-HoblV3LockStatus -Path $path) -ne 'Held') {
        throw "Child did not acquire lock. Ready=$(Test-Path -LiteralPath "$path.ready") Script=$PSCommandPath PID=$($child.Id) Exited=$($child.HasExited) Exit=$($child.ExitCode). Output=$(Get-Content -LiteralPath $childOutput -Raw) Errors=$(Get-Content -LiteralPath $childErrors -Raw)"
    }
    Stop-Process -Id $child.Id -ErrorAction Stop
    $child.WaitForExit()
    Assert-LockStatus 'Free'
    $child.Dispose()
    $child = $null

    $rejected = $false
    try { $null = Get-HoblV3LockStatus -Path $root } catch { $rejected = $true }
    if (-not $rejected) { throw 'Unexpected I/O error was treated as a free lock.' }
    Write-Host 'Lock tests passed (stale metadata, active/legacy exclusion, crash cleanup, I/O errors).'
} finally {
    if ($child) {
        if (-not $child.HasExited) { Stop-Process -Id $child.Id -ErrorAction Stop; $child.WaitForExit() }
        $child.Dispose()
    }
    if ($lock) { Exit-HoblV3Lock $lock }
    if ($legacy) { $legacy.Dispose() }
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
