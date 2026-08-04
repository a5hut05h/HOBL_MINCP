# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
from core.parameters import Params


def run(scenario):
    logging.debug('Executing code block: code_1MFKXM4.py')
    loop_counter = Params.get('cyberpunk', 'loop_counter')

    scenario._screenshot(name=f"score_screenshots\\run_{loop_counter}.png")

    # Increment loop counter for next loop
    Params.setOverride('cyberpunk', 'loop_counter', str(int(loop_counter)+1))