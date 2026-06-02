# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os
import csv
import glob
import json
from core.parameters import Params


def run(scenario):
    logging.debug('Executing code block: code_1062A47.py')
    benchmark_path = Params.getCalculated('cyberpunk_benchmark_path')
    benchmark_loops = Params.get('cyberpunk', 'benchmark_loops')

    try:
        scenario._kill("Cyberpunk2077.exe")
    except:
        pass
    try:
        scenario._kill("CrashReporter.exe")
    except:
        pass
        
    if benchmark_path == '':
        # Setup didn't find a benchmark folder (first-ever run). Ask the shell
        # for the real Documents path on the DUT — [Environment]::GetFolderPath
        # returns the OneDrive path when Known Folder Move is on, otherwise the
        # plain Documents path.
        documents_result = scenario._call(
            ["powershell.exe", "-Command \"[Environment]::GetFolderPath('MyDocuments')\""],
            expected_exit_code=""
        )
        documents_path = documents_result.strip().splitlines()[-1].strip() if documents_result else ""
        benchmark_path = os.path.join(
            documents_path, "CD Projekt Red", "Cyberpunk 2077", "benchmarkResults"
        ) if documents_path else ""

        benchmark_exists = "NOT_FOUND"
        if benchmark_path:
            benchmark_exists = scenario._call(
                ["cmd.exe", f'/C if exist "{benchmark_path}" (echo EXISTS) else (echo NOT_FOUND)'],
                expected_exit_code=""
            )

        if "EXISTS" not in benchmark_exists:
            # Something could've errored and benchmark didn't run. So fail run
            scenario.fail("Benchmark result files not found. Game may have failed to run benchmark. Check benchmark_runs directory for images to confirm. ")
            return
    
    # Need to copy the benchmark results from benchmark_path to dut_data_path and upload the results over to host PC so it can be used for post processing.
    ps_command = (
        f"-Command \"Copy-Item -Path '{benchmark_path}' -Destination '{scenario.dut_data_path}' -Recurse\""
    )
    try:
        scenario._call(["powershell.exe", ps_command], expected_exit_code="")
    except:
        pass
    results_root = os.path.join(scenario.result_dir, "benchmarkResults")
    scenario._copy_data_from_remote(dest=results_root, source=os.path.join(scenario.dut_data_path, "benchmarkResults"),)

    # Aggregate per-run summary.json files into a single CSV.
    # All static info (gpu, cpu, preset, etc.) is identical across runs; only the
    # fps/time fields vary, so we average those across runs.
    summaries = sorted(glob.glob(os.path.join(results_root, "benchmark_*", "summary.json")))
    run_count = len(summaries)

    if run_count != int(benchmark_loops) + 1:
        scenario.fail(f"Expected {int(benchmark_loops) + 1} runs, but found {run_count} summary.json file(s) under {results_root}. Check score_screenshot to verify benchmark scores.")
        return
    
    averaged_fields = ["averageFps", "minFps", "maxFps"]

    with open(summaries[0], "r", encoding="utf-8") as f:
        first = json.load(f)["Data"]

    # Average the per-run fields across all runs.
    totals = {k: 0.0 for k in averaged_fields}
    for path in summaries:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)["Data"]
        for k in averaged_fields:
            totals[k] += float(data.get(k, 0))

    run_count = len(summaries)

    # Build the output row with the averaged fps fields first, then run_count,
    # then all the static fields from the first run's summary.
    row = {}
    for k in averaged_fields:
        row[k] = totals[k] / run_count
    row["run_count"] = run_count
    for k, v in first.items():
        if k not in averaged_fields:
            row[k] = v

    csv_path = os.path.join(scenario.result_dir, "cyberpunk_benchmark_summary.csv")
    with open(csv_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        for key, value in row.items():
            writer.writerow([key, value])

    logging.info(f"Aggregated {run_count} benchmark run(s) into {csv_path}")
