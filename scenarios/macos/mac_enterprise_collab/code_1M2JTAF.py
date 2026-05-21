# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
from core.parameters import Params

def run(scenario):
    logging.debug('Executing code block: code_1M2JTAF.py')

    module = "mac_enterprise_collab"

    def _to_int(value, default=0):
        try:
            return int(value)
        except (TypeError, ValueError):
            return default

    loop_count = _to_int(Params.get(module, 'loop_count'), 0)
    success_count = _to_int(Params.get(module, 'success_count'), 0)
    failure_count = max(loop_count - success_count, 0)

    banner = "=" * 62
    summary_lines = [
        banner,
        "*** EXECUTION SUMMARY ***",
        f"Total Loops   : {loop_count}",
        f"Success Count : {success_count}",
        f"Failure Count : {failure_count}",
        banner,
    ]

    for line in summary_lines:
        logging.info(line)
