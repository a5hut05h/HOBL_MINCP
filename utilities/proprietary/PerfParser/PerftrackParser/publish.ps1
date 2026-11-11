[CmdletBinding()]
param(
    [string]$OutputRoot = (Join-Path $PSScriptRoot 'artifacts\publish')
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'PerfParser.csproj'
$runtimeIdentifiers = @('win-x64', 'win-arm64')

foreach ($runtimeIdentifier in $runtimeIdentifiers) {
    $destination = Join-Path $OutputRoot $runtimeIdentifier
    if (Test-Path -LiteralPath $destination) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }

    dotnet publish $project `
        --configuration Release `
        --runtime $runtimeIdentifier `
        --self-contained false `
        --property:PublishSingleFile=true `
        --property:IncludeNativeLibrariesForSelfExtract=true `
        --property:IncludeAllContentForSelfExtract=true `
        --output $destination `
        --nologo

    if ($LASTEXITCODE -ne 0) {
        Write-Host " ERROR - Failed to publish PerfParser for $runtimeIdentifier." -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

Write-Host "Published PerfParser to $OutputRoot"
