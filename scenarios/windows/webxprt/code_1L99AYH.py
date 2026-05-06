# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os

def run(scenario):
    logging.debug('Executing code block: code_1L99AYH.py')
    webxprt_score = scenario._call(["powershell", "Get-Clipboard"])

    # separate by new line and find the score after "Your score:"
    score_list = webxprt_score.split("\n")
    score = ""
    for i, line in enumerate(score_list):
        if "your score:" in line.lower():
            # Score is on a subsequent line, skip any empty/whitespace-only lines
            for j in range(i + 1, len(score_list)):
                if score_list[j].strip():
                    score = score_list[j].strip()
                    break
            break
    logging.info("WebXPRT Score: " + score)

    webxprt_score_csv = os.path.join(scenario.result_dir, "webxprt_score.csv")
    with open(webxprt_score_csv, "w") as f:
        f.write("WebXPRT Score," + score)
