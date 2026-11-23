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
        & dotnet $parser $etl $manifest $actualCsv --raw-metrics $actualTxt
        if ($LASTEXITCODE -ne 0) {
            throw " ERROR - Parser failed for $trace."
        }

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

    $fixtureRows = @(Import-Csv (Join-Path $root 'validation\consumer_multitasker_021_raw_metrics.txt'))
    $fixtureTrace = Join-Path $root 'validation\consumer_multitasker_021.etl'
    $customMappings = Join-Path $work 'custom.csv'
    @(
        'PT_ID,Display_Name,Drop_InputInject'
        '8998,"Startup, ""Mapped""",false'
        'PT_9471,Shared,TRUE'
        '9412,Shared,true'
        '8805,Word_Boot,'
    ) | Set-Content -LiteralPath $customMappings
    Import-Csv $customMappings | Select-Object PT_ID, Display_Name |
        Export-Csv (Join-Path $work 'legacy.csv') -NoTypeInformation

    foreach ($case in @('custom', 'legacy', 'missing')) {
        $mappingPath = Join-Path $work "$case.csv"
        $actualCsv = Join-Path $work "$case-summary.csv"
        $actualRaw = Join-Path $work "$case-raw.txt"
        $warningsPath = Join-Path $work "$case-stderr.txt"
        & dotnet $parser $fixtureTrace $manifest $actualCsv --pt-mappings $mappingPath --raw-metrics $actualRaw 2> $warningsPath | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw " ERROR - Parser failed for mapping test '$case': $(Get-Content $warningsPath -Raw)"
        }

        $names = if ($case -ne 'missing') {
            @{ PT_8998 = 'Startup, "Mapped"'; PT_9471 = 'Shared'; PT_9412 = 'Shared'; PT_8805 = 'Word_Boot' }
        } else { @{} }
        $actualRows = @(Import-Csv $actualCsv -Header Name, Duration)
        if ($actualRows.Count -ne $fixtureRows.Count) {
            throw " ERROR - Mapping test '$case' changed the row count."
        }

        $occurrences = @{}
        for ($i = 0; $i -lt $fixtureRows.Count; $i++) {
            $row = $fixtureRows[$i]
            $name = if ($names.ContainsKey($row.PT_ID)) { $names[$row.PT_ID] } else { $row.'Scenario Name' }
            $tag = $row.'Corresponding Input Inject Event'
            $dropTag = $case -eq 'custom' -and $row.PT_ID -in @('PT_9471', 'PT_9412')
            $key = if ($tag -and -not $dropTag) { "Perftrack_$($tag)_$name" } else { "Perftrack_$name" }
            $count = if ($occurrences.ContainsKey($key)) { $occurrences[$key] } else { 0 }
            $occurrences[$key] = $count + 1
            $expectedName = if ($count -eq 0) { $key } else { "$($key)_$count" }
            if ($actualRows[$i].Name -cne $expectedName -or $actualRows[$i].Duration -cne $row.DurationMs) {
                throw " ERROR - Mapping test '$case' produced an incorrect name or duration at row $i."
            }
        }

        $warningLines = @(Get-Content $warningsPath)
        foreach ($id in @($fixtureRows.PT_ID | Sort-Object -Unique)) {
            $warningCount = @($warningLines | Where-Object { $_ -like "[[]WARN] No Display_Name mapping for $id.*" }).Count
            $expectedCount = if ($names.ContainsKey($id)) { 0 } else { 1 }
            if ($warningCount -ne $expectedCount) {
                throw " ERROR - Mapping test '$case' did not warn exactly once for missing mapping $id."
            }
        }
        if ($case -eq 'missing' -and -not ($warningLines -like '[[]WARN] PT mapping file not found:*')) {
            throw ' ERROR - Missing mapping file did not produce a warning.'
        }
        $referenceRaw = Join-Path $root 'validation\consumer_multitasker_021_raw_metrics.txt'
        if ((Get-FileHash $actualRaw).Hash -ne (Get-FileHash $referenceRaw).Hash) {
            throw " ERROR - Mapping test '$case' changed raw metrics."
        }
        Write-Host "  PASS  $case mapping, InputInject labels, fallback warnings, CSV escaping, unique keys, and unchanged raw metrics" -ForegroundColor Green
    }

    $invalidMappings = Join-Path $work 'invalid.csv'
    "PT_ID,Display_Name`n8998,First`nPT_8998,Duplicate" | Set-Content -LiteralPath $invalidMappings
    & dotnet $parser $fixtureTrace $manifest --pt-mappings $invalidMappings 2> (Join-Path $work 'invalid-stderr.txt') | Out-Null
    if ($LASTEXITCODE -eq 0 -or -not ((Get-Content (Join-Path $work 'invalid-stderr.txt') -Raw) -match 'Duplicate PT_ID')) {
        throw ' ERROR - Duplicate PT IDs were not rejected.'
    }
    "PT_ID,Display_Name,Drop_InputInject`n8998,Startup,invalid" | Set-Content -LiteralPath $invalidMappings
    & dotnet $parser $fixtureTrace $manifest --pt-mappings $invalidMappings 2> (Join-Path $work 'invalid-flag-stderr.txt') | Out-Null
    if ($LASTEXITCODE -eq 0 -or -not ((Get-Content (Join-Path $work 'invalid-flag-stderr.txt') -Raw) -match 'Invalid Drop_InputInject')) {
        throw ' ERROR - Invalid Drop_InputInject was not rejected.'
    }
    & dotnet $parser --pt-mappings 2> (Join-Path $work 'usage-stderr.txt') | Out-Null
    if ($LASTEXITCODE -eq 0 -or -not ((Get-Content (Join-Path $work 'usage-stderr.txt') -Raw) -match 'requires a path')) {
        throw ' ERROR - Missing --pt-mappings value was not rejected.'
    }
    Write-Host '  PASS  invalid mappings and missing mapping argument rejected' -ForegroundColor Green
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
