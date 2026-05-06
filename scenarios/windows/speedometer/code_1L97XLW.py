# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os

def run(scenario):
    logging.debug('Executing code block: code_1L97XLW.py')
    speedometer_score = scenario._call(["powershell", "Get-Clipboard"])

    # separater by new line and take the line after "score"
    score = speedometer_score.split("\n")[2]
    logging.info("Speedometer Score: " + score)

    speedometer_score_csv = os.path.join(scenario.result_dir, "speedometer_score.csv")
    with open(speedometer_score_csv, "w") as f:
        f.write("Speedometer Score," + score)
