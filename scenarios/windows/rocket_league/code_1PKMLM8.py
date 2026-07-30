# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os

def run(scenario):
    logging.debug('Executing code block: code_1PKMLM8.py')

    # Resolve the DUT's Documents folder, then build the Rocket League config path
    documents_result = scenario._call(
        ["powershell.exe", "-Command \"[Environment]::GetFolderPath('MyDocuments')\""],
        expected_exit_code=""
    )
    documents_path = documents_result.strip().splitlines()[-1].strip() if documents_result else ""
    if not documents_path:
        scenario.fail("Could not resolve DUT Documents folder path.")
        return

    config_dir = os.path.join(documents_path, "My Games", "Rocket League", "TAGame", "Config")

    # Make sure the config directory exists on the DUT before uploading
    scenario._call(["cmd.exe", f'/C if not exist "{config_dir}" mkdir "{config_dir}"'], expected_exit_code="")

    # Upload the prepared TASystemSettings.ini into the config directory
    logging.info("Uploading TASystemSettings.ini to " + config_dir)
    scenario._upload(
        "scenarios\\windows\\rocket_league\\rocket_league_resources\\TASystemSettings.ini",
        config_dir,
        check_modified=False
    )

    # Update the resolution in the ini to match the DUT's screen size.
    width, height = scenario._get_screen_size()
    logging.info("Setting Rocket League resolution to " + str(width) + "x" + str(height))
    ini_path = os.path.join(config_dir, "TASystemSettings.ini")
    ps_cmd = ("-Command \"(Get-Content '" + ini_path + "') "
              "-replace '^ResX=\\d+', 'ResX=" + str(width) + "' "
              "-replace '^ResY=\\d+', 'ResY=" + str(height) + "' "
              "| Set-Content '" + ini_path + "'\"")
    scenario._call(["powershell.exe", ps_cmd])

    # Upload the DBE_Production save folder into SaveData. This is for custom match settings
    savedata_dir = os.path.join(documents_path, "My Games", "Rocket League", "TAGame", "SaveData")
    dbe_dest = os.path.join(savedata_dir, "DBE_Production")
    scenario._call(["cmd.exe", f'/C if not exist "{savedata_dir}" mkdir "{savedata_dir}"'], expected_exit_code="")
    scenario._call(["cmd.exe", f'/C if exist "{dbe_dest}" rmdir /S /Q "{dbe_dest}"'], expected_exit_code="")
    logging.info("Uploading DBE_Production to " + savedata_dir)
    scenario._upload(
        "scenarios\\windows\\rocket_league\\rocket_league_resources\\DBE_Production",
        savedata_dir,
        check_modified=False
    )

    # Launch Rocket League
    logging.info("Launching Rocket League")
    scenario._call(["cmd.exe", "/C start \"\" \"C:\\Program Files (x86)\\Steam\\steamapps\\common\\rocketleague\\Binaries\\Win64\\RocketLeague.exe\""], blocking=False, expected_exit_code="")
