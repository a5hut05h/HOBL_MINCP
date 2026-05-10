# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import csv
import os
import time
import math
import xml.etree.ElementTree as ET
from core.parameters import Params

def run(scenario):
    logging.debug('Executing code block: code_1LC4L8F.py')
    test_def = Params.get('procyon_run', 'test_definition')
    loop_num = Params.get('procyon_run', 'loop_number')
    if loop_num is None or loop_num == "":
        loop_num = "1"
    loop_num = int(float(loop_num))
    if ".def" not in test_def:
        test_def = test_def + ".def"
    logging.info(f"Running Procyon loop {loop_num} using test definition: {test_def}")
    scenario._remote_make_dir(f"{scenario.dut_data_path}\\procyon", delete=False)
    scenario._call(["C:\\Program Files\\UL\\Procyon\\ProcyonCmd.exe", f"--definition={test_def} --loop=1 --export-xml=c:\\hobl_data\\procyon\\Results_{loop_num}.xml"], fail_on_exception=False)
    
    # Record timestamp
    t = time.time() - scenario.scenario_start_time
    # round up t to the nearest second
    timestamp = math.ceil(t)

    # Download xml result file back to host
    scenario._copy_data_from_remote(scenario.result_dir + "\\procyon", source=f"{scenario.dut_data_path}\\procyon")

    # Read scores from xml file and write to csv
    xml_file = scenario.result_dir + f"\\procyon\\Results_{loop_num}.xml"
    tree = ET.parse(xml_file)
    root = tree.getroot()

    score_headers = []
    values = {}
    for element in root.iter():
        if "Score" in element.tag:
            if element.tag not in values:
                score_headers.append(element.tag)
            values[element.tag] = (element.text or "").strip()

    if not score_headers:
        logging.warning(f"No score tags found in XML file: {xml_file}")
        return

    headers = ["timestamp"] + score_headers

    csv_file = scenario.result_dir + f"\\procyon\\Procyon_Results.trace"

    csv_exists = os.path.exists(csv_file)
    with open(csv_file, "a", newline="", encoding="utf-8") as file_handle:
        writer = csv.writer(file_handle)
        if not csv_exists:
            writer.writerow(headers)
        writer.writerow([timestamp] + [values.get(h, "") for h in score_headers])

    # Read Procyon_results.trace file, average the scores for each column, and output into a summary csv as key,val pairs
    summary_file = scenario.result_dir + f"\\Procyon_Summary.csv"
    with open(csv_file, "r", newline="", encoding="utf-8") as file_handle:
        reader = csv.DictReader(file_handle)
        summary_data = {}
        count = 0
        for row in reader:
            count += 1
            for key, value in row.items():
                if key == "timestamp":
                    continue
                try:
                    value = float(value)
                except ValueError:
                    value = 0.0
                if key not in summary_data:
                    summary_data[key] = 0.0
                summary_data[key] += value
        if count > 0:
            for key in summary_data:
                summary_data[key] /= count

    with open(summary_file, "w", newline="", encoding="utf-8") as file_handle:
        writer = csv.writer(file_handle)
        for key, value in summary_data.items():
            writer.writerow([f"Procyon-{key}", value])
