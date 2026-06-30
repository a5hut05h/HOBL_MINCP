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
    [string]$MemorySizeGB = "",

    [Parameter(Mandatory=$false)]
    [string]$UsableRamConfigGB = "",

    [Parameter(Mandatory=$false)]
    [string]$HostName = "",

    [Parameter(Mandatory=$false)]
    [string]$DutType = "",

    [Parameter(Mandatory=$false)]
    [string]$CpuMfg = "",

    [Parameter(Mandatory=$false)]
    [string]$OsBuild = "",

    [Parameter(Mandatory=$false)]
    [string]$BatteryCapacityWh = "",

    [Parameter(Mandatory=$false)]
    [string]$HWVersion = "",

    [Parameter(Mandatory=$false)]
    [string]$LKG = "",

    [Parameter(Mandatory=$false)]
    [string]$ScenarioName = "",

    [Parameter(Mandatory=$false)]
    [string]$TestRunId = "",

    [Parameter(Mandatory=$false)]
    [string]$IterationNumber = ""

)

# Strip a trailing "_<number>" suffix (e.g. "mincp_base_014" -> "mincp_base") from the
# test name so every iteration of a scenario shares one logical TestName in Fungates
# instead of producing a separate dropdown entry per run. The stripped run number is
# preserved and emitted separately as the IterationNumber metadata field.
if ($TestName -match '_(\d+)$') {
    if ([string]::IsNullOrWhiteSpace($IterationNumber)) {
        $IterationNumber = ([int]$matches[1]).ToString()
    }
    $TestName = $TestName -replace '_\d+$', ''
}

# Generate a unique TestRunId (GUID) when one is not supplied. Because the numeric
# suffix is removed from TestName, all iterations would otherwise collide under the
# same TestName; a fresh TestRunId keeps each upload distinct in Fungates.
if ([string]::IsNullOrWhiteSpace($TestRunId)) {
    $TestRunId = [guid]::NewGuid().ToString()
}

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


# Resolve DeviceName, MemorySizeGB, UsableRamConfigGB, and ScenarioName used to
# build the TierDefinitionKey. Preference order for each value:
#   1. Caller-supplied parameter
#   2. hobl_result.json in the run/output directory (authoritative; written by the
#      extractor immediately before upload)
#   3. The DUT's Config.csv in the run/output directory
#   4. Host fallback (DeviceName) / derived from TestName (ScenarioName)

# --- (2) hobl_result.json ---
$resultJson = Join-Path -Path $OutputDirectory -ChildPath "hobl_result.json"
if (Test-Path $resultJson) {
    try {
        $result = Get-Content -Path $resultJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $deviceConfig = $result.device_config
        $runInfo = $result.run_info
        if ([string]::IsNullOrWhiteSpace($DeviceName) -and $deviceConfig.device_name) {
            $DeviceName = [string]$deviceConfig.device_name
        }
        if ([string]::IsNullOrWhiteSpace($MemorySizeGB) -and $deviceConfig.memory_size_gb) {
            $MemorySizeGB = [string]$deviceConfig.memory_size_gb
        }
        if ([string]::IsNullOrWhiteSpace($UsableRamConfigGB) -and $deviceConfig.usable_ram_config_gb) {
            $UsableRamConfigGB = [string]$deviceConfig.usable_ram_config_gb
        }
        if ([string]::IsNullOrWhiteSpace($HostName) -and $runInfo.HostName) {
            $HostName = [string]$runInfo.HostName
        }
        if ([string]::IsNullOrWhiteSpace($DutType) -and $deviceConfig.dut_type) {
            $DutType = [string]$deviceConfig.dut_type
        }
        if ([string]::IsNullOrWhiteSpace($CpuMfg) -and $deviceConfig.cpu_mfg) {
            $CpuMfg = [string]$deviceConfig.cpu_mfg
        }
        if ([string]::IsNullOrWhiteSpace($OsBuild) -and $deviceConfig.os_build) {
            $OsBuild = [string]$deviceConfig.os_build
        }
        if ([string]::IsNullOrWhiteSpace($BatteryCapacityWh) -and $deviceConfig.battery_capacity_wh) {
            $BatteryCapacityWh = [string]$deviceConfig.battery_capacity_wh
        }
        if ([string]::IsNullOrWhiteSpace($HWVersion) -and $deviceConfig.HWVersion) {
            $HWVersion = [string]$deviceConfig.HWVersion
        }
        if ([string]::IsNullOrWhiteSpace($LKG) -and $deviceConfig.LKG) {
            $LKG = [string]$deviceConfig.LKG
        }
        if ([string]::IsNullOrWhiteSpace($ScenarioName)) {
            if ($runInfo.scenario) {
                $ScenarioName = [string]$runInfo.scenario
            } elseif ($runInfo.test_name) {
                $ScenarioName = [string]$runInfo.test_name
            }
        }
    } catch {
        Write-Host " ERROR - Failed to read DUT fields from $resultJson : $_"
    }
}

