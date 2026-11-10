# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import base64
import csv
import json
import logging
import os
import time

import core.app_scenario
from core.parameters import Params
from selenium.common.exceptions import NoSuchElementException, StaleElementReferenceException
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait


def outlook_kind(app_id):
    app_id = app_id.lower()
    if "microsoft.outlookforwindows_" in app_id:
        return "new"
    if "outlook.exe" in app_id:
        return "classic"
    return None


def select_target(classic, outlook):
    classic, outlook = classic.strip(), outlook.strip()
    if classic not in ("0", "1") or outlook not in ("0", "1"):
        raise ValueError(
            "Outlook_Swap:outlook-classic and Outlook_Swap:Outlook must each be 0 or 1."
        )
    return "new" if classic == "0" and outlook == "1" else "classic"


class OutlookSwap(core.app_scenario.Scenario):
    module = "Outlook_Swap"
    Params.setDefault(module, "outlook-classic", "1")
    Params.setDefault(module, "Outlook", "0")
    Params.setDefault(module, "timeout", "60")

    def runTest(self):
        # Validate before contacting the DUT or changing taskbar state.
        target = select_target(
            Params.get(self.module, "outlook-classic"),
            Params.get(self.module, "Outlook"),
        )
        self.ui_timeout = int(Params.get(self.module, "timeout"))
        if not 1 <= self.ui_timeout <= 3600:
            raise ValueError("Outlook_Swap:timeout must be between 1 and 3600 seconds.")

        started = time.monotonic()
        self.helper = os.path.join(self.dut_exec_path, "Outlook_Swap", "outlook_window.ps1")
        self._upload(
            os.path.join(os.path.dirname(__file__), "outlook_window.ps1"),
            os.path.dirname(self.helper),
            check_modified=False,
        )
        inventory = self._helper("Discover")
        if inventory["OpenWindows"]:
            self.fail(
                "Close existing Outlook windows before swapping; no user windows "
                "will be closed automatically: " + str(inventory["OpenWindows"])
            )
        self._startWinAppDriver()
        self.desktop = self._launchDesktop()
        self.desktop.implicitly_wait(0)

        pinned = self._pinned_versions()
        logging.info("Outlook pins before swap: %s; target: %s", sorted(pinned), target)
        apps = [app for app in inventory["Apps"] if outlook_kind(app["AppID"]) == target]
        if len(apps) != 1:
            self.fail(
                "Expected one installed %s Outlook entry from Get-StartApps, found %s. "
                "Install/repair the app for the signed-in DUT user." % (target, apps)
            )
        logging.info("Discovered Outlook application: %s", apps[0])

        # Secure the destination pin before removing the source pin.
        if target not in pinned:
            if sum(app["Name"] == apps[0]["Name"] for app in inventory["Apps"]) != 1:
                self.fail(
                    "Outlook application display names are ambiguous; cannot safely "
                    "choose the destination in the Applications folder."
                )
            self._pin_app(apps[0]["Name"], target)
        for source in sorted(pinned - {target}):
            self._unpin(source)
        self._wait(
            lambda: self._pinned_versions() == {target},
            "Taskbar did not settle to exactly one pinned Outlook: " + target,
        )

        logging.info("Launching %s Outlook from its verified taskbar pin", target)
        self._button(target).click()
        result = self._helper("Complete", target)
        logging.info("Outlook window maximized and closed: %s", result)
        self._wait(
            lambda: self._pinned_versions() == {target},
            "The Outlook pin was not retained after closing its window.",
        )

        runtime = round(time.monotonic() - started, 3)
        with open(os.path.join(self.result_dir, "outlook_swap_results.csv"),
                  "w", newline="", encoding="utf-8") as results:
            writer = csv.DictWriter(results, fieldnames=["target", "scenario_runtime"])
            writer.writeheader()
            writer.writerow({"target": target, "scenario_runtime": runtime})
        logging.info("=== Outlook Swap metrics: target=%s scenario_runtime=%.3f s ===",
                     target, runtime)

    def _helper(self, action, target="classic"):
        helper = self.helper.replace("'", "''")
        command = (
            "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; "
            "& '%s' -Action %s -Target %s -TimeoutSeconds %d"
            % (helper, action, target, self.ui_timeout)
        )
        encoded = base64.b64encode(command.encode("utf-16-le")).decode("ascii")
        output = self._call(
            ["powershell.exe",
             "-NoProfile -NonInteractive -OutputFormat Text "
             "-ExecutionPolicy Bypass -EncodedCommand " + encoded],
            timeout=self.ui_timeout * 3 + 30,
        )
        try:
            return json.loads(output)
        except json.JSONDecodeError as error:
            raise ValueError(
                "Outlook helper %s returned invalid JSON: %r" % (action, output)
            ) from error

    def _wait(self, predicate, message):
        return WebDriverWait(
            self.desktop, self.ui_timeout, poll_frequency=0.5,
            ignored_exceptions=(NoSuchElementException, StaleElementReferenceException),
        ).until(lambda _: predicate(), message)

    def _buttons(self):
        def scan():
            tray = self._get_app_tray(self.desktop)
            result = {}
            for button in tray.find_elements_by_xpath(".//Button"):
                kind = outlook_kind(button.get_attribute("AutomationId") or "")
                if kind:
                    if kind in result:
                        self.fail("Multiple taskbar buttons found for %s Outlook." % kind)
                    result[kind] = button
            # An empty completed scan is valid, so keep the wait result truthy.
            return (result,)

        return self._wait(
            scan, "Cannot read Outlook taskbar buttons before the UI timeout."
        )[0]

    def _button(self, kind):
        button = self._buttons().get(kind)
        if button is None:
            raise NoSuchElementException("Missing %s Outlook taskbar button." % kind)
        return button

    def _menu_item(self, name):
        for item in self.desktop.find_elements_by_name(name):
            if item.is_displayed() and item.is_enabled():
                return item
        return None

    def _dismiss_menu(self):
        ActionChains(self.desktop).send_keys(Keys.ESCAPE).perform()

    def _pin_state(self, kind):
        ActionChains(self.desktop).context_click(self._button(kind)).perform()
        try:
            state = self._wait(
                lambda: (
                    "pinned" if self._menu_item("Unpin from taskbar")
                    else "running" if self._menu_item("Pin to taskbar")
                    else None
                ),
                "Cannot read the %s Outlook taskbar menu. English Windows UI is required."
                % kind,
            )
            return state == "pinned"
        finally:
            self._dismiss_menu()

    def _pinned_versions(self):
        # A visible taskbar button alone does not mean that the application is pinned.
        return {kind for kind in self._buttons() if self._pin_state(kind)}

    def _unpin(self, kind):
        ActionChains(self.desktop).context_click(self._button(kind)).perform()
        try:
            self._wait(
                lambda: self._menu_item("Unpin from taskbar"),
                "Missing Unpin from taskbar for " + kind,
            ).click()
        finally:
            self._dismiss_menu()
        self._wait(
            lambda: kind not in self._pinned_versions(),
            "Outlook could not be unpinned: " + kind,
        )

    def _pin_app(self, app_name, kind):
        existing = {
            win.get_attribute("NativeWindowHandle")
            for win in self.desktop.find_elements_by_class_name("CabinetWClass")
        }
        self._call(["explorer.exe", "/n,shell:AppsFolder"], blocking=False)

        def find_folder():
            for win in self.desktop.find_elements_by_class_name("CabinetWClass"):
                if win.get_attribute("NativeWindowHandle") not in existing:
                    return win
            return None

        folder = self._wait(
            find_folder,
            "Cannot locate a new Applications folder window.",
        )
        folder_driver = self.getDriverFromWin(folder)
        try:
            # Explorer's type-to-select brings off-screen applications into view.
            ActionChains(folder_driver).send_keys(app_name).perform()
            app = self._wait(
                lambda: folder_driver.find_element_by_name(app_name),
                "Cannot locate %s in the Applications folder after type-to-select."
                % app_name,
            )
            app.click()
            ActionChains(folder_driver).context_click(app).perform()

            def pin_command():
                pin = self._menu_item("Pin to taskbar")
                if pin:
                    return pin
                more = self._menu_item("Show more options")
                if more:
                    more.click()
                return None

            self._wait(
                pin_command,
                "Pin to taskbar is unavailable for %s. Check Windows pinning policies "
                "and use an English Windows UI." % app_name,
            ).click()
            self._wait(
                lambda: kind in self._pinned_versions(),
                "Windows did not create the %s Outlook taskbar pin." % kind,
            )
        finally:
            self._dismiss_menu()
            folder_driver.close()
            folder_driver.quit()
