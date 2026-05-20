# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [string]$logFile = "",
    [string]$customResourcesPath = "",
    [switch]$useCustomPyTorchWheel = $false,
    [switch]$installCuda = $false,
    [switch]$installCudnn = $false
)

$scriptDrive = Split-Path -Qualifier $PSScriptRoot
if (-not (Test-Path "$scriptDrive\hobl_data")) {
    Write-Host " ERROR - Required directory not found: $scriptDrive\hobl_data" -ForegroundColor Red
    Exit 1
}
if (-not (Test-Path "$scriptDrive\hobl_bin")) {
    Write-Host " ERROR - Required directory not found: $scriptDrive\hobl_bin" -ForegroundColor Red
    Exit 1
}
if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\pytorch_inf_prep.log" }

# Set execution policy for current process (required for pyenv's Expand-Archive)
$executionPolicy = Get-ExecutionPolicy -Scope Process
if ($executionPolicy -eq "Restricted" -or $executionPolicy -eq "Undefined") {
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force -ErrorAction Stop
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Determine processor architecture
$osInfo = Get-CimInstance Win32_OperatingSystem
$arch = $osInfo.OSArchitecture
$processorArch = $env:PROCESSOR_ARCHITECTURE

if ($arch -eq "64-bit" -and $processorArch -eq "AMD64") {
    $isARM64 = $false
    if ($useCustomPyTorchWheel) {
        $logSuffix = "x64_Custom"
        $pythonVersion = "3.13.1"
        $vsProduct = "BuildTools"
    } else {
        $logSuffix = "x64"
        $pythonVersion = "3.12.10"
        $vsProduct = "BuildTools"
    }
} elseif ($arch -match "ARM" -or $processorArch -match "ARM") {
    $isARM64 = $true
    if ($useCustomPyTorchWheel) {
        $logSuffix = "ARM64_Custom"
        $pythonVersion = "3.13.1-arm"
        $vsProduct = "Community"
    } else {
        $logSuffix = "ARM64"
        $pythonVersion = "3.12.10-arm"
        $vsProduct = "Community"
    }
} else {
    Write-Host " ERROR - Unsupported architecture: $arch (Processor: $processorArch)" -ForegroundColor Red
    Add-Content -Path $logFile -encoding utf8 " ERROR - Unsupported architecture: $arch (Processor: $processorArch)"
    Exit 1
}

# Update log file name to include architecture
$logFile = $logFile -replace "\.log$", "_$($logSuffix.ToLower()).log"

function log {
    [CmdletBinding()] Param([Parameter(ValueFromPipeline)] $msg)
    process {
        if ($msg -Match " ERROR - ") {
            Write-Host $msg -ForegroundColor Red
        } else {
            Write-Host $msg
        }
        Add-Content -Path $logFile -encoding utf8 "$msg"
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

Set-Content -Path $logFile -encoding utf8 "-- pytorch_inf prep started ($logSuffix version)"
"Detected architecture: $arch (Processor: $processorArch)" | log

function getVSVersion {
    param([string]$product)

    # vswhere.exe location is always in Program Files (x86) even on Arm64
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        $vswhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
        if (-not (Test-Path $vswhere)) {
            return $null
        }
    }

    try {
        $productFilter = if ($product -eq "BuildTools") { "Microsoft.VisualStudio.Product.BuildTools" } else { "Microsoft.VisualStudio.Product.Community" }
        $instances = & $vswhere -products $productFilter -format json | ConvertFrom-Json

        if ($instances) {
            $instance = $instances | Select-Object -First 1
            return @{
                Version = $instance.installationVersion
                DisplayName = $instance.displayName
                Path = $instance.installationPath
            }
        }
    } catch {
        return $null
    }

    return $null
}

# Verify winget is available
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    " ERROR - winget is not available. Install App Installer from Microsoft Store or visit https://aka.ms/getwinget" | log
    Exit 1
}

# --- Arm64: Install Rust and VS for compiling native packages (safetensors) ---
# safetensors has no pre-built win_arm64 wheels, so we need to compile from source.
# Rust has no LTS — we pin a known stable version for reproducibility.
$rustVersion = "1.85.0"
if ($isARM64) {
    "-- Installing Rust toolchain $rustVersion (required for Arm64 native package compilation)" | log
    winget install --id Rustlang.Rustup --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        " ERROR - Rust installation failed with exit code: $LASTEXITCODE" | log
    } else {
        "Rustup installation completed" | log
    }
    # Refresh PATH so rustup is available
    $Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

    # Pin the specific Rust version
    "Pinning Rust to $rustVersion..." | log
    rustup default $rustVersion
    if ($LASTEXITCODE -ne 0) {
        "Installing Rust $rustVersion..." | log
        rustup toolchain install $rustVersion
        check($lastexitcode)
        rustup default $rustVersion
        check($lastexitcode)
    }
    "Rust version:" | log
    rustc --version | log

    # Install/update VS Community with Arm64 C++ workload (required for MSVC linker)
    "-- Installing Visual Studio Community 2022 (Arm64 C++ workload)" | log
    $scriptDir = Split-Path -Parent $PSCommandPath
    $vsconfigPath = Join-Path $scriptDir ".vsconfig_arm64"
    if (-not (Test-Path $vsconfigPath)) {
        " ERROR - .vsconfig_arm64 not found at: $vsconfigPath" | log
        Exit 1
    }
    "Using .vsconfig file: $vsconfigPath" | log

    $installerUrl = "https://aka.ms/vs/17/release/vs_community.exe"
    $installerPath = "$env:TEMP\vs_community.exe"
    $productName = "VS Community"

    # Check if VS is already installed using getVSVersion (per copilot-instructions)
    $existingVS = getVSVersion -product $vsProduct
    if ($existingVS -and $existingVS.Path) {
        "Existing $productName found at: $($existingVS.Path)" | log
        "Version: $($existingVS.Version)" | log
        "Display Name: $($existingVS.DisplayName)" | log

        # VS Installer is in a shared location, not in the product folder
        $sharedInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
        if (Test-Path $sharedInstaller) {
            "Found existing VS installer at: $sharedInstaller" | log
            "Using existing installer to apply .vsconfig (handles LTSC and version mismatches)" | log
            $installerPath = $sharedInstaller
        } else {
            "Existing VS found but no installer at expected location, downloading new installer..." | log
            try {
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
                "$productName installer downloaded successfully" | log
            } catch {
                " ERROR - Failed to download $productName installer: $($_.Exception.Message)" | log
                Exit 1
            }
            if (-not (Test-Path $installerPath)) {
                " ERROR - $productName installer not found after download" | log
                Exit 1
            }
        }
    } else {
        "No existing $productName installation found, downloading new installer..." | log
        try {
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
            "$productName installer downloaded successfully" | log
        } catch {
            " ERROR - Failed to download $productName installer: $($_.Exception.Message)" | log
            Exit 1
        }
        if (-not (Test-Path $installerPath)) {
            " ERROR - $productName installer not found after download" | log
            Exit 1
        }
    }

    if ($existingVS) {
        $installArgs = @(
            "modify"
            "--installPath", "`"$($existingVS.Path)`""
            "--quiet"
            "--config", "`"$vsconfigPath`""
        )
        "$productName Modify args: $($installArgs -join ' ')" | log
    } else {
        $installArgs = @(
            "install"
            "--quiet"
            "--wait"
            "--config", "`"$vsconfigPath`""
        )
        "$productName Install args: $($installArgs -join ' ')" | log
    }

    "Starting $productName installation (this will wait for completion)..." | log
    $logDirectory = Split-Path -Path $logFile -Parent
    $vsStdOut = Join-Path $logDirectory "vs_install_pytorch_stdout_$($logSuffix.ToLower()).log"
    $vsStdErr = Join-Path $logDirectory "vs_install_pytorch_stderr_$($logSuffix.ToLower()).log"
    "VS installer stdout redirected to: $vsStdOut" | log
    "VS installer stderr redirected to: $vsStdErr" | log
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru -RedirectStandardOutput $vsStdOut -RedirectStandardError $vsStdErr
        $exitCode = $process.ExitCode
        "$productName installer completed with exit code: $exitCode" | log

        # VS installer exit codes:
        # 0 = Success
        # 3010 = Success but reboot required
        # 1618 = Another installation is already in progress
        if ($exitCode -eq 0 -or $exitCode -eq 3010) {
            if ($exitCode -eq 3010) {
                "Installation successful but may require reboot for full functionality" | log
            }
        } elseif ($exitCode -eq 1618) {
            " ERROR - $productName installation failed with exit code: $exitCode" | log
            " ERROR - Exit code 1618 means another setup/installer is already running." | log
            " ERROR - Please close any other installation programs and try again." | log
            Exit 1
        } else {
            " ERROR - $productName installation failed with exit code: $exitCode" | log
            Exit 1
        }
    } catch {
        " ERROR - Failed to run $productName installer: $($_.Exception.Message)" | log
        Exit 1
    } finally {
        # Clean up downloaded installer (not shared installer)
        " Cleaning up installer file..." | log
        if ($installerPath -like "$env:TEMP\*" -and (Test-Path $installerPath)) {
            Remove-Item $installerPath -ErrorAction SilentlyContinue
        }
    }

    # Refresh PATH after VS install
    $Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# --- Install CUDA Toolkit (when -installCuda is specified) ---
if ($installCuda) {
    "-- Installing CUDA Toolkit" | log
    if (-not $customResourcesPath -or -not (Test-Path $customResourcesPath)) {
        " ERROR - Custom resources path required for CUDA install: $customResourcesPath" | log
        Exit 1
    }
    $cudaExe = Get-ChildItem -Path $customResourcesPath -Filter "cuda_*.exe" | Select-Object -First 1
    if ($cudaExe) {
        "Found CUDA Toolkit installer: $($cudaExe.Name)" | log
        "Installing CUDA Toolkit (silent, this may take several minutes)..." | log
        $cudaProcess = Start-Process -FilePath $cudaExe.FullName -ArgumentList "/s" -Wait -PassThru
        if ($cudaProcess.ExitCode -ne 0) {
            " ERROR - CUDA Toolkit installation failed with exit code: $($cudaProcess.ExitCode)" | log
            Exit 1
        }
        "CUDA Toolkit installed successfully" | log

        # Refresh PATH so nvcc is available
        $Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    } else {
        " ERROR - No cuda_*.exe found in: $customResourcesPath" | log
        Exit 1
    }

    # Verify nvcc is available
    $nvccVersion = nvcc --version 2>&1
    if ($LASTEXITCODE -eq 0) {
        "nvcc verified: $($nvccVersion | Select-Object -Last 1)" | log
    } else {
        " ERROR - nvcc not found after CUDA Toolkit install. Check that CUDA bin is in PATH." | log
        Exit 1
    }

    # Ensure CUDA_PATH is set for this session
    if (-not $env:CUDA_PATH) {
        $env:CUDA_PATH = [System.Environment]::GetEnvironmentVariable("CUDA_PATH", "Machine")
    }
    if ($env:CUDA_PATH) {
        "CUDA_PATH: $env:CUDA_PATH" | log
    } else {
        "WARNING: CUDA_PATH not set. torch.cuda.is_available() may return False." | log
    }
}

# --- Install cuDNN (when -installCudnn is specified) ---
if ($installCudnn) {
    "-- Installing cuDNN" | log
    if (-not $customResourcesPath -or -not (Test-Path $customResourcesPath)) {
        " ERROR - Custom resources path required for cuDNN install: $customResourcesPath" | log
        Exit 1
    }
    $cudnnExe = Get-ChildItem -Path $customResourcesPath -Filter "cudnn*.exe" | Select-Object -First 1
    if ($cudnnExe) {
        "Found cuDNN installer: $($cudnnExe.Name)" | log
        "Installing cuDNN (silent)..." | log
        $cudnnProcess = Start-Process -FilePath $cudnnExe.FullName -ArgumentList "/s" -Wait -PassThru
        if ($cudnnProcess.ExitCode -ne 0) {
            " ERROR - cuDNN installation failed with exit code: $($cudnnProcess.ExitCode)" | log
            Exit 1
        }
        "cuDNN installed successfully" | log
    } else {
        " ERROR - No cudnn*.exe found in: $customResourcesPath" | log
        Exit 1
    }
}

# --- Install pyenv-win ---
"-- Installing python environment" | log
"Installing pyenv-win for Python version management..." | log
try {
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1" -OutFile "./install-pyenv-win.ps1"
    & "./install-pyenv-win.ps1"
    "pyenv-win installation completed" | log
} catch {
    " ERROR - Failed to install pyenv-win: $($_.Exception.Message)" | log
    Exit 1
}

# --- Optimize PATH: pyenv shims before WindowsApps ---
"Optimizing Python PATH priority permanently..." | log

$pyenvPaths = @(
    "$env:USERPROFILE\.pyenv\pyenv-win\shims",
    "$env:USERPROFILE\.pyenv\pyenv-win\bin"
)

function Set-OptimizedPathOrder {
    "=== Optimizing PATH Permanently ===" | log

    function Normalize-PathEntry {
        param([string]$Entry)
        if (-not $Entry) { return $null }
        $value = $Entry.Trim().Trim('"')
        if (-not $value) { return $null }
        if ($value.Length -gt 3 -and $value.EndsWith("\")) {
            $value = $value.TrimEnd("\\")
        }
        return $value
    }

    function Get-PathEntries {
        param([string]$PathValue)
        $entries = New-Object System.Collections.Generic.List[string]
        if (-not $PathValue) { return $entries }
        foreach ($segment in ($PathValue -split ';')) {
            $normalized = Normalize-PathEntry -Entry $segment
            if ($normalized) {
                $entries.Add($normalized)
            }
        }
        return $entries
    }

    function Add-UniquePathEntry {
        param(
            [System.Collections.Generic.List[string]]$List,
            [hashtable]$Seen,
            [string]$Entry
        )
        $normalized = Normalize-PathEntry -Entry $Entry
        if (-not $normalized) { return }
        $key = $normalized.ToLowerInvariant()
        if (-not $Seen.ContainsKey($key)) {
            $List.Add($normalized)
            $Seen[$key] = $true
        }
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

    $currentUserPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    "Original User PATH length: $($currentUserPath.Length) characters" | log

    $windowsAppsCanonical = Normalize-PathEntry -Entry "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    $windowsAppsCanonicalKey = $windowsAppsCanonical.ToLowerInvariant()
    $windowsAppsEnvKey = "%localappdata%\microsoft\windowsapps"

    $pyenvPathKeys = @{}
    foreach ($pyenvPath in $pyenvPaths) {
        $normalizedPyenv = Normalize-PathEntry -Entry $pyenvPath
        if ($normalizedPyenv) {
            $pyenvPathKeys[$normalizedPyenv.ToLowerInvariant()] = $true
        }
    }

    $userEntries = Get-PathEntries -PathValue $currentUserPath
    $cleanUserEntries = New-Object System.Collections.Generic.List[string]
    $cleanUserSeen = @{}
    $hadWindowsAppsInUserPath = $false

    foreach ($entry in $userEntries) {
        $entryKey = $entry.ToLowerInvariant()
        if ($entryKey -eq $windowsAppsCanonicalKey -or $entryKey -eq $windowsAppsEnvKey) {
            $hadWindowsAppsInUserPath = $true
            continue
        }
        if ($pyenvPathKeys.ContainsKey($entryKey)) {
            "Removing existing pyenv path: $entry" | log
            continue
        }
        Add-UniquePathEntry -List $cleanUserEntries -Seen $cleanUserSeen -Entry $entry
    }

    $newUserEntries = New-Object System.Collections.Generic.List[string]
    $newUserSeen = @{}

    foreach ($pyenvPath in $pyenvPaths) {
        Add-UniquePathEntry -List $newUserEntries -Seen $newUserSeen -Entry $pyenvPath
    }
    foreach ($entry in $cleanUserEntries) {
        Add-UniquePathEntry -List $newUserEntries -Seen $newUserSeen -Entry $entry
    }
    if ($hadWindowsAppsInUserPath -or (Test-Path $windowsAppsCanonical)) {
        Add-UniquePathEntry -List $newUserEntries -Seen $newUserSeen -Entry $windowsAppsCanonical
    }

    $newUserPath = ($newUserEntries -join ';')

    try {
        "Updating User PATH permanently..." | log
        [System.Environment]::SetEnvironmentVariable('PATH', $newUserPath, 'User')
        "New User PATH length: $($newUserPath.Length) characters" | log

        if ($isAdmin) {
            "Running as Administrator - also updating Machine PATH" | log
            $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
            $machineEntries = Get-PathEntries -PathValue $machinePath
            $cleanMachineEntries = New-Object System.Collections.Generic.List[string]
            $cleanMachineSeen = @{}

            foreach ($entry in $machineEntries) {
                if ($pyenvPathKeys.ContainsKey($entry.ToLowerInvariant())) { continue }
                Add-UniquePathEntry -List $cleanMachineEntries -Seen $cleanMachineSeen -Entry $entry
            }

            $newMachineEntries = New-Object System.Collections.Generic.List[string]
            $newMachineSeen = @{}
            foreach ($pyenvPath in $pyenvPaths) {
                Add-UniquePathEntry -List $newMachineEntries -Seen $newMachineSeen -Entry $pyenvPath
            }
            foreach ($entry in $cleanMachineEntries) {
                Add-UniquePathEntry -List $newMachineEntries -Seen $newMachineSeen -Entry $entry
            }

            $newMachinePath = ($newMachineEntries -join ';')
            "Updating Machine PATH permanently..." | log
            [System.Environment]::SetEnvironmentVariable('PATH', $newMachinePath, 'Machine')
        }

        $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
        $env:PATH = $machinePath + ";" + $newUserPath

        "PATH optimization complete!" | log
        "pyenv paths have FIRST priority" | log
        if ($hadWindowsAppsInUserPath -or (Test-Path $windowsAppsCanonical)) {
            "Windows Store Python moved to LAST priority" | log
        }
    } catch {
        " ERROR - Failed to update PATH: $($_.Exception.Message)" | log
        Exit 1
    }
}

Set-OptimizedPathOrder

# --- Install Python via pyenv ---
"-- Installing python $pythonVersion for $logSuffix" | log
"Installing Python $pythonVersion (this may take several minutes)..." | log
pyenv install $pythonVersion -f
check($lastexitcode)

"Setting Python $pythonVersion as global version..." | log
pyenv global $pythonVersion
check($lastexitcode)

# --- Verify Python installation ---
function Find-AllPython {
    "=== Python Detection Report ===" | log
    "`n1. Python in PATH:" | log
    try {
        $pathPython = Get-Command python -ErrorAction SilentlyContinue
        if ($pathPython) {
            "  Found: $($pathPython.Source)" | log
            & python --version 2>&1 | log
        } else {
            "  No python in PATH" | log
        }
    } catch {
        "  No python in PATH" | log
    }
    "`n2. pyenv-win managed Python:" | log
    if (Get-Command pyenv -ErrorAction SilentlyContinue) {
        "  pyenv is available" | log
        pyenv versions | log
    } else {
        "  pyenv not found" | log
    }
}

Find-AllPython

"`n=== Python Resolution Verification ===" | log
$whichPython = Get-Command python -ErrorAction SilentlyContinue
if ($whichPython) {
    "Resolved python.exe: $($whichPython.Source)" | log
    if ($whichPython.Source -like "*pyenv*") {
        "SUCCESS: pyenv Python is being used" | log
    } else {
        "WARNING: Non-pyenv Python is being used" | log
        "This may cause version conflicts" | log
    }
} else {
    " ERROR - No python found in PATH" | log
    Exit 1
}

"Verifying Python installation..." | log
pyenv versions | log

# --- Copy resources (always overwrite to pick up script changes) ---
"-- Setting up pytorch_inf_resources in $scriptDrive\hobl_bin\pytorch_inf_resources" | log
if ($PSScriptRoot -ne "$scriptDrive\hobl_bin\pytorch_inf_resources") {
    if (-not (Test-Path "$scriptDrive\hobl_bin\pytorch_inf_resources")) {
        New-Item -ItemType Directory -Force -Path "$scriptDrive\hobl_bin\pytorch_inf_resources" | Out-Null
    }
    Copy-Item -Path "$PSScriptRoot\*" -Destination "$scriptDrive\hobl_bin\pytorch_inf_resources" -Exclude "*.ps1" -Recurse -Force
    "Resources copied from $PSScriptRoot" | log
} else {
    "Already running from target directory, skipping copy" | log
}

Set-Location "$scriptDrive\hobl_bin\pytorch_inf_resources"
checkCmd($?)

# --- Install Python packages ---
$currentPythonVersion = & python --version 2>&1
"Current Python version: $currentPythonVersion" | log

$expectedVersionPattern = $pythonVersion -replace "-arm", ""
if ($currentPythonVersion -like "*$expectedVersionPattern*") {
    "Correct Python version ($pythonVersion) is active" | log
} else {
    " ERROR - Wrong Python version active. Expected: $pythonVersion, Got: $currentPythonVersion" | log
    Exit 1
}

if ($useCustomPyTorchWheel) {
    # --- Custom wheel path: install custom PyTorch wheel + remaining deps ---
    "-- Installing PyTorch from custom wheel" | log
    if (-not $customResourcesPath -or -not (Test-Path $customResourcesPath)) {
        " ERROR - Custom resources path required for custom wheel install: $customResourcesPath" | log
        Exit 1
    }
    $wheelFile = Get-ChildItem -Path $customResourcesPath -Filter "torch-*.whl" | Select-Object -First 1
    if (-not $wheelFile) {
        " ERROR - No torch-*.whl found in: $customResourcesPath" | log
        " ERROR - No matching custom PyTorch wheel found." | log
        Exit 1
    }
    "Found wheel: $($wheelFile.Name) ($([math]::Round($wheelFile.Length / 1MB, 1)) MB)" | log
    pip install $wheelFile.FullName
    check($lastexitcode)
    "-- Installing remaining dependencies from requirements_custom.txt" | log
    pip install -r requirements_custom.txt
    check($lastexitcode)
} else {
    # --- Standard path: x64 (cu128) or Arm64 CPU ---
    $requirementsFile = if ($isARM64) { "requirements_win_arm64.txt" } else { "requirements_win.txt" }
    "-- Installing Python packages from $requirementsFile" | log
    pip install -r $requirementsFile
    check($lastexitcode)
}

# --- Download model ---
"-- Setup LLM Phi-4-mini inferencing" | log
python inference.py --setup
check($lastexitcode)

"-- pytorch_inf prep completed ($logSuffix version)" | log
Exit 0