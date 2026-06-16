# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

# Check battery level and recharge when below specified threshold

from builtins import *
from core.parameters import Params
from core.app_scenario import Scenario
import logging
import time
import subprocess
import threading

class Tool(Scenario):
    '''
    Pause run and recharge device when battery drops below [charge_threshold], then resume.

    Pass charge_on_call and charge_off_call as auto_recharge parameters. If the command
    points to a .ps1 script it will be wrapped with powershell.exe automatically, e.g.:
      auto_recharge:charge_on_call=C:\pdu_controller\apc_pdu_controller.ps1 on 6 -PduIp 10.150.18.38 -Community hobl
      auto_recharge:charge_off_call=C:\pdu_controller\apc_pdu_controller.ps1 off 6 -PduIp 10.150.18.38 -Community hobl
    '''
    module = __module__.split('.')[-1]
    # Set default parameters
    Params.setDefault(module, 'charge_threshold', '40')  # Percent battery level (40%)
    Params.setDefault(module, 'resume_threshold', '95')  # Percent battery level (95%)
    Params.setDefault(module, 'charge_on_call', '')
    Params.setDefault(module, 'charge_off_call', '')

    # Get parameters
    charge_threshold = Params.get(module, 'charge_threshold')
    resume_threshold = Params.get(module, 'resume_threshold')

    already_started = False
    _monitor_stop = None  # threading.Event to stop background monitor
    _charge_event = None  # threading.Event: set=OK to proceed, clear=charging in progress

    def testBeginEarlyCallback(self, scenario):
        self.initCallback(scenario)
        self.already_started = True

    def initCallback(self, scenario):
        if self.already_started:
            return
        MAX_COUNT = 10
        count = 0

        logging.info(f"auto_recharge thresholds: charge_threshold={self.charge_threshold}%, resume_threshold={self.resume_threshold}%")
        batt_level = self.getBattLevel()
        logging.info("Battery level: " + batt_level)

        if int(batt_level) <= int(self.charge_threshold):
            logging.info("Charging...")
            # Start charging and wait until resume_threshold reached
            self.chargeOn()

            old_batt_level = -1
            # TODO: handle errors
            while True:
                # Wait before polling so the device has time to actually charge
                time.sleep(300)  # sleep 5 minutes
                try:
                    batt_level = self.getBattLevel()
                except:
                    continue
                logging.info("Battery level: " + batt_level)
                if int(batt_level) >= int(self.resume_threshold):
                    logging.info("Charging complete")
                    # Disengage charging
                    self.chargeOff()
                    # TODO: handle errors
                    break
                else:
                    if batt_level == old_batt_level:
                        count += 1
                        logging.info("Seeing same battery level for " + str(count) + " times.")
                    else:
                        count = 0
                    if count == MAX_COUNT:
                        logging.info(f"Disengaging charger since seeing same battery level for {MAX_COUNT} times.")
                        self.chargeOff()
                        break
                    old_batt_level = batt_level
            try:
                delay = int(self.post_charge_delay)
            except:
                logging.error(f"Invalid post_charge_delay setting: {self.post_charge_delay}.  Make sure it's an integer.")
            else:
                logging.info(f"Delaying for {delay} seconds to let device quiesce.")
                time.sleep(delay)

        # Start background thread that polls battery every 60s during the scenario
        self._charge_event = threading.Event()
        self._charge_event.set()  # Initially not charging
        self._monitor_stop = threading.Event()
        monitor_thread = threading.Thread(
            target=self._battery_monitor_loop,
            args=(self._monitor_stop,),
            daemon=True
        )
        monitor_thread.start()
        logging.info("auto_recharge: background battery monitor started (polling every 60s).")

    def testBeginCallback(self):
        # Block scenario start if a charge cycle is in progress
        if self._charge_event is not None and not self._charge_event.is_set():
            logging.info("auto_recharge: battery charging in progress — pausing scenario until resume_threshold is reached...")
            self._charge_event.wait()
            logging.info("auto_recharge: charging complete, resuming scenario.")

    def testEndCallback(self):
        if self._monitor_stop is not None:
            self._monitor_stop.set()
            logging.info("auto_recharge: background battery monitor stopped.")

    def _battery_monitor_loop(self, stop_event, poll_interval=60):
        """Background thread: polls battery every poll_interval seconds.
        When battery <= charge_threshold: calls chargeOn, clears _charge_event to block
        scenario iterations, polls every 5 min until resume_threshold, then calls
        chargeOff and sets _charge_event to unblock the scenario.
        """
        MAX_COUNT = 10
        logging.info(f"auto_recharge monitor: polling every {poll_interval}s.")
        while not stop_event.is_set():
            stop_event.wait(poll_interval)
            if stop_event.is_set():
                break
            try:
                batt_level = self.getBattLevel()
            except Exception as e:
                logging.warning(f"auto_recharge monitor: getBattLevel failed: {e}")
                continue
            logging.info(f"auto_recharge monitor: Battery level: {batt_level}%")
            if int(batt_level) <= int(self.charge_threshold):
                logging.info(f"auto_recharge monitor: Battery {batt_level}% <= threshold {self.charge_threshold}%, starting charge.")
                self._charge_event.clear()  # Pause scenario at next testBeginCallback
                self.chargeOn()
                count = 0
                old_batt_level = -1
                while not stop_event.is_set():
                    stop_event.wait(300)  # poll every 5 minutes while charging
                    if stop_event.is_set():
                        break
                    try:
                        batt_level = self.getBattLevel()
                    except Exception as e:
                        logging.warning(f"auto_recharge monitor: getBattLevel failed during charge: {e}")
                        continue
                    logging.info(f"auto_recharge monitor: Battery level during charge: {batt_level}%")
                    if int(batt_level) >= int(self.resume_threshold):
                        logging.info(f"auto_recharge monitor: Battery {batt_level}% >= resume_threshold {self.resume_threshold}%, stopping charge.")
                        self.chargeOff()
                        self._charge_event.set()  # Resume scenario
                        break
                    if batt_level == old_batt_level:
                        count += 1
                        logging.info(f"auto_recharge monitor: Same battery level for {count} polls.")
                    else:
                        count = 0
                    if count == MAX_COUNT:
                        logging.info(f"auto_recharge monitor: Battery stuck at {batt_level}% for {MAX_COUNT} polls, stopping charge.")
                        self.chargeOff()
                        self._charge_event.set()  # Resume scenario
                        break
                    old_batt_level = batt_level

    def dataReadyCallback(self):
        pass

    def getBattLevel(self):
        if self.platform.lower() == "android":
            command = "adb "
            # if device_ip is not None:
            command = command + "-s " + str(self.dut_ip) + ":5555 "
            command = command + "shell \"dumpsys battery | grep 'level'|cut -f2 -d ':'\""
            p = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell = True)
            out, err = p.communicate()
            actual_exit_code = p.returncode
            batt_level = str(out.decode('utf-8').rstrip())
        else:
            batt_level = self._call(["powershell.exe", "Add-Type -Assembly System.Windows.Forms; [Math]::round(([System.Windows.Forms.SystemInformation]::PowerStatus.BatteryLifePercent) * 100, 2)"])
        return batt_level

    def chargeOn(self):
        logging.info("Attempting to turn on charger...")
        call = Params.get(self.module, 'charge_on_call') or ''
        logging.info(f"auto_recharge: charge_on_call resolved to: {repr(call)}")
        if call:
            self._host_call(self._wrap_ps1(call))
            if Params.get('global', 'local_execution') == '1':
                self._host_call('utilities\\MsgPrompt.exe -WaitForAC')
            else:
                self._wait_for_power_line_status(target='AC')
        else:
            logging.warning("No charge_on_call specified.")
        logging.info("Charger on.")

    def chargeOff(self):
        logging.info("Attempting to turn off charger...")
        call = Params.get(self.module, 'charge_off_call') or ''
        logging.info(f"auto_recharge: charge_off_call resolved to: {repr(call)}")
        if call:
            self._host_call(self._wrap_ps1(call))
            if Params.get('global', 'local_execution') == '1':
                self._host_call('utilities\\MsgPrompt.exe -WaitForDC')
            else:
                self._wait_for_power_line_status(target='DC')
        else:
            logging.warning("No charge_off_call specified.")
        logging.info("Charger off.")

    def _wrap_ps1(self, call):
        '''If the call targets a .ps1 script, prepend powershell.exe so that
        cmd.exe (used by _host_call via shell=True) can execute it.
        Example input:  C:\\pdu_controller\\script.ps1 off 7 -PduIp 10.0.0.1
        Example output: powershell.exe -ExecutionPolicy Bypass -File "C:\\pdu_controller\\script.ps1" off 7 -PduIp 10.0.0.1
        '''
        stripped = call.strip().strip('"')
        first_token = stripped.split()[0] if stripped else ''
        if first_token.lower().endswith('.ps1'):
            rest = stripped[len(first_token):].lstrip()
            args_suffix = f' {rest}' if rest else ''
            return f'powershell.exe -ExecutionPolicy Bypass -File "{first_token}"{args_suffix}'
        return call

    def _wait_for_power_line_status(self, target, poll_interval=10, max_wait=120):
        '''Poll Windows PowerLineStatus until it matches target ('AC' or 'DC').
        This confirms the OS has detected the charger state change before
        continuing — avoids reading stale battery levels right after a PDU switch.
        '''
        ps_cmd = ("Add-Type -Assembly System.Windows.Forms; "
                  "[System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus.ToString()")
        logging.info(f"Waiting for PowerLineStatus={target} (max {max_wait}s)...")
        elapsed = 0
        while elapsed < max_wait:
            status = self._call(["powershell.exe", ps_cmd]).strip()
            logging.info(f"PowerLineStatus: {status}")
            if status == target:
                logging.info(f"PowerLineStatus confirmed: {target}")
                return
            time.sleep(poll_interval)
            elapsed += poll_interval
        logging.warning(f"PowerLineStatus did not reach {target} within {max_wait}s, continuing anyway.")
