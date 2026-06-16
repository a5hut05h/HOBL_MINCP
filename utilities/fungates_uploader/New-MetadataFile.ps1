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
    [string]$RoutingTag = "hobl",

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
    [string]$MachineModel = "",

    [Parameter(Mandatory=$false)]
    [string]$DeviceName = "",

    [Parameter(Mandatory=$false)]
    [string]$MemorySizeGB = ""

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


# Resolve DeviceName and MemorySizeGB: prefer caller-supplied values, otherwise
# read "Device Name" and "Memory Size (GB)" from the DUT's Config.csv in the
# run/output directory. Fall back to the host computer name only if Config.csv
# is missing or unreadable.
if ([string]::IsNullOrWhiteSpace($DeviceName) -or [string]::IsNullOrWhiteSpace($MemorySizeGB)) {
    $configCsv = Join-Path -Path $OutputDirectory -ChildPath "Config.csv"
    if (Test-Path $configCsv) {
        try {
            foreach ($line in Get-Content -Path $configCsv -Encoding UTF8) {
                $parts = $line -split ",", 2
                if ($parts.Count -lt 2) { continue }
                $key = $parts[0].Trim()
                $value = $parts[1].Trim()
                if ([string]::IsNullOrWhiteSpace($DeviceName) -and $key -eq "Device Name") {
                    $DeviceName = $value
                }
                elseif ([string]::IsNullOrWhiteSpace($MemorySizeGB) -and $key -eq "Memory Size (GB)") {
                    $MemorySizeGB = $value
                }
            }
        } catch {
            Write-Host " ERROR - Failed to read DUT fields from $configCsv : $_"
        }
    } else {
        Write-Host " ERROR - Config.csv not found in $OutputDirectory; falling back to host name for DeviceName"
    }

    if ([string]::IsNullOrWhiteSpace($DeviceName)) {
        $DeviceName = $computerInfo.CsName
        if ([string]::IsNullOrWhiteSpace($DeviceName)) {
            $DeviceName = $env:COMPUTERNAME
        }
    }
}

# Generate TierDefinitionKey: <DeviceName>_<MemorySizeGB>
# Both values come from the DUT's Config.csv (resolved above). Using memory
# size instead of scenario name keeps the tier count bounded per device while
# still separating runs that use different RAM configurations.
if ([string]::IsNullOrWhiteSpace($TierDefinitionKey)) {
    # Replace whitespace in device name so the key has no spaces.
    $deviceToken = ($DeviceName -replace '\s+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($MemorySizeGB)) {
        Write-Host " ERROR - Memory Size (GB) not found in Config.csv; TierDefinitionKey will omit memory size"
        $TierDefinitionKey = $deviceToken
    } else {
        $memoryToken = ($MemorySizeGB -replace '\s+', '').Trim()
        $TierDefinitionKey = "{0}_{1}" -f $deviceToken, $memoryToken
    }
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
