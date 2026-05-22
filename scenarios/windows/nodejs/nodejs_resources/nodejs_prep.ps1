# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

param(
    [string]$logFile = ""
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
if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\nodejs_prep.log" }

# Require PowerShell > 7
$required = [version]"7.0"
if (-not $PSVersionTable.PSVersion) {
    Write-Host "Cannot determine PowerShell version; aborting." -ForegroundColor Red
    Exit 1
}
if ([version]$PSVersionTable.PSVersion -le $required) {
    Write-Host "This script requires PowerShell greater than $required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Yellow
    Write-Host "Please install PowerShell 7 or later from https://aka.ms/powershell" -ForegroundColor Yellow
    Exit 1
}

# Set execution policy for current process to allow script execution
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Check if log file directory exists
$logDirectory = Split-Path -Path $logFile -Parent
if (-not (Test-Path -Path $logDirectory)) {
    Write-Host "ERROR: Log directory does not exist: $logDirectory" -ForegroundColor Red
    Write-Host "Please create the directory before continuing." -ForegroundColor Yellow
    Exit 1
}

# Check if hobl_bin directory exists
if (-not (Test-Path -Path "$scriptDrive\hobl_bin")) {
    Write-Host "ERROR: $scriptDrive\hobl_bin directory does not exist" -ForegroundColor Red
    Write-Host "Please create the $scriptDrive\hobl_bin directory before continuing." -ForegroundColor Yellow
    Exit 1
}

# Check and set execution policy if needed
# This fixes the following error when running pyenv install.
# Microsoft.PowerShell.Archive\Expand-Archive : The module 'Microsoft.PowerShell.Archive' could not be loaded. For more
# information, run 'Import-Module Microsoft.PowerShell.Archive'.
$executionPolicy = Get-ExecutionPolicy -Scope Process
if ($executionPolicy -eq "Restricted" -or $executionPolicy -eq "Undefined") {
    Write-Host "Setting execution policy to Unrestricted for Process..." -ForegroundColor Yellow
    try {
        Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Force -ErrorAction Stop
        Write-Host "Execution policy set successfully" -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Failed to set execution policy" -ForegroundColor Red
        Write-Host "Please run as administrator or manually set execution policy with:" -ForegroundColor Yellow
        Write-Host "  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser" -ForegroundColor Cyan
        Exit 1
    }
}

# Determine processor architecture and set appropriate variables
$osInfo = Get-CimInstance Win32_OperatingSystem
$arch = $osInfo.OSArchitecture
$processorArch = $env:PROCESSOR_ARCHITECTURE

if ($arch -eq "64-bit" -and $processorArch -eq "AMD64") {
    $isARM64 = $false
    $vsArchParam = "x64"
    $vsHostArchParam = "x64"
    $logSuffix = "x64"
    $vsProduct = "BuildTools"
    $pythonVersion = "3.12.10"
} elseif ($arch -match "ARM" -or $processorArch -match "ARM") {
    $isARM64 = $true
    $vsArchParam = "arm64"
    $vsHostArchParam = "arm64"
    $logSuffix = "ARM64"
    $vsProduct = "Community"
    $pythonVersion = "3.12.10-arm"
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

function getVSVersion {
    param([string]$product)
    
    # vswhere.exe location is always in Program Files (x86) even on ARM64
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        # Fallback for ARM64 where installer might be in Program Files
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

# Visual Studio Build tools installation using direct installer download
# This is more reliable than winget for VS installations
# Visual Studio installation using direct installer download
# Architecture-aware: Build Tools for x64, Community for ARM64
function installVisualStudio {
    # Get the directory where the script is located
    $scriptDir = Split-Path -Parent $PSCommandPath
    
    if ($isARM64) {
        "-- Installing Visual Studio Community 2022 (direct installer for ARM64)" | log
        $installerUrl = "https://aka.ms/vs/17/release/vs_community.exe"
        $installerPath = "$env:TEMP\vs_community.exe"
        $productName = "VS Community"
        $vsconfigPath = Join-Path $scriptDir ".vsconfig_arm64"
    } else {
        "-- Installing Visual Studio Build Tools 2022 (direct installer for x64)" | log
        $installerUrl = "https://aka.ms/vs/17/release/vs_buildtools.exe"
        $installerPath = "$env:TEMP\vs_buildtools.exe"
        $productName = "VS Build Tools"
        $vsconfigPath = Join-Path $scriptDir ".vsconfig_x64"
    }
    
    # Verify .vsconfig file exists
    if (-not (Test-Path $vsconfigPath)) {
        " ERROR - .vsconfig file not found at: $vsconfigPath" | log
        return $false
    }
    
    "Using .vsconfig file: $vsconfigPath" | log
    
    # Check if VS is already installed by getting version info
    $existingVS = getVSVersion -product $vsProduct
    if ($existingVS -and $existingVS.Path) {
        # VS Installer is in a shared location, not in the product folder
        $sharedInstaller = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe"
        
        if (Test-Path $sharedInstaller) {
            "Found existing Visual Studio installer at: $sharedInstaller" | log
            "Using existing installer to apply .vsconfig (handles LTSC and version mismatches)" | log
            $installerPath = $sharedInstaller
        } else {
            "Existing VS installation found but no installer at expected location, downloading new installer..." | log
            
            try {
                Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
                "$productName installer downloaded successfully" | log
            } catch {
                " ERROR - Failed to download $productName installer: $($_.Exception.Message)" | log
                return $false
            }
            
            if (-not (Test-Path $installerPath)) {
                " ERROR - $productName installer not found after download" | log
                return $false
            }
        }
    } else {
        "No existing Visual Studio installation found, downloading new installer..." | log
        
        try {
            Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath
            "$productName installer downloaded successfully" | log
        } catch {
            " ERROR - Failed to download $productName installer: $($_.Exception.Message)" | log
            return $false
        }
        
        if (-not (Test-Path $installerPath)) {
            " ERROR - $productName installer not found after download" | log
            return $false
        }
    }
    
    # Create VS-specific log file path in same directory as main log
    $logDirectory = Split-Path -Path $logFile -Parent
    $vsLogFile = Join-Path $logDirectory "vs_install_$($logSuffix.ToLower()).log"
    "VS installer output will be logged to: $vsLogFile" | log
    
    if ($existingVS) {
        # Build modify arguments using .vsconfig file and install path
        $installArgs = @(
            "modify"
            "--installPath", "`"$($existingVS.Path)`""
            "--quiet"
            "--config", "`"$vsconfigPath`""
        )
        "Visual Studio Modify args: $($installArgs -join ' ')" | log
    } else {
        # Build install arguments using .vsconfig file
        $installArgs = @(
            "install"
            "--quiet"
            "--wait"
            "--config", "`"$vsconfigPath`""
        )
        "Visual Studio Install args: $($installArgs -join ' ')" | log
    }
    
    "Starting $productName installation (this will wait for completion)..." | log
    $vsStdOut = Join-Path $logDirectory "vs_install_nodejs_stdout_$($logSuffix.ToLower()).log"
    $vsStdErr = Join-Path $logDirectory "vs_install_nodejs_stderr_$($logSuffix.ToLower()).log"
    "VS installer stdout redirected to: $vsStdOut" | log
    "VS installer stderr redirected to: $vsStdErr" | log
    try {
        $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru -RedirectStandardOutput $vsStdOut -RedirectStandardError $vsStdErr
        $exitCode = $process.ExitCode
        
        "$productName installer completed with exit code: $exitCode" | log
        
        # VS installer exit codes:
        # 0 = Success
        # 3010 = Success but reboot required
        if ($exitCode -eq 0 -or $exitCode -eq 3010) {
            if ($exitCode -eq 3010) {
                "Installation successful but may require reboot for full functionality" | log
            }
            return $true
        } else {
            " ERROR - $productName installation failed with exit code: $exitCode" | log
            return $false
        }
    } catch {
        " ERROR - Failed to run $productName installer: $($_.Exception.Message)" | log
        return $false
    } finally {
        # Clean up downloaded installer (not existing installer)
        " Cleaning up installer file..." | log
        if ($installerPath -like "$env:TEMP\*" -and (Test-Path $installerPath)) {
            Remove-Item $installerPath -ErrorAction SilentlyContinue
        }
    }
}

function verifyVSInstallation {
    "Verifying Visual Studio $vsProduct installation..." | log
    
    # First, try to find VS using vswhere which handles non-default locations
    $vsInfo = getVSVersion -product $vsProduct
    
    if (-not $vsInfo -or -not $vsInfo.Path) {
        " ERROR - Visual Studio $vsProduct not found using vswhere" | log
        return $false
    }
    
    $actualVSPath = $vsInfo.Path
    "Found Visual Studio at: $actualVSPath" | log
    "Version: $($vsInfo.Version)" | log
    "Display Name: $($vsInfo.DisplayName)" | log
    
    # Use actual installation path for verification
    $vsPath = Join-Path $actualVSPath "Common7\Tools\VsDevCmd.bat"
    $msbuildPath = Join-Path $actualVSPath "MSBuild\Current\Bin\MSBuild.exe"
    $clPath = Join-Path $actualVSPath "VC\Tools\MSVC"
    
    $vsDevReady = Test-Path $vsPath
    $msbuildReady = Test-Path $msbuildPath  
    $vcToolsReady = Test-Path $clPath
    
    # Additional ARM64-specific verification
    $archSpecificReady = $true
    if ($isARM64) {
        $arm64ToolsReady = $false
        if (Test-Path $clPath) {
            $msvcVersions = Get-ChildItem $clPath -Directory
            foreach ($version in $msvcVersions) {
                $arm64CompilerPath = Join-Path $version.FullName "bin\Hostarm64\arm64\cl.exe"
                if (Test-Path $arm64CompilerPath) {
                    $arm64ToolsReady = $true
                    "Found ARM64 compiler at: $arm64CompilerPath" | log
                    break
                }
            }
        }
        $archSpecificReady = $arm64ToolsReady
        "VS Components Check - VsDevCmd: $vsDevReady, MSBuild: $msbuildReady, VCTools: $vcToolsReady, ARM64Tools: $arm64ToolsReady" | log
    } else {
        "VS Components Check - VsDevCmd: $vsDevReady, MSBuild: $msbuildReady, VCTools: $vcToolsReady" | log
    }
    
    if ($vsDevReady -and $msbuildReady -and $vcToolsReady -and $archSpecificReady) {
        "Visual Studio $vsProduct verification successful" | log
        return $true
    } else {
        " ERROR - Visual Studio $vsProduct verification failed - missing components" | log
        return $false
    }
}

function initializeVSEnvironment {
    "Initializing Visual Studio environment for build tools ($logSuffix)..." | log
    
    # Use vswhere to find actual VS installation path
    $vsInfo = getVSVersion -product $vsProduct
    
    if (-not $vsInfo -or -not $vsInfo.Path) {
        " ERROR - Visual Studio $vsProduct not found using vswhere" | log
        return $false
    }
    
    $actualVSPath = $vsInfo.Path
    "Using Visual Studio from: $actualVSPath" | log
    
    # Use actual installation path for VsDevCmd
    $vsDevCmd = Join-Path $actualVSPath "Common7\Tools\VsDevCmd.bat"
    
    if (-not (Test-Path $vsDevCmd)) {
        " ERROR - VsDevCmd.bat not found at expected location: $vsDevCmd" | log
        return $false
    }
    
    "Using VsDevCmd.bat from: $vsDevCmd" | log
    
    # Initialize VS environment with architecture-specific parameters
    $tempBat = "$env:TEMP\vsinit_$($logSuffix.ToLower()).bat"
    Set-Content -Path $tempBat -Value @"
@echo off
call "$vsDevCmd" -arch=$vsArchParam -host_arch=$vsHostArchParam > nul 2>&1
set
"@
    
    # Execute the batch file and capture environment variables
    $envVars = cmd /c "$tempBat" 2>nul
    Remove-Item $tempBat -ErrorAction SilentlyContinue
    
    # Parse and set environment variables
    $envVars | ForEach-Object {
        if ($_ -match "^([^=]+)=(.*)$") {
            $name = $matches[1]
            $value = $matches[2]
            
            # Set important VS-related environment variables
            if ($name -match "^(PATH|INCLUDE|LIB|LIBPATH|VS.*|VC.*|WindowsSDK.*|Platform.*|PROCESSOR_ARCHITECTURE)$") {
                Set-Item "env:$name" $value -ErrorAction SilentlyContinue
            }
        }
    }
    
    "Visual Studio environment initialized successfully for $logSuffix" | log
    return $true
}

Set-Content -Path $logFile -encoding utf8 "-- nodejs prep started"

"Detected architecture: $arch (Processor: $processorArch)" | log
"Using Visual Studio $vsProduct for $logSuffix" | log

# Check Visual Studio version before installation
"Checking Visual Studio version before installation..." | log
$vsBefore = getVSVersion -product $vsProduct
if ($vsBefore) {
    "Existing $vsProduct installation found:" | log
    "  Version: $($vsBefore.Version)" | log
    "  Display Name: $($vsBefore.DisplayName)" | log
    "  Path: $($vsBefore.Path)" | log
} else {
    "No existing $vsProduct installation found" | log
}

# Install Visual Studio using architecture-appropriate installer
if (-not (installVisualStudio)) {
    " ERROR - Visual Studio $vsProduct installation failed" | log
    Exit 1
}

# Check Visual Studio version after installation
"Checking Visual Studio version after installation..." | log
$vsAfter = getVSVersion -product $vsProduct
if ($vsAfter) {
    "Current $vsProduct installation:" | log
    "  Version: $($vsAfter.Version)" | log
    "  Display Name: $($vsAfter.DisplayName)" | log
    "  Path: $($vsAfter.Path)" | log
} else {
    " ERROR - $vsProduct not found after installation" | log
    Exit 1
}

# Verify installation completed properly
if (-not (verifyVSInstallation)) {
    " ERROR - Visual Studio $vsProduct verification failed" | log
    Exit 1
}

# Initialize VS environment for build tools
if (-not (initializeVSEnvironment)) {
    " ERROR - Failed to initialize Visual Studio environment" | log
    Exit 1
}

# "-- Installing git" | log
# winget install --id git.git

# Refresh environment variables after VS installation
"Refreshing environment variables after VS installation..." | log
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

Set-Location "$scriptDrive\hobl_bin"

# Clone Node.js version 25.0.0 with all submodules
# "Cloning Node.js v25.0.0 repository (this may take a few minutes)..." | log
# & git clone --depth 1 --branch v24.10.0 https://github.com/nodejs/node.git
# & git clone --depth 1 https://github.com/nodejs/node.git
# cd .\node
# git fetch --tags
# git checkout tags/v25.0.0 -b v25.0.0-branch
# git submodule update --init --depth 1 --recursive

# Download nodejs zipped source code
"-- Downloading git repo" | log
Set-Location "$scriptDrive\hobl_bin"
Invoke-WebRequest -Uri "https://github.com/nodejs/node/archive/refs/tags/v25.0.0.zip" -OutFile "./nodejs.zip" -UseBasicParsing

"-- Unzip Nodejs" | log
Set-Location "$scriptDrive\hobl_bin"
Expand-Archive -Path .\nodejs.zip -DestinationPath .\nodejs -Force


"-- Installing python environment" | log
Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1" -OutFile "./install-pyenv-win.ps1"; &"./install-pyenv-win.ps1"
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# --- Install Python via pyenv (conditional — DO NOT use -f) ---
# Force-reinstall (`-f`) wipes the pyenv version directory including any packages
# installed by other scenarios that share this Python version. We only install
# when the version is truly missing. Node.js only needs the interpreter (for
# node-gyp / vcbuild.bat) so no venv is required.
"-- Installing python $pythonVersion" | log
$installedVersions = (pyenv versions --bare 2>$null) -split "`n" | ForEach-Object { $_.Trim() }
if ($installedVersions -notcontains $pythonVersion) {
    "Installing Python $pythonVersion via pyenv..." | log
    pyenv install $pythonVersion
} else {
    "Python $pythonVersion already installed via pyenv — preserving existing install" | log
}
pyenv versions; pyenv global $pythonVersion; pyenv versions


"-- nodejs prep completed" | log
Exit 0