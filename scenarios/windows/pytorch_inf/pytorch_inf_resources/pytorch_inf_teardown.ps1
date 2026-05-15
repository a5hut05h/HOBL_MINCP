# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# param(
#     [string]$logFile = "c:\hobl_data\pytorch_inf_prep.log"
# )

$scriptDrive = Split-Path -Qualifier $PSScriptRoot

function log {
    [CmdletBinding()] Param([Parameter(ValueFromPipeline)] $msg)
    process {
        if ($msg -Match " ERROR - ") {
            Write-Host $msg -ForegroundColor Red
        } else {
            Write-Host $msg
        }
        # Add-Content -Path $logFile -encoding utf8 "$msg"
    }
}

function check {
    param($code)
    if ($code -ne 0) {
        " ERROR - Last command failed." | log
        Exit $code
    }
}

function checkCmd {
    param($code)
    if ($code -ne "True") {
        " ERROR - Last command failed." | log
        Exit 1
    }
}

# Set-Content -Path $logFile -encoding utf8 "-- pytorch_inf prep started"
"-- pytorch_inf teardown started" | log

# Determine processor architecture for pyenv Python version
$osInfo = Get-CimInstance Win32_OperatingSystem
$arch = $osInfo.OSArchitecture
$processorArch = $env:PROCESSOR_ARCHITECTURE

if ($arch -eq "64-bit" -and $processorArch -eq "AMD64") {
    # Detect whether the custom wheel path was used during prep by checking the active pyenv version
    $activeVersion = (pyenv version 2>$null) -replace '\s.*', ''
    if ($activeVersion -match "^3\.13") {
        $pythonVersion = $activeVersion
    } else {
        $pythonVersion = "3.12.10"
    }
} elseif ($arch -match "ARM" -or $processorArch -match "ARM") {
    # Detect whether the custom wheel path was used during prep by checking the active pyenv version
    $activeVersion = (pyenv version 2>$null) -replace '\s.*', ''
    if ($activeVersion -match "^3\.13") {
        $pythonVersion = $activeVersion
    } else {
        $pythonVersion = "3.12.10-arm"
    }
} else {
    " ERROR - Unsupported architecture: $arch (Processor: $processorArch)" | log
    Exit 1
}

# --- Ensure CUDA paths are in session PATH if available ---
if ($env:CUDA_PATH -and (Test-Path $env:CUDA_PATH)) {
    $cudaBin = Join-Path $env:CUDA_PATH "bin"
    $cuptiLib = Join-Path $env:CUDA_PATH "extras\CUPTI\lib64"
    if ($env:PATH -notlike "*$cudaBin*") {
        $env:PATH = "$cudaBin;$env:PATH"
    }
    if ((Test-Path $cuptiLib) -and $env:PATH -notlike "*$cuptiLib*") {
        $env:PATH = "$cuptiLib;$env:PATH"
    }
}

# Ensure pyenv shims are in PATH for this session
$pyenvShims = "$env:USERPROFILE\.pyenv\pyenv-win\shims"
$pyenvBin = "$env:USERPROFILE\.pyenv\pyenv-win\bin"
if ($env:PATH -notlike "*$pyenvShims*") {
    $env:PATH = "$pyenvShims;$pyenvBin;$env:PATH"
}

"Setting Python global version to $pythonVersion..." | log
pyenv global $pythonVersion
check($lastexitcode)

"-- CD to resources" | log
Set-Location "$scriptDrive\hobl_bin\pytorch_inf_resources"
checkCmd($?)

"-- Cleanup GPU caching" | log
python inference.py --cleanup-gpu
check($lastexitcode)

"-- pytorch_inf teardown completed" | log
Exit 0