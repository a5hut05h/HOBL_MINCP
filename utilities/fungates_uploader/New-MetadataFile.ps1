<#
.SYNOPSIS
    Creates a metadata JSON file for a given ETL trace file.
.DESCRIPTION
    Generates metadata required by Fungates/CSEUploader for each ETL file.
    Derives IHV, TierDefinitionKey, and machine info.
.PARAMETER TraceFileName
    Name of the ETL file (e.g., test_as_dll_memory.etl).
.PARAMETER TestName
    Logical test name derived from the ETL file name.
.PARAMETER BuildPlatform
    Target architecture (e.g., ARM64, x64). Auto-detected from system if not provided.
.PARAMETER OutputDirectory
    Directory where the metadata JSON will be written.
.EXAMPLE
    .\New-MetadataFile.ps1 -TraceFileName "test_as_dll_memory.etl" -TestName "test_as_dll_memory" `
        -OutputDirectory "C:\traces"
#>
param (
    [Parameter(Mandatory=$true)]
    [string]$TraceFileName,

    [Parameter(Mandatory=$true)]
    [string]$TestName,

    [Parameter(Mandatory=$false)]
    [string]$BuildPlatform,

    [Parameter(Mandatory=$true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory=$false)]
    [string]$BuildNum,

    [Parameter(Mandatory=$false)]
    [string]$BuildDate,

    [Parameter(Mandatory=$false)]
    [string]$TierDefinitionKey,

    [Parameter(Mandatory=$false)]
    [string]$RoutingTag = "winperf",

    [Parameter(Mandatory=$false)]
    [string]$GateName = "Hobl",

    [Parameter(Mandatory=$false)]
    [string]$IterationsPerRun = "1",

    [Parameter(Mandatory=$false)]
    [string]$Iteration = "1",

    [Parameter(Mandatory=$false)]
    [string]$BuildLab,

    [Parameter(Mandatory=$false)]
    [string]$IsOfficial = "1",

    [Parameter(Mandatory=$false)]
    [string]$TestRunIdSource = "Hobl",

    [Parameter(Mandatory=$false)]
    [string]$BuildSku = "Enterprise",

    [Parameter(Mandatory=$false)]
    [string]$Edition = "Enterprise",

    [Parameter(Mandatory=$false)]
    [string]$MachineMake = "",

    [Parameter(Mandatory=$false)]
    [string]$MachineModel = ""

)

Write-Host "Creating metadata file for $TraceFileName"
Write-Host "Output directory: $OutputDirectory"

$metadataFileName = "$($TraceFileName).json"
$metadataFilePath = Join-Path -Path $OutputDirectory -ChildPath $metadataFileName
$runDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"


# Get computer info for BuildLab, MachineMake, MachineModel
$computerInfo = Get-ComputerInfo
if ([string]::IsNullOrWhiteSpace($BuildLab)) {
    $BuildLab = ($computerInfo.WindowsBuildLabEx).Split(".")[3]
}
if ([string]::IsNullOrWhiteSpace($MachineMake)) {
    $MachineMake = $computerInfo.CsManufacturer
}
if ([string]::IsNullOrWhiteSpace($MachineModel)) {
    $MachineModel = $computerInfo.CsModel
}

if ([string]::IsNullOrWhiteSpace($BuildNum)) {
    $BuildNum = (Get-Date).ToString("yMMddHH")
}
if ([string]::IsNullOrWhiteSpace($BuildDate)) {
    $BuildDate = $runDate
}


# Generate TierDefinitionKey
if ([string]::IsNullOrWhiteSpace($TierDefinitionKey)) {
    $TierDefinitionKey = "${GateName}"
}

$metadata = @{
    TraceFileName      = $TraceFileName.Trim()
    RoutingTag         = $RoutingTag.Trim()
    TestName           = $TestName.Trim()
    GateName           = $GateName.Trim()
    IterationsPerRun   = $IterationsPerRun.Trim()
    Iteration          = $Iteration.Trim()
    TierDefinitionKey  = $TierDefinitionKey.Trim()
    BuildNum           = $BuildNum.Trim()
    BuildLab           = $BuildLab.Trim()
    IsOfficial         = $IsOfficial
    TestRunIdSource    = $TestRunIdSource.Trim()
    RunDate            = $runDate.Trim()
    BuildSku           = $BuildSku.Trim()
    Edition            = $Edition.Trim()
    BuildDate          = $BuildDate.Trim()
    EnableFileCompression = "true"
    MachineMake        = $MachineMake.Trim()
    MachineModel       = $MachineModel.Trim()
}

New-Item -Path $metadataFilePath -ItemType File -Force | Out-Null
Set-Content -Path $metadataFilePath -Value ($metadata | ConvertTo-Json -Depth 3) -Force
Write-Host "Metadata file created at: $metadataFilePath"

return $metadataFilePath
