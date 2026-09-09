# tools\dump_plan.ps1
#
# Diagnostic helper for HOBL automation v2. Captures the JSON shape of an
# existing HOBLweb plan so you can compare it against what
# lib\testplan.ps1 produces. Use this if /plan/Create starts rejecting
# rows built from a testplan, to see what field names HOBLweb actually
# expects.
#
# Usage (from the automation_v2 folder):
#   powershell -ExecutionPolicy Bypass -File tools\dump_plan.ps1 -PlanID 31
#   powershell -ExecutionPolicy Bypass -File tools\dump_plan.ps1 -PlanID 31 -BaseUrl http://otherhost
#
# Writes the dump next to this script as plan_<PlanID>.dump.json.

param(
    [Parameter(Mandatory)] [int]    $PlanID,
    [string]                        $BaseUrl = "http://localhost",
    [string]                        $OutFile = ""
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

. (Join-Path (Split-Path -Parent $PSScriptRoot) "lib\submit.ps1")

if (-not $OutFile) {
    $OutFile = Join-Path $PSScriptRoot "plan_$PlanID.dump.json"
}

Write-Host "Fetching PlanID=$PlanID from $BaseUrl ..."
$rows = Get-HoblPlanContent -BaseUrl $BaseUrl -PlanID $PlanID
$rows | ConvertTo-Json -Depth 20 | Set-Content -Path $OutFile -Encoding utf8

Write-Host "Wrote $OutFile"
Write-Host "Compare its row shape against ConvertFrom-HoblTestplan output;"
Write-Host "if field names differ, update lib\testplan.ps1 accordingly."
