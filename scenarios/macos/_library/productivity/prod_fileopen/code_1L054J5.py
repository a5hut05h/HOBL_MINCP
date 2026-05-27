# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
import os
import logging
from parameters import Params

def run(scenario):
    logging.debug('Executing code block: code_1L054J5.py')
    # Get user home directory
    if Params.get("global", "local_execution") == "0":
        userprofile = scenario._call(["bash", "-c \"echo $HOME\""]).strip()
    else:
        userprofile = os.environ['HOME']
    logging.debug(f"User profile: {userprofile}")

    relative_filepath = str(Params.get("prod_fileopen", "relative_filepath") or "").strip()

    # Ensure we append a relative path to the user profile directory.
    relative_filepath = relative_filepath.lstrip("/")
    full_filepath = userprofile + "/" + relative_filepath
    logging.debug(f"Full file path: {full_filepath}")

    scenario._call(["open", full_filepath]).strip()