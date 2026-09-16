<#
.SYNOPSIS
    End-to-end script: scans a folder for .etl files, generates metadata,
    builds Fungates arguments, and uploads via CSEUploader.exe.
.DESCRIPTION
    Orchestrates the full Fungates upload workflow:
      1. Discovers .etl files in the input folder.
      2. Creates per-file metadata JSON (New-MetadataFile.ps1).
      3. Builds a ##-delimited args file (New-FungatesArgs.ps1).
      4. Invokes CSEUploader.exe with the args file.
.PARAMETER InputFolder
    Folder containing the .etl trace files to upload.
.PARAMETER CSEUploaderPath
    Full path to CSEUploader.exe. If omitted, auto-detected from
    Pipeline.Workspace/FungatesUploader install location.
.PARAMETER Delimiter
    Delimiter used between test entries in the args file. Default: ##
.PARAMETER DryRun
    When set, generates metadata and args but does NOT invoke CSEUploader.
.EXAMPLE
    # Upload all ETL files from a folder
    .\Upload-ToFungates.ps1 -InputFolder "C:\traces\wpr_logs"

    # Dry-run (prepare only, no upload)
    .\Upload-ToFungates.ps1 -InputFolder "C:\traces\wpr_logs" -DryRun
#>
param (
    [Parameter(Mandatory=$true)]
    [string]$InputFolder,

    [Parameter(Mandatory=$false)]
    [string]$CSEUploaderPath,

    [Parameter(Mandatory=$false)]
    [string]$Delimiter = "##",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

# ─── Validation ──────────────────────────────────────────────────────
if (-not (Test-Path $InputFolder)) {
    Write-Error "Input folder not found: $InputFolder"
    exit 1
}

# ─── Auto-detect CSEUploader ────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($CSEUploaderPath)) {
    $bundledPath = Join-Path $scriptDir "CSEUploader.exe"
    $defaultPath = "C:\Uploader\CSEUploader.exe"
    if (Test-Path $bundledPath) {
        $CSEUploaderPath = $bundledPath
    } elseif (Test-Path $defaultPath) {
        $CSEUploaderPath = $defaultPath
    } else {
        Write-Error "CSEUploader.exe not found alongside the script or at $defaultPath. Provide -CSEUploaderPath explicitly."
        exit 1
    }
}
if (-not (Test-Path $CSEUploaderPath)) {
    Write-Error "CSEUploader.exe not found at: $CSEUploaderPath"
    exit 1
}
Write-Host "Using CSEUploader: $CSEUploaderPath"

# ─── Auto-detect BuildPlatform ───────────────────────────────────────
$BuildPlatform = switch ($env:PROCESSOR_ARCHITECTURE) {
    "ARM64" { "ARM64" }
    "AMD64" { "x64" }
    "x86"   { "x86" }
    default { $env:PROCESSOR_ARCHITECTURE }
}
Write-Host "Detected platform: $BuildPlatform"

# ─── Step 1: Discover ETL files ─────────────────────────────────────
$etlFiles = Get-ChildItem -Path $InputFolder -Filter *.etl -ErrorAction SilentlyContinue
if (-not $etlFiles -or $etlFiles.Count -eq 0) {
    Write-Host "No .etl files found in $InputFolder. Nothing to upload."
    exit 0
}
Write-Host "Discovered $($etlFiles.Count) ETL file(s) in $InputFolder"

# ─── Step 2: Generate metadata for each ETL ─────────────────────────
$metadataScript = Join-Path $scriptDir "New-MetadataFile.ps1"
foreach ($etl in $etlFiles) {
    $testName = [System.IO.Path]::GetFileNameWithoutExtension($etl.Name)

    $metaParams = @{
        TraceFileName  = $etl.Name
        TestName       = $testName
        BuildPlatform  = $BuildPlatform
        OutputDirectory = $InputFolder
    }

    & $metadataScript @metaParams
}

# ─── Step 3: Build Fungates args file ───────────────────────────────
$argsScript = Join-Path $scriptDir "New-FungatesArgs.ps1"
$argsFile = & $argsScript -TraceDirectory $InputFolder

if (-not (Test-Path $argsFile)) {
    Write-Host "Args file was not created. Nothing to upload."
    exit 0
}
Write-Host "Args file ready: $argsFile"

# ─── Step 4: Upload via CSEUploader ─────────────────────────────────
$argsContent = Get-Content -Path $argsFile -Raw
$testEntries = $argsContent -split [regex]::Escape($Delimiter)

foreach ($entry in $testEntries) {
    $entry = $entry.Trim()
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }

    if ($DryRun) {
        Write-Host "[DRY RUN] Would invoke:"
        Write-Host "  CSEUploader.exe /TenantId:... /UseMIOnLabMachine:true $entry"
        continue
    }

    Write-Host "Invoking CSEUploader..."
    $cmdArgs = "/TenantId:`"72f988bf-86f1-41af-91ab-2d7cd011db47`" /UseMIOnLabMachine:`"true`" $entry"
    Write-Host "Arguments: $cmdArgs"
    Invoke-Expression "& `"$CSEUploaderPath`" $cmdArgs"
    $uploaderExitCode = $LASTEXITCODE

    if ($uploaderExitCode -ne 0) {
        Write-Error "CSEUploader exited with code $uploaderExitCode"
        exit $uploaderExitCode
    }
}

Write-Host "Fungates upload completed successfully."
