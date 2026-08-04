# Foundry Local Inference Workload

Edge LLM inference benchmark built on
[Microsoft Foundry Local](https://learn.microsoft.com/azure/ai-foundry/foundry-local/).
It starts the Foundry Local service, ensures a model is cached (default
`Phi-3.5-mini-instruct-generic-cpu`), runs a single-prompt inference, and reports the
end-to-end runtime.

## What HOBL sets up (from `foundrylocal_resources/*.ps1`)

- `Microsoft.FoundryLocal` (winget)
- Model downloaded on demand via `foundry model download` (several GB, cached locally)

## Run it standalone (Windows)

```powershell
winget install --id Microsoft.FoundryLocal --source winget

# Refresh PATH so `foundry` resolves in this session
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + `
            [Environment]::GetEnvironmentVariable("Path","User")

foundry service start
foundry model download "Phi-3.5-mini-instruct-generic-cpu"
foundry cache list

# Timed workload
foundry model run "Phi-3.5-mini-instruct-generic-cpu" --prompt "What is the meaning of life?"

# Cleanup (avoids disk bloat — models are not auto-expired)
foundry cache remove "Phi-3.5-mini-instruct-generic-cpu" --yes
foundry service stop
```

## Notes

- Default: 1 loop. Works on x64 and ARM64.
- First run downloads the model; the HOBL teardown removes it afterward.
