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
if (-not $logFile) { $logFile = "$scriptDrive\hobl_data\opencv_prep.log" }

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Determine processor architecture and set appropriate variables
$osInfo = Get-CimInstance Win32_OperatingSystem
$arch = $osInfo.OSArchitecture
$processorArch = $env:PROCESSOR_ARCHITECTURE

if ($arch -eq "64-bit" -and $processorArch -eq "AMD64") {
    $isARM64 = $false
    $vsArchParam = "x64"
    $vsHostArchParam = "x64"
    $logSuffix = "x64"
    $vsInstallPath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022"
    $vsProduct = "BuildTools"
} elseif ($arch -match "ARM" -or $processorArch -match "ARM") {
    $isARM64 = $true
    $vsArchParam = "arm64"
    $vsHostArchParam = "arm64"
    $logSuffix = "ARM64"
    $vsInstallPath = "${env:ProgramFiles}\Microsoft Visual Studio\2022"
    $vsProduct = "Community"
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

function checkWinget {
    param($code)
    # Winget exit codes:
    # 0 = Success
    # -1978335189 (0x8A15002B) = Already installed
    # -1978335215 (0x8A150011) = No applicable upgrade found
    # Other non-zero = Actual error
    if ($code -eq 0) {
        "Winget command succeeded" | log
    } elseif ($code -eq -1978335189) {
        "Package already installed (this is OK)" | log
    } elseif ($code -eq -1978335215) {
        "No applicable upgrade found (this is OK)" | log
    } else {
        " ERROR - Winget command failed with exit code: $code" | log
        Exit $code
    }
}

function checkGitClone {
    param($code, $repoPath)
    # Git clone exit codes:
    # 0 = Success
    # 128 = Usually means directory already exists or other repository error
    if ($code -eq 0) {
        "Git clone succeeded" | log
    } elseif ($code -eq 128 -and (Test-Path $repoPath)) {
        "Repository already exists (this is OK)" | log
    } else {
        " ERROR - Git clone failed with exit code: $code" | log
        Exit $code
    }
}

function checkSetLocation {
    param($path)
    if (Test-Path $path) {
        Set-Location $path
        "Changed directory to: $path" | log
    } else {
        " ERROR - Directory does not exist: $path" | log
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
    $logDirectory = Split-Path -Path $logFile -Parent
    $vsStdOut = Join-Path $logDirectory "vs_install_opencv_build_stdout_$($logSuffix.ToLower()).log"
    $vsStdErr = Join-Path $logDirectory "vs_install_opencv_build_stderr_$($logSuffix.ToLower()).log"
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
function diagnoseVSInstallation {
    "=== Diagnosing Visual Studio Installation for CMake ($logSuffix) ===" | log
    
    # Check vswhere.exe
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        "vswhere.exe found, checking installed instances:" | log
        try {
            $instances = & $vswhere -format json | ConvertFrom-Json
            foreach ($instance in $instances) {
                "  - $($instance.displayName) v$($instance.installationVersion) at $($instance.installationPath)" | log
            }
        } catch {
            "Could not parse vswhere output: $($_.Exception.Message)" | log
        }
    } else {
        " ERROR - vswhere.exe not found - this is required for CMake VS detection" | log
    }
    
    # Check VS environment variables
    $vsComnTools = $env:VS170COMNTOOLS
    if ($vsComnTools) {
        "VS170COMNTOOLS found: $vsComnTools" | log
    } else {
        "VS170COMNTOOLS environment variable not set" | log
    }
    
    # Check for architecture-specific VS components
    $vsDevCmdPath = "$vsInstallPath\$vsProduct\Common7\Tools\VsDevCmd.bat"
    if (Test-Path $vsDevCmdPath) {
        "Found VsDevCmd.bat at: $vsDevCmdPath" | log
    }
    
    # Check processor architecture
    "Processor Architecture: $processorArch" | log
    "OS Architecture: $arch" | log
    "Target Architecture: $logSuffix" | log
    
    "=== End VS Diagnosis ===" | log
}

function initializeVSEnvironment {
    "Initializing Visual Studio environment for CMake ($logSuffix)..." | log
    
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

Set-Content -Path $logFile -encoding utf8 "-- opencv prep started ($logSuffix version)"

"Detected architecture: $arch (Processor: $processorArch)" | log
"Using Visual Studio $vsProduct for $logSuffix" | log

# --- Remove the msstore source before any winget install so a broken pinned
# certificate on that source cannot fail the command (winget 0x8a15005e /
# -1978335138) behind an SSL-inspecting proxy. All needed packages are on 'winget'. ---
try {
    if ((winget source list 2>$null) -match "msstore") {
        "Removing msstore winget source to avoid pinned-certificate failures (0x8a15005e)" | log
        winget source remove msstore 2>&1 | log
    }
} catch {
    "Could not remove msstore source (continuing): $($_.Exception.Message)" | log
}

"-- Installing git" | log
winget install --id git.git --source winget --accept-source-agreements --accept-package-agreements
checkWinget($lastexitcode)
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

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

# Diagnose VS installation for CMake
diagnoseVSInstallation

# Initialize VS environment to ensure CMake can find it
if (-not (initializeVSEnvironment)) {
    " ERROR - Failed to initialize Visual Studio environment" | log
    Exit 1
}

# Refresh environment variables after VS installation - CRITICAL for CMake detection
"Refreshing environment variables after VS installation..." | log
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Refresh all VS-related environment variables
$vsEnvVars = @("VS170COMNTOOLS", "VSINSTALLDIR", "VCINSTALLDIR", "WindowsSDKDir", "WindowsSDKVersion")
foreach ($varName in $vsEnvVars) {
    $value = [System.Environment]::GetEnvironmentVariable($varName, "Machine")
    if ($value) {
        Set-Item "env:$varName" $value
        "$varName set to: $value" | log
    }
}

# Force refresh of process environment from registry
try {
    # Signal that environment changed to all windows
    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1a
    $null = Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public class Win32 {
            [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
            public static extern IntPtr SendMessageTimeout(
                IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
                uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
        }
"@
    $result = [UIntPtr]::Zero
    [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result)
    "Environment change notification sent" | log
} catch {
    "Could not send environment change notification: $($_.Exception.Message)" | log
}
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

"-- Installing CMake 4.1.1" | log
winget install --id KitWare.CMake --version 4.1.1 --source winget --accept-source-agreements --accept-package-agreements
checkWinget($lastexitcode)

"Refreshing environment variables after cmake installation..." | log
$Env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

"-- Cloning git repo" | log
checkSetLocation "$scriptDrive\"
git clone https://github.com/opencv/opencv.git
checkGitClone $lastexitcode "$scriptDrive\opencv"

"-- Checkout" | log
checkSetLocation "$scriptDrive\opencv"
git checkout tags/4.10.0
check($lastexitcode)

"-- Configure" | log
New-Item -ItemType Directory -Path "$scriptDrive\opencv\build_msvc" -Force | Out-Null
checkSetLocation "$scriptDrive\opencv\build_msvc"

# Define CMake arguments as a hashtable
$cmakeArgs = @(
    "-S", ".."
    "-B", "."
    "-G", "Visual Studio 17 2022"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DBUILD_opencv_world=ON"
    "-DWITH_ITT=OFF"
    "-DWITH_OPENCL=OFF"
    "-DWITH_OPENCLAMDBLAS=OFF"
    "-DWITH_OPENCLAMDFFT=OFF"
    "-DWITH_OPENCL_D3D11_NV=OFF"
    "-DWITH_DIRECTML=OFF"
    "-DWITH_DIRECTX=OFF"
    "-DWITH_ADE=OFF"
    "-DWITH_CAROTENE=OFF"
    "-DBUILD_opencv_python2=OFF"
    "-DBUILD_opencv_python3=OFF"
    "-DWITH_PYTHON=OFF"
    "-DBUILD_opencv_python_bindings_generator=OFF"
    "-DBUILD_opencv_python_tests=OFF"
    "-DOPENCV_SKIP_PYTHON_LOADER=ON"
    "-DOPENCV_PYTHON_SKIP_DETECTION=ON"
    "-DBUILD_PERF_TESTS=OFF"
    "-DBUILD_TESTS=OFF"
    "-DPYTHON_EXECUTABLE="
    "-DPYTHON3_EXECUTABLE="
    "-DPYTHON2_EXECUTABLE="
)

"Running cmake to generate VS Project..." | log
# Configure OpenCV project
cmake @cmakeArgs
check($lastexitcode)

"-- opencv prep completed ($logSuffix version)" | log
Exit 0