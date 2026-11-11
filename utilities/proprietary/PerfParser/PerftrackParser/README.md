# PerfParser

Converts an ETW trace (`.etl`) plus a PerfTrack scenario manifest (`.xml`) into a
summary CSV of scenario durations.

## Build

```powershell
dotnet build PerfParser.csproj --configuration Release
```

To create the framework-dependent Windows packages used by HOBL:

```powershell
.\publish.ps1
```

This produces:

```text
artifacts\publish\win-x64\PerfParser.exe
artifacts\publish\win-arm64\PerfParser.exe
```

Both packages target `net8.0` and require an architecture-matching
`Microsoft.NETCore.App` 8.x runtime. HOBL DUT setup installs Windows Desktop
Runtime 8.0.29, which includes that runtime. The packages are not
self-contained. Their runtime configuration requests version `8.0.0` and uses
the .NET host's normal patch roll-forward behavior, so runtime 8.0.29 satisfies
the request. Managed and native NuGet dependencies are bundled into each
single-file executable and extracted at startup because the ETW toolkit
requires real assembly paths.

Package the publish outputs in HOBL as:

```text
artifacts\publish\win-x64\   -> utilities\proprietary\ParseUtc\x64\
artifacts\publish\win-arm64\ -> utilities\proprietary\ParseUtc\arm64\
```

Separate executables are required because
`Microsoft.Windows.EventTracing.Processing.OutputRedirection` includes
architecture-specific `NativeOutputRedirector.dll` binaries. An AnyCPU package
would not guarantee that the matching native dependency is loaded.

## Run

```powershell
dotnet bin\Release\net8.0\PerfParser.dll <trace.etl> <manifest.xml> [summary.csv] [--raw-metrics [path]] [--verbose]
```

Example:

```powershell
dotnet bin\Release\net8.0\PerfParser.dll `
    validation\consumer_multitasker_021.etl `
    test\ConsumerMultitaskerPTs.xml `
    validation\consumer_multitasker_021_scenario_duration.csv `
    --raw-metrics validation\consumer_multitasker_021_raw_metrics.txt
```

The manifest is required. It supplies the `PT_ID -> PTScenarioName` mapping, the
provider GUIDs used to filter the trace, and the per-scenario duration field
name. Any PerfTrack event whose `PT_ID` is absent from the manifest is dropped.

## Output

The summary CSV has no header row. Each line is:

```
Perftrack_<InputInjectEventName>_<PTScenarioName>,<DurationMs>
```

The first field is unique. When the same key occurs more than once the first
occurrence is written bare and later ones gain a `_1`, `_2`, ... suffix.

## Diagnostics

By default the parser writes nothing to stderr on a successful run. Automation
that treats any stderr output as a failure therefore stays quiet. Only three
things reach stderr: a usage error, a warning that no rows were produced, and an
unhandled exception.

Pass `--verbose` to explain why individual rows were dropped:

```powershell
dotnet bin\Release\net8.0\PerfParser.dll trace.etl manifest.xml out.csv --verbose 2> drops.log
```

Most `[INFO] Dropped ...` lines are expected. `PT_9412` in particular fires
repeatedly per navigation, and the requirement is to keep only the first event
per transaction, so a busy trace legitimately drops many rows.

## Validation

`validation\` holds three traces with their expected outputs. To confirm a
change did not alter results:

```powershell
.\validate.ps1
```

The script regenerates every output into a temporary directory and compares it
against the committed expectations, reporting any drift. It exits non-zero on
mismatch.

## Processing stages

1. Parse the manifest into scenarios, provider GUIDs and duration fields.
2. Read the trace, keeping only events from manifest-declared providers plus
   InputInject, DiagTrack and TestInProduction.
3. Resolve each event's `PT_ID`, directly from its fields where possible and
   otherwise by matching the manifest's SCXML state and filters.
4. Correlate each PerfTrack event with an InputInject start event. `PT_9471`
   binds to the nearest *following* start event; everything else binds to the
   nearest preceding one.
5. For `PT_9412`, keep only the first event per InputInject transaction window.
6. Drop overlapping events. Overlap is scoped per `PT_ID`, so a repeated
   emission of the same scenario is discarded while a genuinely nested
   sub-scenario is preserved.
7. Assign unique output keys and write the CSV.

## Repository layout

| Path | Purpose |
| --- | --- |
| `PerfParser.cs` | Trace parsing, correlation, filtering and output |
| `ScenarioManifestHandler.cs` | Manifest and SCXML parsing |
| `publish.ps1` | Builds framework-dependent `win-x64` and `win-arm64` packages |
| `test\*.xml` | Scenario manifests |
| `validation\` | Traces and their expected outputs |

`test\` also retains earlier test traces and reference outputs. The validation
script uses the traces and expected outputs under `validation\`. Build and
publish outputs are ignored by version control.
