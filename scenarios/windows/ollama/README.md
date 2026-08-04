# Ollama Inference Workload

Builds [Ollama](https://github.com/ollama/ollama) from source (tag `v0.20.8-rc0`), starts the
server, pulls a model (default `gemma3`), and runs a prompt in verbose mode. It reports
inference metrics: total duration, time-to-first-token (TTFT), and tokens/second.

## What HOBL sets up (from `ollama_resources/*.ps1`)

- winget: Visual Studio 2022, Go 1.25.1, Git, CMake 4.1.1
- LLVM-MinGW toolchain (GitHub release → `C:\Program Files`)
- Clones `ollama/ollama` @ `v0.20.8-rc0` to `<drive>\hobl_bin\ollama`
- Also supports a pre-built custom-binary path (skips all compilation)

## Run it standalone (Windows)

```powershell
winget install --id GoLang.Go --source winget --version 1.25.1
winget install --id git.git --source winget
winget install --id KitWare.CMake --source winget
# + Visual Studio 2022 C++ tools; download LLVM-MinGW and add its \bin to PATH

git clone https://github.com/ollama/ollama.git
cd ollama
git checkout v0.20.8-rc0

# Build (x64 builds GPU runners via cmake first; ARM64 is CPU-only)
cmake -B build; cmake --build build      # x64 only
go build -o ollama.exe .

# Run
.\ollama.exe serve                       # background; listens on http://localhost:11434
.\ollama.exe pull gemma3
.\ollama.exe run gemma3 "what is the meaning of life?" --verbose
```

## Notes

- Requires PowerShell 7+. The server listens on `http://localhost:11434`.
- Default: 1 loop. HOBL teardown removes the pulled model.
