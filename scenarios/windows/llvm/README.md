# LLVM Build Workload

Compiler-infrastructure build benchmark. It clones the
[LLVM project](https://github.com/llvm/llvm-project) at tag `llvmorg-21.1.8`, configures a
Ninja + CMake build, and performs a full from-clean build. It reports total build time — a
heavy, real-world CPU / memory / I/O compile workload.

## What HOBL sets up (from `llvm_resources/llvm_prep.ps1`)

- Python 3.12.10 (pyenv) and Visual Studio 2022 C++ build tools
- winget: Git, Ninja, CMake
- A pre-built LLVM 21.1.8 toolchain (installer → `C:\Program Files\llvm`)
- Clones `llvm/llvm-project` @ `llvmorg-21.1.8` to `<drive>\llvm-project`; build dir `<drive>\build_llvm`

## Run it standalone (Windows)

```powershell
winget install --id Git.Git --source winget
winget install --id Ninja-build.Ninja --source winget
winget install --id Kitware.CMake --source winget
# + Visual Studio 2022 with the "Desktop development with C++" workload

git clone --depth 1 --branch llvmorg-21.1.8 --config core.autocrlf=false `
  https://github.com/llvm/llvm-project.git

# From a Developer PowerShell (VsDevCmd loaded for your arch, e.g. -arch=x64 or -arch=arm64):
cmake -G Ninja -S llvm-project\llvm -B build_llvm -DCMAKE_BUILD_TYPE=Release `
  -DLLVM_ENABLE_PROJECTS="clang;lld"

# Timed workload
ninja -C build_llvm
```

## Notes

- The CMake configure line above is representative — see `llvm_resources/llvm_prep.ps1`
  for the exact project/runtime targets and flags HOBL uses.
- Load the MSVC environment first (`VsDevCmd.bat -arch=x64` or `-arch=arm64`).
- Expect a long build (tens of minutes or more). Default: 1 loop. Works on x64 and ARM64.
