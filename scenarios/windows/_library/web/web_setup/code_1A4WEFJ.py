# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
from core.parameters import Params

def run(scenario):
    logging.debug('Executing code block: code_1A4WEFJ.py')
    if Params.get("global", "browser").lower() != "chrome":
        scenario._call(["cmd.exe", '/C reg add "HKLM\\Software\\Policies\\Microsoft\\Edge\\LocalNetworkAccessAllowedForUrls" /v 1 /t REG_SZ /d * /f'])
    logging.info("Web Replay Delay Enabled")
    scenario._web_replay_start()
    scenario._sleep_to_now()
