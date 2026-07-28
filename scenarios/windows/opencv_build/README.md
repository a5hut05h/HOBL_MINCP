# OpenCV Build Workload

Builds [OpenCV](https://github.com/opencv/opencv) (tag `4.10.0`) from source with MSVC + CMake
as a monolithic "world" library in Release configuration. It reports compile time — a C++
build benchmark.

## What HOBL sets up (from `opencv_build_resources/opencv_build_prep.ps1`)

- winget: Visual Studio 2022, Git, CMake 4.1.1
- Clones `opencv/opencv` @ `4.10.0` to `<drive>\opencv`; build dir `<drive>\opencv\build_msvc`

## Run it standalone (Windows)

```powershell
winget install --id git.git --source winget
winget install --id KitWare.CMake --source winget
# + Visual Studio 2022 with "Desktop development with C++"

git clone https://github.com/opencv/opencv.git
cd opencv
git checkout tags/4.10.0
mkdir build_msvc; cd build_msvc

cmake -S .. -B . -G "Visual Studio 17 2022" -DBUILD_opencv_world=ON `
  -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DWITH_PYTHON=OFF

# Timed workload
cmake --build . --config Release
cmake --build . --target INSTALL --config Release
```

## Notes

- The CMake flags above are representative — see
  `opencv_build_resources/opencv_build_prep.ps1` for the exact configuration HOBL uses.
- Default: 1 loop. Works on x64 and ARM64.
