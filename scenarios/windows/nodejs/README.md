# Node.js Build Workload

Builds [Node.js](https://github.com/nodejs/node) v25.0.0 from source with the MSVC native
build system (`vcbuild.bat`), compiling the runtime and OpenSSL with `openssl-no-asm` for
cross-architecture reproducibility. It reports total build time — a heavy C++ build benchmark.

## What HOBL sets up (from `nodejs_resources/nodejs_prep.ps1`)

- Visual Studio 2022 C++ build tools, Git, Python 3.12.10 (pyenv, required by `vcbuild.bat`)
- Downloads the `nodejs/node` v25.0.0 source zip and extracts it to
  `<drive>\hobl_bin\nodejs\node-25.0.0`

## Run it standalone (Windows)

```powershell
# + Visual Studio 2022 with "Desktop development with C++"
pyenv install 3.12.10; pyenv local 3.12.10

Invoke-WebRequest "https://github.com/nodejs/node/archive/refs/tags/v25.0.0.zip" -OutFile node.zip
Expand-Archive node.zip -DestinationPath .
cd node-25.0.0

# Timed workload (from a Developer prompt with VsDevCmd loaded)
.\vcbuild.bat clean x64 openssl-no-asm       # arm64 on ARM64 devices
.\vcbuild.bat release x64 openssl-no-asm
```

## Notes

- Requires PowerShell 7+. Expect a long build (tens of minutes).
- Set `PYTHON` / `PYTHONHOME` to your pyenv Python so `vcbuild.bat` finds it.
- HOBL teardown removes `out/`, `Release/`, and `Debug/` (frees ~2–3 GB). Default: 1 loop.