# --- (3) Config.csv ---
if ([string]::IsNullOrWhiteSpace($DeviceName) -or [string]::IsNullOrWhiteSpace($MemorySizeGB) -or [string]::IsNullOrWhiteSpace($UsableRamConfigGB)) {
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
                elseif ([string]::IsNullOrWhiteSpace($UsableRamConfigGB) -and $key -eq "Usable RAM (GB)") {
                    $UsableRamConfigGB = $value
                }
                elseif ([string]::IsNullOrWhiteSpace($DutType) -and $key -eq "DUT Type") {
                    $DutType = $value
                }
                elseif ([string]::IsNullOrWhiteSpace($CpuMfg) -and $key -eq "CPU Mfg") {
                    $CpuMfg = $value
                }
                elseif ([string]::IsNullOrWhiteSpace($OsBuild) -and $key -eq "OS Build") {
                    $OsBuild = $value
                }
                elseif ([string]::IsNullOrWhiteSpace($BatteryCapacityWh) -and $key -eq "Battery Total Designed Capacity (Wh)") {
                    $BatteryCapacityWh = $value
                }
                elseif ([string]::IsNullOrWhiteSpace($HWVersion) -and $key -eq "Hardware Version") {
                    $HWVersion = $value
                }
                elseif ([string]::IsNullOrWhiteSpace($LKG) -and $key -eq "Boot Image Version") {
                    $LKG = $value
                }
            }
        } catch {
            Write-Host " ERROR - Failed to read DUT fields from $configCsv : $_"
        }
    } else {
        Write-Host " ERROR - Config.csv not found in $OutputDirectory; falling back to host name for DeviceName"
    }
}

# --- (4) Fallbacks ---
if ([string]::IsNullOrWhiteSpace($DeviceName)) {
    $DeviceName = $computerInfo.CsName
    if ([string]::IsNullOrWhiteSpace($DeviceName)) {
        $DeviceName = $env:COMPUTERNAME
    }
}
if ([string]::IsNullOrWhiteSpace($HostName)) {
    $HostName = $computerInfo.CsName
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        $HostName = $env:COMPUTERNAME
    }
}
# Derive the scenario name from the test name when no explicit value is available.
# Mirrors the extractor's logic of stripping a trailing "_<runNumber>" suffix
# (e.g. "youtube_040" -> "youtube").
if ([string]::IsNullOrWhiteSpace($ScenarioName)) {
    $ScenarioName = $TestName -replace '_\d+$', ''
}

# Generate TierDefinitionKey: <DeviceName>_<UsableRamConfigGB>_<ScenarioName>
# All three values are resolved above (hobl_result.json -> Config.csv -> fallbacks).
# Using the usable RAM config (rather than total memory size) separates runs of the
# same DUT at different RAM configurations, and the scenario name separates runs of
# different scenarios.
if ([string]::IsNullOrWhiteSpace($TierDefinitionKey)) {
    # Replace whitespace in device name so the key has no spaces.
    $deviceToken = ($DeviceName -replace '\s+', '_').Trim('_')
    $tierTokens = @($deviceToken)

    # Prefer the usable RAM config; fall back to total memory size if unavailable.
    $ramSource = $UsableRamConfigGB
    if ([string]::IsNullOrWhiteSpace($ramSource)) { $ramSource = $MemorySizeGB }
    if ([string]::IsNullOrWhiteSpace($ramSource)) {
        Write-Host " ERROR - Usable RAM (GB)/Memory Size (GB) not found; TierDefinitionKey will omit RAM config"
    } else {
        $tierTokens += ($ramSource -replace '\s+', '').Trim()
    }

    # Replace whitespace in scenario name so the key has no spaces.
    $scenarioToken = ($ScenarioName -replace '\s+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($scenarioToken)) {
        Write-Host " ERROR - Scenario name not found; TierDefinitionKey will omit scenario"
    } else {
        $tierTokens += $scenarioToken
    }

    $TierDefinitionKey = ($tierTokens -join "_")
}

$metadata = @{
    TraceFileName      = $TraceFileName.Trim()
    RoutingTag         = $RoutingTag.Trim()
    TestName           = $TestName.Trim()
    GateName           = $GateName.Trim()
    IterationsPerRun   = $IterationsPerRun.Trim()
    Iteration          = $Iteration.Trim()
    IterationNumber    = $IterationNumber.Trim()
    TierDefinitionKey  = $TierDefinitionKey.Trim()
    BuildNum           = $BuildNum.Trim()
    BuildLab           = $BuildLab.Trim()
    IsOfficial         = $IsOfficial
    TestRunIdSource    = $TestRunIdSource.Trim()
    TestRunId          = $TestRunId.Trim()
    RunDate            = $runDate.Trim()
    BuildSku           = $BuildSku.Trim()
    Edition            = $Edition.Trim()
    BuildDate          = $BuildDate.Trim()
    EnableFileCompression = "true"
    MachineMake        = $MachineMake.Trim()
    MachineModel       = $MachineModel.Trim()
    hostname              = $HostName.Trim()
    DeviceName            = $DeviceName.Trim()
    DUTType               = $DutType.Trim()
    UsableRam          = $UsableRamConfigGB.Trim()
    DefaultRam            = $MemorySizeGB.Trim()
    IHV               = $CpuMfg.Trim()
    OSBuild              = $OsBuild.Trim()
    BatteryCapacity_wh   = $BatteryCapacityWh.Trim()
    HWVersion             = $HWVersion.Trim()
    LKG                   = $LKG.Trim()
    PushMetadataToKusto   = "true"
}

New-Item -Path $metadataFilePath -ItemType File -Force | Out-Null
Set-Content -Path $metadataFilePath -Value ($metadata | ConvertTo-Json -Depth 3) -Force
Write-Host "Metadata file created at: $metadataFilePath"

return $metadataFilePath
