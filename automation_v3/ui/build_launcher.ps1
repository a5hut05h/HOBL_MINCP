# Run with Windows PowerShell 5.1 to use the installed .NET Framework compiler.
$ErrorActionPreference = 'Stop'
try {
    $compilerCommand = Get-Command csc.exe -ErrorAction SilentlyContinue
    $compiler = if ($compilerCommand) { $compilerCommand.Source } else {
        Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    }
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw 'C# compiler not found. Run this build script with Windows PowerShell 5.1 (powershell.exe).'
    }
    $source = Join-Path $PSScriptRoot 'SchedulerLauncher.cs'
    $manifest = Join-Path $PSScriptRoot 'SchedulerLauncher.manifest'
    $script = Join-Path $PSScriptRoot 'register_schedule_wpf.ps1'
    foreach ($required in @($source, $manifest, $script)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file not found: $required" }
    }
    $output = Join-Path $PSScriptRoot 'HOBL-Scheduler.exe'
    Write-Host "Using C# compiler: $compiler"
    & $compiler /nologo /target:winexe /platform:anycpu /optimize+ /warnaserror+ "/win32manifest:$manifest" /reference:System.Windows.Forms.dll "/out:$output" $source
    if ($LASTEXITCODE -ne 0) { throw "Launcher compilation failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path -LiteralPath $output -PathType Leaf)) { throw "Compiler did not create $output" }
    Write-Host "Built: $output" -ForegroundColor Green
} catch {
    Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
