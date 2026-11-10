param(
    [Parameter(Mandatory)] [string] $StartDate,
    [Parameter(Mandatory)] [string] $EndDate,
    [string] $ConfigPath = '',
    [string] $OutputRoot = '',
    [switch] $Open
)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\common.ps1')

function ConvertTo-ReportDate {
    param([Parameter(Mandatory)] [string] $Value, [Parameter(Mandatory)] [string] $Name)
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
        $Value,
        'yyyy-MM-dd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsed)) {
        throw "$Name must use yyyy-MM-dd format."
    }
    return $parsed.Date
}

try {
    $start = ConvertTo-ReportDate -Value $StartDate -Name 'StartDate'
    $end = ConvertTo-ReportDate -Value $EndDate -Name 'EndDate'
    if ($end -lt $start) { throw 'EndDate must be on or after StartDate.' }
    if (($end - $start).Days -ne 6 -or $start.DayOfWeek -ne 'Monday' -or $end.DayOfWeek -ne 'Sunday') {
        throw 'StartDate and EndDate must define one Monday-through-Sunday week.'
    }

    $context = Get-HoblV3Config -ConfigPath $ConfigPath
    $sourceRoot = Join-Path $context.RuntimeRoot 'jobs'
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "V3 job results directory not found: $sourceRoot"
    }

    if (-not $OutputRoot) { $OutputRoot = Join-Path $context.RuntimeRoot 'local_snapshot' }
    if (-not [IO.Path]::IsPathRooted($OutputRoot)) { $OutputRoot = Join-Path $context.RuntimeRoot $OutputRoot }
    $OutputRoot = [IO.Path]::GetFullPath($OutputRoot)

    . (Join-Path $context.RepoRoot 'automation_v2\lib\report.ps1')

    $files = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Filter 'daily_report_*.jsonl' -File)) {
        if ($file.BaseName -notmatch '^daily_report_(\d{4}-\d{2}-\d{2})$') { continue }
        $fileDate = ConvertTo-ReportDate -Value $Matches[1] -Name 'ledger date'
        if ($fileDate -ge $start -and $fileDate -le $end) { $files += $file }
    }
    if ($files.Count -eq 0) {
        throw "No daily report ledgers found from $($start.ToString('yyyy-MM-dd')) through $($end.ToString('yyyy-MM-dd'))."
    }

    $entries = @{}
    foreach ($file in $files) {
        foreach ($line in @(Get-Content -LiteralPath $file.FullName -Encoding UTF8)) {
            if (-not $line.Trim()) { continue }
            $entry = $line | ConvertFrom-Json
            $key = if ([string]$entry.type -eq 'scenario') {
                "scenario|$($entry.planId)|$($entry.scenarioId)"
            } else {
                "plan|$($entry.planId)"
            }
            $previous = $entries[$key]
            if (-not $previous -or [datetime]$entry.recordedAt -ge [datetime]$previous.recordedAt) {
                $entries[$key] = $entry
            }
        }
    }

    $paths = Get-HoblReportPaths -ReportDir $OutputRoot -Date $start -Frequency Weekly
    if (-not (Test-Path -LiteralPath $paths.Dir)) {
        New-Item -ItemType Directory -Path $paths.Dir -Force | Out-Null
    }
    $encoding = New-Object Text.UTF8Encoding($false)
    $writer = New-Object IO.StreamWriter($paths.Ledger, $false, $encoding)
    try {
        foreach ($entry in $entries.Values) {
            $writer.WriteLine(($entry | ConvertTo-Json -Depth 8 -Compress))
        }
    } finally {
        $writer.Dispose()
    }

    $html = Write-HoblReportHtml -ReportDir $OutputRoot -Date $start -Frequency Weekly
    $scenarios = @($entries.Values | Where-Object { $_.type -eq 'scenario' -and -not $_.isPrep })
    Write-Host "Weekly report written: $html" -ForegroundColor Green
    Write-Host "Range: $($start.ToString('yyyy-MM-dd')) through $($end.ToString('yyyy-MM-dd'))"
    Write-Host "Source ledgers: $($files.Count); scenarios: $($scenarios.Count); passed: $(@($scenarios | Where-Object status -in @('PASS','PASSED')).Count); failed: $(@($scenarios | Where-Object status -in @('FAIL','FAILED','ERROR','ERRORED')).Count); terminated: $(@($scenarios | Where-Object status -in @('TERMINATED','CANCELLED','ABORTED','STOPPED')).Count)"
    if ($Open) { Invoke-Item -LiteralPath $html }
} catch {
    Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}
