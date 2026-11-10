import csv
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch


def load_scenario():
    # Isolate RPC/WinAppDriver dependencies; these tests never touch a real desktop.
    core = types.ModuleType("core")
    app_scenario = types.ModuleType("core.app_scenario")
    app_scenario.Scenario = unittest.TestCase
    core.app_scenario = app_scenario
    parameters = types.ModuleType("core.parameters")
    parameters.Params = Mock()
    exceptions = types.ModuleType("selenium.common.exceptions")
    exceptions.NoSuchElementException = type("NoSuchElementException", (Exception,), {})
    exceptions.StaleElementReferenceException = type(
        "StaleElementReferenceException", (Exception,), {}
    )
    actions = types.ModuleType("selenium.webdriver.common.action_chains")
    actions.ActionChains = Mock()
    keys = types.ModuleType("selenium.webdriver.common.keys")
    keys.Keys = types.SimpleNamespace(ESCAPE="ESCAPE", SHIFT="SHIFT", F10="F10")
    ui = types.ModuleType("selenium.webdriver.support.ui")
    ui.WebDriverWait = Mock()
    replacements = {
        "core": core,
        "core.app_scenario": app_scenario,
        "core.parameters": parameters,
        "selenium": types.ModuleType("selenium"),
        "selenium.common": types.ModuleType("selenium.common"),
        "selenium.common.exceptions": exceptions,
        "selenium.webdriver": types.ModuleType("selenium.webdriver"),
        "selenium.webdriver.common": types.ModuleType("selenium.webdriver.common"),
        "selenium.webdriver.common.action_chains": actions,
        "selenium.webdriver.common.keys": keys,
        "selenium.webdriver.support": types.ModuleType("selenium.webdriver.support"),
        "selenium.webdriver.support.ui": ui,
    }
    source = Path(__file__).resolve().parents[1] / "Outlook_Swap.py"
    spec = importlib.util.spec_from_file_location("outlook_swap_under_test", source)
    module = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, replacements):
        spec.loader.exec_module(module)
    return module


scenario = load_scenario()


class SwapPolicyTests(unittest.TestCase):
    def test_parameter_matrix(self):
        for classic, outlook, expected in [
            ("0", "1", "new"), ("1", "0", "classic"),
            ("0", "0", "classic"), ("1", "1", "classic"),
        ]:
            with self.subTest(classic=classic, outlook=outlook):
                self.assertEqual(scenario.select_target(classic, outlook), expected)
        self.assertEqual(scenario.select_target(" 0 ", " 1 "), "new")

    def test_invalid_parameters(self):
        for classic, outlook in [("2", "1"), ("0", "new"), ("", "0"), ("1", "-1")]:
            with self.subTest(classic=classic, outlook=outlook):
                with self.assertRaisesRegex(ValueError, "must each be 0 or 1"):
                    scenario.select_target(classic, outlook)

    def test_taskbar_and_start_app_identities(self):
        for identity in [
            "Microsoft.Office.OUTLOOK.EXE.15",
            "Appid: Microsoft.Office.OUTLOOK.EXE.15",
        ]:
            self.assertEqual(scenario.outlook_kind(identity), "classic")
        self.assertEqual(scenario.outlook_kind(
            "Appid: Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookforWindows"
        ), "new")
        self.assertIsNone(scenario.outlook_kind("Microsoft.Office.WINWORD.EXE.15"))
        self.assertIsNone(scenario.outlook_kind(""))


