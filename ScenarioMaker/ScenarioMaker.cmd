@echo off
pushd %~dp0
if exist ..\downloads\python_embed\python.exe (
    ..\downloads\python_embed\python.exe -s ScenarioMaker.pyw %*
) else (
    python ScenarioMaker.pyw %*
)
