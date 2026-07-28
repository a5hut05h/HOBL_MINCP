# MLPerf Client Workload

Runs the [MLPerf Client](https://github.com/mlcommons/mlperf_client) v1.5 LLM benchmark
offline. On Snapdragon X-class ARM64 devices it executes Phi-3.5 inference across several
task categories using Windows ML with the Qualcomm QNN NPU execution provider, and reports
the benchmark duration.

## What HOBL sets up (from `mlperf_resources/mlperf_prep.ps1`)

- `Microsoft.WindowsAppRuntime.1.8` (winget)
- MLPerf Client v1.5 zip (GitHub release) → `<drive>\hobl_bin\mlperf`
- (ARM64) WinML QNN execution-provider MSIX via `Add-AppxPackage`

## Run it standalone (Windows, ARM64 / Snapdragon)

```powershell
winget install --id Microsoft.WindowsAppRuntime.1.8 --source winget

# Download + extract the client (ARM64 example)
Invoke-WebRequest "https://github.com/mlcommons/mlperf_client/releases/download/v1.5/mlperf-client-1.5.0-8665cb1-windows-arm64.zip" -OutFile mlperf.zip
Expand-Archive mlperf.zip -DestinationPath C:\hobl_bin\mlperf

# (Snapdragon) install the QNN execution provider
Add-AppxPackage -Path C:\hobl_bin\mlperf\qnnep_arm.msix

# Timed workload
C:\hobl_bin\mlperf\mlperf-windows.exe `
  --config "C:\hobl_bin\mlperf\Config_Phi3.5_WindowsML_QNN_NPU.json" `
  --output-dir "C:\hobl_data" --download_behaviour skip_all --pause false
```

## Notes

- See `mlperf_resources/mlperf_prep.ps1` and `mlperf_run.ps1` for the exact release URL and
  config filename used.
- The default config targets the Qualcomm NPU (ARM64); x64 binaries exist but the default
  config is Snapdragon-specific.
- Results land in `results.json` ("Benchmark Duration"). Admin is required for the MSIX install.
- Default: 1 loop.
