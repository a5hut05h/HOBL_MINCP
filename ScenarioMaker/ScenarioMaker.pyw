# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

"""
Tool for authoring HOBL test cases.
"""


# Imports
import sys
import os
import argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from PyQt6 import QtWidgets, QtGui, QtCore
import pywinstyles
import main_window as mainwin
import remote as remote
from settings import SettingsData


def parse_startup_args(argv):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("folder", nargs="?", help="Optional scenario folder to open in a new tab.")
    return parser.parse_known_args(argv)

def main():
    os.environ['QT_QPA_PLATFORM'] = "windows:darkmode=1"
    parsed_args, qt_args = parse_startup_args(sys.argv[1:])

    # Load settings
    settings_data = SettingsData()
    # data_directory = settings["data_directory"]
    config_file = settings_data.get("config_file")

    app = QtWidgets.QApplication([sys.argv[0]] + qt_args)
    app.setStyle('Fusion')

    main_window = mainwin.MainWindow(app, settings_data) 
    # main_window = mainwin.MainWindow(app) 

    pywinstyles.apply_style(main_window, "normal")
    # pywinstyles.change_header_color(main_window, color="#303030")
    main_window.setWindowIcon(QtGui.QIcon('images/logo.png'))

    if parsed_args.folder:
        open_dir = os.path.abspath(parsed_args.folder)
        scenario_name = os.path.basename(os.path.normpath(open_dir))
        expected_json = os.path.join(open_dir, scenario_name + ".json")

        if os.path.isdir(open_dir) and os.path.isfile(expected_json):
            main_window.open_in_new_tab(open_dir)
        else:
            QtWidgets.QMessageBox.warning(
                main_window,
                "ScenarioMaker",
                f"Unable to open action list from folder:\n{open_dir}\n\nExpected file:\n{expected_json}",
            )

    main_window.show()
    main_window.raise_()

    # remote_thread = remote.RemoteThread(main_window)
    # remote_thread.start()

    app.exec()

    # remote_thread.stop()
    # remote_thread.join()

    print("Application Closed \n")


if __name__ == "__main__":
    main()
