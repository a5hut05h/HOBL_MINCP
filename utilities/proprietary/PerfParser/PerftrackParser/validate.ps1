<#
.SYNOPSIS
    Regenerates every validation output and compares it against the committed
    expectations.

.DESCRIPTION
    Outputs are written to a temporary directory so the committed files are
    never touched by a failing run. Exits with code 1 if any output drifts,
    which makes this usable as a pre-commit or CI gate.

.PARAMETER Update
    Overwrite the committed expectations with the freshly generated output.
    Use only after deliberately changing parser behaviour, and review the diff.
#>
[CmdletBinding()]
param(
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$manifest = Join-Path $root 'test\ConsumerMultitaskerPTs.xml'
$parser = Join-Path $root 'bin\Release\net8.0\PerfParser.dll'
$traces = @(
    'consumer_multitasker_021',
    'consumer_multitasker_022',
    'enterprise_collab'
)

if (-not (Test-Path $manifest)) {
    Write-Error "Manifest not found: $manifest"
}

if (-not (Test-Path $parser)) {
    Write-Host 'Parser not built, building Release...' -ForegroundColor Yellow
    dotnet build (Join-Path $root 'PerfParser.csproj') --configuration Release --nologo
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'Build failed.'
    }
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "perfparser_validate_$PID"
New-Item -ItemType Directory -Force -Path $work | Out-Null

$failed = @()
try {
    foreach ($trace in $traces) {
        $etl = Join-Path $root "validation\$trace.etl"
        if (-not (Test-Path $etl)) {
            Write-Host "  SKIP  $trace (no trace file)" -ForegroundColor Yellow
            continue
        }

        $actualCsv = Join-Path $work "$trace`_scenario_duration.csv"
        $actualTxt = Join-Path $work "$trace`_raw_metrics.txt"
        & dotnet $parser $etl $manifest $actualCsv --raw-metrics $actualTxt 2>$null | Out-Null

        foreach ($pair in @(
            @{ Actual = $actualCsv; Expected = Join-Path $root "validation\$trace`_scenario_duration.csv" },
            @{ Actual = $actualTxt; Expected = Join-Path $root "validation\$trace`_raw_metrics.txt" }
        )) {
            $name = Split-Path $pair.Expected -Leaf

            if ($Update) {
                Copy-Item $pair.Actual $pair.Expected -Force
                Write-Host "  UPDATED  $name" -ForegroundColor Cyan
                continue
            }

            if (-not (Test-Path $pair.Expected)) {
                Write-Host "  MISSING  $name (no expectation committed)" -ForegroundColor Yellow
                $failed += $name
                continue
            }

            $a = (Get-FileHash $pair.Actual -Algorithm SHA256).Hash
            $b = (Get-FileHash $pair.Expected -Algorithm SHA256).Hash
            if ($a -eq $b) {
                Write-Host "  PASS  $name" -ForegroundColor Green
            }
            else {
                Write-Host "  FAIL  $name" -ForegroundColor Red
                $failed += $name
                Compare-Object (Get-Content $pair.Expected) (Get-Content $pair.Actual) |
                    ForEach-Object {
                        $tag = if ($_.SideIndicator -eq '=>') { 'unexpected' } else { 'missing   ' }
                        Write-Host "          $tag $($_.InputObject)"
                    }
            }
        }
    }
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($Update) {
    Write-Host "`nExpectations updated. Review the diff before committing." -ForegroundColor Cyan
    exit 0
}

if ($failed.Count -gt 0) {
    Write-Host "`n$($failed.Count) output(s) drifted from expectations." -ForegroundColor Red
    exit 1
}

Write-Host "`nAll outputs match expectations." -ForegroundColor Green
exit 0
