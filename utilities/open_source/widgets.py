# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

from PyQt6 import QtWidgets
import requests
from urllib.parse import urlparse, urlunparse
from core.parameters import Params


class Widgets:
    dashboard_url     = Params.get('global', 'dashboard_url')
    dashboard_plan_id = Params.get('global', 'dashboard_plan_id')


    def __init__(self):
        if self.dashboard_url == "":
            self.app = QtWidgets.QApplication([])


    def _call_widget(self, path, data):
        data["planId"] = self.dashboard_plan_id

        url = urlunparse(
            urlparse(self.dashboard_url)._replace(
                path=path
            )
        )

        while True:
            try:
                response = requests.post(
                    url,
                    data,
                    timeout=10
                )

                if response.status_code == 200:
                    break
            except Exception as e:
                pass


    def about(self, title, text):
        if self.dashboard_url == "":
            input(f"{text} Press Enter to continue...")
            # QtWidgets.QMessageBox.about(None, title, text)
        else:
            self._call_widget(
                "/plan/Widget",
                {
                    "title": title,
                    "text": text
                }
            )
