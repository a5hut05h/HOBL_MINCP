@echo off
REM Copyright (c) Microsoft. All rights reserved.
REM Licensed under the MIT license. See LICENSE file in the project root for full license information.

SetLocal EnableDelayedExpansion

REM Set path to download supporting assets
set "DOWNLOADS=%~dp0..\..\downloads\setup\assets"
REM create downloads directory if it doesn't exist
if not exist "%DOWNLOADS%" (
    mkdir "%DOWNLOADS%"
)

REM Download powershell and dotnet runtime installers, then build dut_setup.exe with InnoSetup
REM Requirements: InnoSetup installed.

set RUNTIME_VERSION=8.0.29
set RUNTIME_X64_DOWNLOAD_URL="https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/%RUNTIME_VERSION%/windowsdesktop-runtime-%RUNTIME_VERSION%-win-x64.exe"
set RUNTIME_ARM64_DOWNLOAD_URL="https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/%RUNTIME_VERSION%/windowsdesktop-runtime-%RUNTIME_VERSION%-win-arm64.exe"

set POWERSHELL_VERSION=7.6.4
set POWERSHELL_X64_DOWNLOAD_URL="https://github.com/PowerShell/PowerShell/releases/download/v%POWERSHELL_VERSION%/PowerShell-%POWERSHELL_VERSION%-win-x64.msi"
set POWERSHELL_ARM64_DOWNLOAD_URL="https://github.com/PowerShell/PowerShell/releases/download/v%POWERSHELL_VERSION%/PowerShell-%POWERSHELL_VERSION%-win-arm64.msi"

set VC_REDIST_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"

REM Download Visual C++ Redistributable
if not exist "%DOWNLOADS%\vc_redist.x64.exe" (  
    echo Downloading vc_redist.x64.exe
    curl -L --output "%DOWNLOADS%\vc_redist.x64.exe" %VC_REDIST_URL%
    if %errorlevel% neq 0 goto ERROR
) else (
    echo vc_redist.x64.exe already exists, skipping download
)

REM Download .NET Windows Desktop Runtime installers
if not exist "%DOWNLOADS%\windowsdesktop-runtime-%RUNTIME_VERSION%-win-x64.exe" (
    echo Downloading windowsdesktop-runtime-%RUNTIME_VERSION%-win-x64.exe
    curl -L --output "%DOWNLOADS%\windowsdesktop-runtime-%RUNTIME_VERSION%-win-x64.exe" %RUNTIME_X64_DOWNLOAD_URL%
    if %errorlevel% neq 0 goto ERROR
) else (
    echo windowsdesktop-runtime-%RUNTIME_VERSION%-win-x64.exe already exists, skipping download
)

if not exist "%DOWNLOADS%\windowsdesktop-runtime-%RUNTIME_VERSION%-win-arm64.exe" (
    echo Downloading windowsdesktop-runtime-%RUNTIME_VERSION%-win-arm64.exe
    curl -L --output "%DOWNLOADS%\windowsdesktop-runtime-%RUNTIME_VERSION%-win-arm64.exe" %RUNTIME_ARM64_DOWNLOAD_URL%
    if %errorlevel% neq 0 goto ERROR
) else (
    echo windowsdesktop-runtime-%RUNTIME_VERSION%-win-arm64.exe already exists, skipping download
)

REM Download PowerShell installers
if not exist "%DOWNLOADS%\PowerShell-%POWERSHELL_VERSION%-win-x64.msi" (
    echo Downloading PowerShell-%POWERSHELL_VERSION%-win-x64.msi
    curl -L --output "%DOWNLOADS%\PowerShell-%POWERSHELL_VERSION%-win-x64.msi" %POWERSHELL_X64_DOWNLOAD_URL%
    if %errorlevel% neq 0 goto ERROR
) else (
    echo PowerShell-%POWERSHELL_VERSION%-win-x64.msi already exists, skipping download
)

if not exist "%DOWNLOADS%\PowerShell-%POWERSHELL_VERSION%-win-arm64.msi" (
    echo Downloading PowerShell-%POWERSHELL_VERSION%-win-arm64.msi
    curl -L --output "%DOWNLOADS%\PowerShell-%POWERSHELL_VERSION%-win-arm64.msi" %POWERSHELL_ARM64_DOWNLOAD_URL%
    if %errorlevel% neq 0 goto ERROR
) else (
    echo PowerShell-%POWERSHELL_VERSION%-win-arm64.msi already exists, skipping download
)

REM Build the installer using InnoSetup
echo Building dut_setup.exe with InnoSetup
"C:\Program Files\Inno Setup 7\ISCC.exe" dut_setup.iss
if %errorlevel% neq 0 goto ERROR

goto END

:ERROR
echo Error occurred, please check the output for details
exit /b 1

:END
exit /b 0
