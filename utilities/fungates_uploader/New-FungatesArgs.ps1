<#
.SYNOPSIS
    Builds a Fungates argument file from ETL files and their metadata JSONs.
.DESCRIPTION
    Scans a trace directory for .etl files, pairs each with its metadata JSON,
    organises files into per-test folders, merges custom CSVs, and writes
    a ##-delimited args file consumed by CSEUploader.exe.
.PARAMETER TraceDirectory
    Root folder containing the .etl files and their companion .json metadata.
.PARAMETER ArgsFilePath
    Output path for the generated args file. Defaults to <TraceDirectory>\fungates_args.txt.
.EXAMPLE
    .\New-FungatesArgs.ps1 -TraceDirectory "C:\traces\wpr_logs"
#>
param (
    [Parameter(Mandatory=$true)]
    [string]$TraceDirectory,

    [Parameter(Mandatory=$false)]
    [string]$ArgsFilePath
)

if (-not (Test-Path $TraceDirectory)) {
    Write-Host "Trace directory not found: $TraceDirectory. Skipping."
    exit 0
}

# Default args file path
if ([string]::IsNullOrWhiteSpace($ArgsFilePath)) {
    $ArgsFilePath = Join-Path $TraceDirectory "fungates_args.txt"
}
New-Item -ItemType File -Path $ArgsFilePath -Force | Out-Null

# Collect ETL files
$etlFiles = Get-ChildItem -Path $TraceDirectory -Filter *.etl -Recurse -ErrorAction SilentlyContinue
if (-not $etlFiles) {
    Write-Host "No ETL files found in $TraceDirectory. Skipping."
    exit 0
}
Write-Host "Found $($etlFiles.Count) ETL file(s)."

$argLines = @()
$processedCount = 0

foreach ($etl in $etlFiles) {
    $arg = ""
    $testName = [System.IO.Path]::GetFileNameWithoutExtension($etl.Name)
    $json     = "$($etl.FullName).json"

    if (-not (Test-Path $json)) {
        Write-Host "Skipping ETL (no metadata): $($etl.Name)"
        continue
    }

    # Create per-test folder and move artefacts into it
    $testDir = Join-Path $TraceDirectory $testName
    New-Item -ItemType Directory -Path $testDir -Force | Out-Null

    Move-Item -Path $etl.FullName -Destination (Join-Path $testDir "trace.etl") -Force

    # Read metadata JSON (but do not move it into the test folder)
    $meta = Get-Content -Path $json -Raw | ConvertFrom-Json
    Remove-Item -Path $json -Force

    # Copy custom.csv if present in the trace directory
    $customCsv = Join-Path $TraceDirectory "custom.csv"
    if (Test-Path $customCsv) {
        Copy-Item -Path $customCsv -Destination (Join-Path $testDir "custom.csv") -Force
        $arg += "/HasCustomMetricSource:`"true`" "
        $arg += "/TestResultBlobName:`"custom.csv`" "
    }

    # Copy hobl_result.json if present in the trace directory
    $hoblResult = Join-Path $TraceDirectory "hobl_result.json"
    if (Test-Path $hoblResult) {
        Copy-Item -Path $hoblResult -Destination (Join-Path $testDir "hobl_result.json") -Force
        Write-Host "Copied hobl_result.json for test: $testName"
    }

    # Convert each metadata property to a CSEUploader argument
    $meta.PSObject.Properties | ForEach-Object {
        if ($_.Name -notin @('workload','timestamp','MetricsSummary') -and $_.Name -notlike '*internal*') {
            $arg += "/$($_.Name):`"$($_.Value)`" "
        }
    }
    $arg += "/ResultPath:`"$testDir`"" 

    $argLines += $arg.TrimEnd()
    Write-Host "Prepared test: $testName"
    $processedCount++
}

# Write args file with ## delimiter
if ($processedCount -gt 0) {
    ($argLines -join "##") | Set-Content -Path $ArgsFilePath -Encoding utf8
    Write-Host "Created args file with $processedCount entries: $ArgsFilePath"
} else {
    Write-Host "No valid ETL + metadata pairs found. Nothing to upload."
    exit 0
}

return $ArgsFilePath