class TaskbarScanTests(unittest.TestCase):
    def setUp(self):
        self.flow = scenario.OutlookSwap()
        self.flow.desktop = Mock()
        self.flow.ui_timeout = 60
        self.flow._get_app_tray = Mock()

        def wait(driver, timeout, poll_frequency, ignored_exceptions):
            self.assertIs(driver, self.flow.desktop)
            self.assertEqual(timeout, 60)
            self.assertEqual(poll_frequency, 0.5)

            def until(predicate, message):
                for _ in range(3):
                    try:
                        result = predicate(driver)
                        if result:
                            return result
                    except ignored_exceptions:
                        pass
                raise TimeoutError(message)

            return Mock(until=until)

        patcher = patch.object(scenario, "WebDriverWait", side_effect=wait)
        patcher.start()
        self.addCleanup(patcher.stop)

    def button(self, app_id):
        button = Mock()
        button.get_attribute.return_value = app_id
        return button

    def test_stale_scan_reacquires_tray_and_discards_partial_results(self):
        classic = self.button("Microsoft.Office.OUTLOOK.EXE.15")
        stale = Mock()
        stale.get_attribute.side_effect = scenario.StaleElementReferenceException()
        fresh = self.button("Microsoft.OutlookForWindows_test!App")
        old_tray, new_tray = Mock(), Mock()
        old_tray.find_elements_by_xpath.return_value = [classic, stale]
        new_tray.find_elements_by_xpath.return_value = [fresh]
        self.flow._get_app_tray.side_effect = [old_tray, new_tray]
        self.assertEqual(self.flow._buttons(), {"new": fresh})
        self.assertEqual(self.flow._get_app_tray.call_count, 2)

    def test_missing_tray_is_reacquired(self):
        tray = Mock()
        tray.find_elements_by_xpath.return_value = []
        self.flow._get_app_tray.side_effect = [
            scenario.NoSuchElementException(), tray,
        ]
        self.assertEqual(self.flow._buttons(), {})
        self.assertEqual(self.flow._get_app_tray.call_count, 2)

    def test_empty_scan_does_not_wait_for_outlook(self):
        self.flow._get_app_tray.return_value.find_elements_by_xpath.return_value = []
        self.assertEqual(self.flow._buttons(), {})
        self.flow._get_app_tray.assert_called_once_with(self.flow.desktop)

    def test_persistent_staleness_fails_explicitly(self):
        self.flow._get_app_tray.side_effect = scenario.StaleElementReferenceException()
        with self.assertRaisesRegex(TimeoutError, "Cannot read Outlook taskbar buttons"):
            self.flow._buttons()
        self.assertEqual(self.flow._get_app_tray.call_count, 3)

    def test_duplicate_outlook_buttons_still_fail_without_retry(self):
        buttons = [
            self.button("Microsoft.Office.OUTLOOK.EXE.15"),
            self.button("Microsoft.Office.OUTLOOK.EXE.15"),
        ]
        self.flow._get_app_tray.return_value.find_elements_by_xpath.return_value = buttons
        with self.assertRaisesRegex(AssertionError, "Multiple taskbar buttons"):
            self.flow._buttons()
        self.flow._get_app_tray.assert_called_once()


