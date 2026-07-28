# .NET Aspire Build Workload

Builds the [.NET Aspire](https://github.com/dotnet/aspire) cloud-app orchestration stack from
source (tag `v9.4.2`). It restores, cleans, then performs a no-restore rebuild of
`Aspire.slnx` and reports build time — a large managed (.NET / MSBuild) build workload.

## What HOBL sets up (from `net_aspire_resources/net_aspire_prep.ps1`)

- winget: .NET SDK 10 preview, .NET SDK 8, Git
- Clones `dotnet/aspire` @ `v9.4.2` to `<drive>\aspire`

## Run it standalone (Windows)

```powershell
winget install --id Microsoft.DotNet.SDK.Preview --source winget --version 10.0.100-preview.5.25277.114
winget install --id Microsoft.DotNet.SDK.8 --source winget
winget install --id Git.Git --source winget

git clone https://github.com/dotnet/aspire.git
cd aspire
git checkout v9.4.2

# Timed workload
dotnet restore Aspire.slnx
dotnet clean Aspire.slnx
dotnet build Aspire.slnx --no-restore
```

## Notes

- On ARM64, HOBL points `DOTNET_INSTALL_DIR` at the system dotnet to avoid pulling an
  x64-only legacy runtime. If `dotnet restore` complains about an old runtime, set
  `$env:DOTNET_INSTALL_DIR="C:\Program Files\dotnet"`.
- Aspire restores only from Microsoft/dnceng NuGet feeds. Default: 4 loops.
