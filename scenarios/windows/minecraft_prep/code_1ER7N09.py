# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import time
from unittest import result

def run(scenario):
    logging.debug('Executing code block: code_1ER7N09.py')
    # result = scenario._call(["cmd.exe", "/C winget list --name \"Minecraft Launcher\""], expected_exit_code="")
    # if "Minecraft Launcher" not in result:
    #     logging.info("Minecraft Launcher not found, installing via winget.")
    #     scenario._call(["cmd.exe", '/c winget install -e --id Mojang.MinecraftLauncher --source winget'])
    try:
        scenario._call(["cmd.exe", '/c winget install -e --id Mojang.MinecraftLauncher --source winget'])
    except:
        pass
    scenario._call(["cmd.exe", "/C \"C:\\Program Files (x86)\\Minecraft Launcher\\MinecraftLauncher.exe\""], blocking=False)
    time.sleep(30)