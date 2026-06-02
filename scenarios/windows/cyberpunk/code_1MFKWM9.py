# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os

def run(scenario): 
    logging.debug('Executing code block: code_1MFKWM9.py')
    os.makedirs(scenario.result_dir + "\\score_screenshots", exist_ok=True)
    scenario._screenshot(name="score_screenshots\\run_1.png")