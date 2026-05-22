# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# Calculates the charge time from 5% (or test start if above 5%) to various thresholds, defaulted to 80%, 90%, 100%.
# Setup instructions:
#   None
##

import logging
import os
import time
import csv
import core.app_scenario
from core.parameters import Params


class RechargeMeasured(core.app_scenario.Scenario):

    module = __module__.split('.')[-1]
    # Set default parameters
    Params.setDefault(module, 'resume_threshold', '100', desc="Battery level at which to end the test.")
    Params.setDefault('charge_on', 'charge_on_call', '')
    Params.setDefault('charge_off', 'charge_off_call', '')
    Params.setDefault(module, 'delay_til_5_percent', '1', valOptions=["0", "1"], desc="Whether to delay the start of the test until battery level is at or below 5%")
    Params.setDefault(module, 'leave_on_ac', '1', valOptions=["0", "1"], desc="Whether to leave the device on AC power after charging")

    # Get parameters
    charge_on_call = Params.get('charge_on', 'charge_on_call')
    charge_off_call = Params.get('charge_off', 'charge_off_call')
    resume_threshold = Params.get(module, 'resume_threshold')
    delay_til_5_percent = Params.get(module, 'delay_til_5_percent')
    leave_on_ac = Params.get(module, 'leave_on_ac')

    # Local parameters
    prep_scenarios = []

    def setUp(self):
        # Get parameters
        platform = Params.get('global', 'platform').lower()
        
        # minimize any windows
        if platform == 'windows':
            self._call(["powershell.exe", '-command "$x = New-Object -ComObject Shell.Application; $x.minimizeall()"'])
        core.app_scenario.Scenario.setUp(self)

        # See if we need to delay the start of test until battery level is at 5% or below.
        self.delay_til_5_percent_check()

    def runTest(self):
        self.trace_path = os.path.join(self.result_dir, "battery_level.trace")
        with open(self.trace_path, "w") as trace_file:
            trace_file.write("time,battery_level\n")
        
        # Turn on charger
        if self.charge_on_call != '':
            self._host_call(self.charge_on_call)
        else:
            logging.warning("No charge_on_call specified. Charger may not be on.")

        # Get the starting time as the referene point. Loop every minute to read the battery level to see if it reached the threshold. 
        test_start_time = time.time()
        while True:
            try:
                batt_level = self._call(["powershell.exe", "Add-Type -Assembly System.Windows.Forms; [Math]::round(([System.Windows.Forms.SystemInformation]::PowerStatus.BatteryLifePercent) * 100, 2)"])
            except:
                logging.info("Couldn't read battery level")
                time.sleep(60)
                continue          
            logging.info("Battery level: " + str(batt_level) + "  Expected Level: " + str(self.resume_threshold))

            # Log battery level with elapsed seconds from test start for analysis
            elapsed_seconds = int(time.time() - test_start_time)
            with open(self.trace_path, "a") as trace_file:
                trace_file.write(f"{elapsed_seconds}, {batt_level}\n")

            if int(batt_level) >= int(self.resume_threshold):
                logging.info("Charging complete")
                if (self.leave_on_ac == '0'):
                    if self.charge_off_call != '':
                        self._host_call(self.charge_off_call)
                    else:
                        logging.warning("No charge_off_call specified. Charger may not be turned off.")
                break
            time.sleep(60)


    def tearDown(self):
        # Parse trace file to get total time taken to charge from start to various thresholds
        if not os.path.exists(self.trace_path):
            logging.warning("No battery_level.trace file found, skipping charge time analysis.")
        elif os.path.getsize(self.trace_path) == 0:
            logging.warning("Trace file is empty, skipping charge time analysis.")
        else:
            entries = []
            with open(self.trace_path, "r") as f:
                next(f)  # skip header
                for line in f:
                    elapsed, level = line.split(",")
                    entries.append((int(elapsed), int(float(level))))
            if not entries:
                logging.warning("Trace file has no data rows, skipping charge time analysis.")
            else:
                # Determine start time: find when battery first hits 5% (or use first entry if already above 5%)
                start_time = entries[0][0]  # elapsed seconds when first entry was recorded
                start_level = entries[0][1]
                for timestamp, level in entries:
                    if level >= 5:
                        start_time = timestamp
                        start_level = level
                        break


                # Determine which thresholds to report
                if int(self.resume_threshold) < 80 or start_level > 10:
                    thresholds = [int(self.resume_threshold)]
                else:
                    thresholds = [80, 90, 100]

                # Find time to reach each threshold
                charge_times = {}
                for threshold in thresholds:
                    reached_time = None
                    for timestamp, level in entries:
                        if level >= threshold:
                            reached_time = timestamp
                            break
                    if reached_time is not None:
                        elapsed_seconds = reached_time - start_time
                        elapsed_minutes = elapsed_seconds / 60
                        logging.info(f"Time to charge from {start_level}% to {threshold}%: {elapsed_seconds} seconds ({elapsed_minutes:.2f} minutes)")
                        charge_times[threshold] = elapsed_seconds
                    else:
                        logging.info(f"Battery never reached {threshold}% during this session.")

                # Write charge times to CSV
                csv_path = os.path.join(self.result_dir, "charge_time_result.csv")
                with open(csv_path, "w", newline='') as csv_file:
                    csv_writer = csv.writer(csv_file)
                    csv_writer.writerow([f"{'Charge Range'}", "Elapsed Seconds"])
                    for threshold in thresholds:
                        seconds = charge_times.get(threshold)
                        label = f"{start_level}-{threshold}"
                        csv_writer.writerow([f"{label}", seconds])

        # Prevent callback_test_end from executing in base tearDown() method
        core.app_scenario.Scenario.tearDown(self, callback_test_end="")

    def delay_til_5_percent_check(self):
        if self.delay_til_5_percent == '1':
            logging.info("Delaying test start until battery level is at or below 5%")
            while True:
                try:
                    batt_level = self._call(["powershell.exe", "Add-Type -Assembly System.Windows.Forms; [Math]::round(([System.Windows.Forms.SystemInformation]::PowerStatus.BatteryLifePercent) * 100, 2)"])
                except:
                    logging.info("Couldn't read battery level")
                    time.sleep(30)
                    continue          
                if int(batt_level) <= 5:
                    logging.info("Battery level is at or below 5%, starting test.")
                    break
                time.sleep(30)