class SwapFlowTests(unittest.TestCase):
    def make_flow(self, pinned, target="classic", apps=None, windows=None, flags=None):
        flow = scenario.OutlookSwap()
        flow.dut_exec_path = r"D:\hobl_bin"
        flow._upload = Mock()
        flow._startWinAppDriver = Mock()
        flow._launchDesktop = Mock(return_value=Mock())
        flow.events = []
        state = set(pinned)
        flow._pinned_versions = Mock(side_effect=lambda: set(state))
        flow._pin_app = Mock(side_effect=lambda name, kind: (
            flow.events.append(("pin", kind)), state.add(kind)
        ))
        flow._unpin = Mock(side_effect=lambda kind: (
            flow.events.append(("unpin", kind)), state.remove(kind)
        ))
        button = Mock()
        button.click.side_effect = lambda: flow.events.append(("launch", None))
        flow._button = Mock(return_value=button)

        def wait(predicate, message):
            value = predicate()
            if not value:
                raise AssertionError(message)
            return value

        flow._wait = wait
        inventory = {
            "Apps": apps if apps is not None else [
                {"Name": "Outlook (classic)", "AppID": "Microsoft.Office.OUTLOOK.EXE.15"},
                {"Name": "Outlook", "AppID":
                 "Microsoft.OutlookForWindows_8wekyb3d8bbwe!Microsoft.OutlookforWindows"},
            ],
            "OpenWindows": windows or [],
        }

        def helper(action, selected="classic"):
            if action == "Discover":
                return inventory
            flow.events.append(("complete", selected))
            return {"maximized": True, "closed": True}

        flow._helper = Mock(side_effect=helper)
        classic, outlook = flags if flags is not None else (
            ("0", "1") if target == "new" else ("1", "0")
        )
        parameters = {"outlook-classic": classic, "Outlook": outlook, "timeout": "60"}
        scenario.Params.get.side_effect = lambda section, key: parameters[key]
        return flow

    def run_flow(self, flow):
        with tempfile.TemporaryDirectory() as results:
            flow.result_dir = results
            flow.runTest()
            with open(os.path.join(results, "outlook_swap_results.csv"),
                      newline="", encoding="utf-8") as output:
                row = next(csv.DictReader(output))
        self.assertGreaterEqual(float(row["scenario_runtime"]), 0)
        return row

    def test_swap_in_both_directions(self):
        for source, target in [("classic", "new"), ("new", "classic")]:
            with self.subTest(source=source):
                flow = self.make_flow({source}, target)
                self.assertEqual(self.run_flow(flow)["target"], target)
                self.assertEqual(flow.events, [
                    ("pin", target), ("unpin", source),
                    ("launch", None), ("complete", target),
                ])

    def test_both_pinned_keeps_only_classic(self):
        flow = self.make_flow({"classic", "new"})
        self.assertEqual(self.run_flow(flow)["target"], "classic")
        flow._pin_app.assert_not_called()
        self.assertEqual(flow.events, [
            ("unpin", "new"), ("launch", None), ("complete", "classic"),
        ])

    def test_no_pins_defaults_to_classic(self):
        flow = self.make_flow(set())
        self.assertEqual(self.run_flow(flow)["target"], "classic")
        flow._pin_app.assert_called_once_with("Outlook (classic)", "classic")
        flow._unpin.assert_not_called()

    def test_all_parameter_combinations_for_every_pin_state(self):
        for pinned in [set(), {"classic"}, {"new"}, {"classic", "new"}]:
            for classic, outlook in [("0", "1"), ("1", "0"), ("0", "0"), ("1", "1")]:
                with self.subTest(pinned=pinned, classic=classic, outlook=outlook):
                    target = "new" if (classic, outlook) == ("0", "1") else "classic"
                    flow = self.make_flow(pinned, flags=(classic, outlook))
                    self.assertEqual(self.run_flow(flow)["target"], target)
                    self.assertEqual(flow._pinned_versions(), {target})
                    if target in pinned:
                        flow._pin_app.assert_not_called()

    def test_invalid_parameters_fail_before_contacting_dut(self):
        flow = self.make_flow({"classic"}, flags=("invalid", "1"))
        with self.assertRaisesRegex(ValueError, "must each be 0 or 1"):
            flow.runTest()
        flow._upload.assert_not_called()
        flow._helper.assert_not_called()
        self.assertEqual(flow.events, [])

    def test_explicit_already_pinned_still_launches(self):
        flow = self.make_flow({"classic"}, "classic")
        self.run_flow(flow)
        self.assertEqual(flow.events, [("launch", None), ("complete", "classic")])

    def test_existing_windows_are_not_closed(self):
        flow = self.make_flow({"classic"}, windows=[{"Id": 123}])
        with self.assertRaisesRegex(AssertionError, "Close existing Outlook"):
            flow.runTest()
        flow._startWinAppDriver.assert_not_called()
        self.assertEqual(flow.events, [])

    def test_missing_or_ambiguous_installation_preserves_pins(self):
        for apps in [[], [
            {"Name": "Outlook", "AppID": "Microsoft.OutlookForWindows_test!App"},
            {"Name": "Other Outlook", "AppID": "Microsoft.OutlookForWindows_test2!App"},
        ]]:
            with self.subTest(apps=apps):
                flow = self.make_flow({"classic"}, "new", apps=apps)
                with self.assertRaisesRegex(AssertionError, "Expected one installed"):
                    flow.runTest()
                self.assertEqual(flow.events, [])

    def test_pin_failure_does_not_remove_original_pin_or_launch(self):
        flow = self.make_flow({"classic"}, "new")
        flow._pin_app.side_effect = RuntimeError("Pin blocked by policy")
        with self.assertRaisesRegex(RuntimeError, "blocked by policy"):
            flow.runTest()
        flow._unpin.assert_not_called()
        flow._button.assert_not_called()

    def test_duplicate_display_names_do_not_pin_the_wrong_app(self):
        flow = self.make_flow({"classic"}, "new", apps=[
            {"Name": "Outlook", "AppID": "Microsoft.Office.OUTLOOK.EXE.15"},
            {"Name": "Outlook", "AppID": "Microsoft.OutlookForWindows_test!App"},
        ])
        with self.assertRaisesRegex(AssertionError, "display names are ambiguous"):
            flow.runTest()
        self.assertEqual(flow.events, [])

    def test_close_failure_does_not_write_success_results(self):
        flow = self.make_flow({"classic"})
        original = flow._helper.side_effect

        def helper(action, selected="classic"):
            if action == "Complete":
                raise RuntimeError("Close blocked")
            return original(action, selected)

        flow._helper.side_effect = helper
        with tempfile.TemporaryDirectory() as results:
            flow.result_dir = results
            with self.assertRaisesRegex(RuntimeError, "Close blocked"):
                flow.runTest()
            self.assertFalse(os.path.exists(
                os.path.join(results, "outlook_swap_results.csv")
            ))

    def test_running_taskbar_button_is_not_counted_as_pinned(self):
        flow = scenario.OutlookSwap()
        flow._buttons = Mock(return_value={"classic": Mock(), "new": Mock()})
        flow._pin_state = Mock(side_effect=lambda kind: kind == "classic")
        self.assertEqual(flow._pinned_versions(), {"classic"})

    def test_encoded_helper_command_and_timeout(self):
        import base64
        flow = scenario.OutlookSwap()
        flow.helper = r"D:\hobl bin\Outlook_Swap\outlook_window.ps1"
        flow.ui_timeout = 60
        flow._call = Mock(return_value=json.dumps({"closed": True}))
        self.assertEqual(flow._helper("Complete", "new"), {"closed": True})
        arguments = flow._call.call_args.args[0]
        command = base64.b64decode(arguments[1].split()[-1]).decode("utf-16-le")
        self.assertIn("-Action Complete -Target new -TimeoutSeconds 60", command)
        self.assertIn(flow.helper, command)
        self.assertEqual(flow._call.call_args.kwargs["timeout"], 210)
        flow._helper("Discover")
        self.assertEqual(flow._call.call_args.kwargs["timeout"], 210)

    def test_pinning_uses_apps_folder_without_launching_outlook(self):
        flow = scenario.OutlookSwap()
        folder = Mock()
        folder.get_attribute.return_value = "123"
        app = Mock()
        folder.find_elements_by_name.return_value = []
        flow.desktop = Mock()
        flow.desktop.find_elements_by_class_name.side_effect = [[], [folder]]
        flow._call = Mock()
        flow._wait = lambda predicate, message: predicate()
        pin = Mock()
        flow._menu_item = Mock(return_value=pin)
        flow._pinned_versions = Mock(return_value={"new"})
        folder_driver = Mock()
        folder_driver.find_element_by_name.return_value = app
        flow.getDriverFromWin = Mock(return_value=folder_driver)
        with patch.object(scenario, "ActionChains") as actions:
            def find_app(name):
                actions.return_value.send_keys.assert_called_once_with("Outlook")
                actions.return_value.send_keys.return_value.perform.assert_called_once()
                return app

            folder_driver.find_element_by_name.side_effect = find_app
            flow._pin_app("Outlook", "new")
            actions.return_value.context_click.assert_called_once_with(app)
            actions.return_value.context_click.return_value.perform.assert_called_once()
            actions.return_value.key_down.assert_not_called()
            self.assertIn(
                ((folder_driver,), {}), actions.call_args_list
            )
        flow._call.assert_called_once_with(
            ["explorer.exe", "/n,shell:AppsFolder"], blocking=False
        )
        folder.find_elements_by_name.assert_not_called()
        folder_driver.find_element_by_name.assert_called_once_with("Outlook")
        app.click.assert_called_once()
        pin.click.assert_called_once()
        folder_driver.close.assert_called_once()
        folder_driver.quit.assert_called_once()

    def test_missing_apps_folder_item_fails_and_closes_owned_window(self):
        flow = scenario.OutlookSwap()
        folder = Mock()
        folder.get_attribute.return_value = "123"
        flow.desktop = Mock()
        flow.desktop.find_elements_by_class_name.side_effect = [[], [folder]]
        flow._call = Mock()
        flow._wait = lambda predicate, message: predicate()
        folder_driver = Mock()
        folder_driver.find_element_by_name.side_effect = scenario.NoSuchElementException(
            "Outlook item unavailable"
        )
        flow.getDriverFromWin = Mock(return_value=folder_driver)
        flow._dismiss_menu = Mock()
        flow._pinned_versions = Mock()
        with self.assertRaisesRegex(scenario.NoSuchElementException, "unavailable"):
            flow._pin_app("Outlook", "new")
        flow._pinned_versions.assert_not_called()
        folder_driver.close.assert_called_once()
        folder_driver.quit.assert_called_once()


if __name__ == "__main__":
    unittest.main()
