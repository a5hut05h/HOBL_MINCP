param([string]$ConfigPath = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')
try {
    $context = Get-HoblV3Config -ConfigPath $ConfigPath
    $errors = @(Test-HoblV3Config -Context $context)
    if ($errors.Count -gt 0) {
        foreach ($item in $errors) { Write-Host " ERROR - $item" -ForegroundColor Red }
        Exit 1
    }
    . (Join-Path $context.RepoRoot 'automation_v2\lib\testplan.ps1')
    foreach ($job in @($context.Config.jobs | Where-Object { $_.enabled })) {
        $testplan = [string]$job.testplan
        if (-not [System.IO.Path]::IsPathRooted($testplan)) { $testplan = Join-Path $context.RepoRoot $testplan }
        try {
            $parsed = ConvertFrom-HoblTestplan -Path $testplan
            if (@($parsed.Rows).Count -eq 0) { throw 'No HOBL scenario rows were parsed.' }
        } catch {
            Write-Host " ERROR - Job '$($job.id)' testplan is invalid: $($_.Exception.Message)" -ForegroundColor Red
            Exit 1
        }
    }
    Write-Host "Configuration is valid: $($context.ConfigPath)" -ForegroundColor Green
    Write-Host "Runtime root: $($context.RuntimeRoot)"
    Write-Host "Jobs: $(@($context.Config.jobs).Count)"
    Exit 0
} catch {
    Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}
