# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os
import re
import core.app_scenario
from core.parameters import Params
import time


class Iperf3(core.app_scenario.Scenario):
    """
    Runs iperf3 network throughput tests against a remote server while measuring power.

    Supports four predefined test profiles (T1-T4) drawn from the iperf3 test matrix, plus
    a 'custom' option that accepts any iperf3 argument string. Power/performance collection
    is enabled so each run captures the power impact of the traffic pattern alongside the
    raw throughput numbers.

    The scenario blocks on iperf3's process exit (expected exit code 0). The duration
    parameter feeds the -t flag in the command; it does not drive any internal timer.

    Results written to the run directory:
        iperf3_output.txt  —  raw iperf3 console output (stdout + stderr)
        iperf3.csv         —  parsed key metrics (throughput, jitter, packet loss)
    """

    module = __module__.split('.')[-1]

    Params.setDefault(module, 'server_ip', '',
                      desc="IP address of the iperf3 server (required for T1-T4)")
    Params.setDefault(module, 'test_type', 'T1',
                      desc="Test profile to run: T1, T2, T3, T4, or custom",
                      valOptions=['T1', 'T2', 'T3', 'T4', 'custom'])
    Params.setDefault(module, 'custom_arguments', '',
                      desc="Full iperf3 argument string when test_type='custom'. "
                           "Include everything after 'iperf3', e.g. '-c 192.168.1.1 -u -b100M -t 60'. "
                           "Ignored for T1-T4.")
    Params.setDefault(module, 'duration', '300',
                      desc="Seconds passed to iperf3 via -t (T1-T4 only). "
                           "Also used to size the call timeout safety net for custom tests.")
    Params.setDefault(module, 'wlan_logging', '0',
                      desc="Set to '1' to capture Wi-Fi layer telemetry alongside iperf3. "
                           "Logs adapter error/discard counter deltas (Get-NetAdapterStatistics), "
                           "a 5-second channel/RSSI/rate poll time series, and WLAN AutoConfig "
                           "event log entries (connects, disconnects, roaming, channel switches). "
                           "Adds wlan_*.txt / wlan_events.csv to the results directory and "
                           "appends wlan_* metrics to iperf3.csv.",
                      valOptions=['0', '1'])

    # Enable power and performance measurement alongside the iperf3 run
    Params.setOverride("global", "collection_enabled", "1")

    prep_scenarios = []

    # Host-side path to iperf3 distribution (iperf3.exe + wlan_monitor.ps1 + any DLLs)
    # _HOST_IPERF3_DIR       = "utilities\\open_source\\iperf3"
    # Paths on DUT after upload
    _DUT_IPERF3_EXE        = "c:\\hobl_bin\\iperf3_resources\\iperf3.exe"
    _DUT_WLAN_MONITOR_PS1  = "c:\\hobl_bin\\iperf3_resources\\wlan_monitor.ps1"
    _OUT_FILENAME          = "iperf3_output.txt"

    # Files written by wlan_monitor.ps1 that are copied back when wlan_logging=1
    _WLAN_FILES = [
        'wlan_stats_before.csv',
        'wlan_stats_after.csv',
        'wlan_iface_before.csv',
        'wlan_iface_after.csv',
        'wlan_poll.txt',
        'wlan_events.txt',
    ]

    # Predefined argument templates — {server_ip} and {duration} substituted at runtime.
    # Parameters match the iperf3 test matrix (Main_test_Matrix sheet).
    _TEST_ARGS = {
        # T1: TCP TX — Sustained maximum throughput; 8 parallel streams, 256 MB socket buffer
        'T1': '-c {server_ip} -w256M -l64000 -P8 -t {duration} -O 5',
        # T2: TCP RX — Same as T1 but server sends, client receives (-R flag)
        'T2': '-c {server_ip} -R -w256M -l64000 -P8 -t {duration} -O 5',
        # T3: UDP TX — Fixed 50 Mbps rate; measures loss and jitter on the TX path
        'T3': '-c {server_ip} -u -b50M -w64M -l64000 -t {duration} -O 5',
        # T4: UDP RX — Same as T3 but server sends, client receives (-R flag)
        'T4': '-c {server_ip} -R -u -b50M -w64M -l64000 -t {duration} -O 5',
    }

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def setUp(self):
        self.server_ip        = Params.get(self.module, 'server_ip')
        self.test_type        = Params.get(self.module, 'test_type')
        self.custom_arguments = Params.get(self.module, 'custom_arguments')
        self.duration         = int(Params.get(self.module, 'duration'))
        self.wlan_logging     = Params.get(self.module, 'wlan_logging') == '1'

        if self.test_type != 'custom' and not self.server_ip:
            raise ValueError(
                "server_ip is required for test types T1-T4. "
                "Set it in the [iperf3] section of your profile INI."
            )

        # Get neccessary paths for downloading and unzipping iperf3 files.
        scenario_dir = os.path.dirname(os.path.abspath(__file__))
        zip_file     = os.path.join(scenario_dir, 'iperf3.zip')
        extract_dir  = os.path.join(scenario_dir, 'iperf3_resources')

        # Download the zip into this scenario's directory if not already present.
        self._check_and_download('iperf3.zip', scenario_dir, url='https://github.com/ar51an/iperf3-win-builds/releases/download/3.21/iperf-3.21-win64.zip')

        # Extract into iperf3_resources/ next to this file.
        os.makedirs(extract_dir, exist_ok=True)
        try:
            # Extract the zip file
            self._host_call("cmd.exe /C " + f"tar -xf {zip_file} -C {extract_dir}", expected_exit_code="")
        except:
            logging.debug("Could already being extracted, wait for extraction to finish")
        

        # Upload iperf3.exe, wlan_monitor.ps1, and any companion DLLs from the host
        # utilities directory to C:\hobl_bin\iperf3\ on the DUT.
        logging.info(f"Uploading iperf3 from '{extract_dir}' to '{self.dut_exec_path}'")
        self._upload(extract_dir, self.dut_exec_path)

        if self.wlan_logging:
            logging.info(
                "WLAN logging enabled — retry counters, channel/RSSI poll, and "
                "AutoConfig event log will be captured alongside iperf3."
            )

        super().setUp()

    def runTest(self):
        arguments = self._build_arguments()
        out_path  = f"{self.dut_data_path}\\{self._OUT_FILENAME}"

        # The scenario completes when iperf3 exits with code 0. The timeout is a safety
        # net only — duration + 5 min for T1-T4; 1 hour for custom (unknown duration).
        timeout_s = self.duration + 300 if self.test_type != 'custom' else 3600

        if self.wlan_logging:
            # Delegate to wlan_monitor.ps1, which wraps iperf3 with pre/post stat
            # snapshots, a 5-second background interface poller, and an event log query.
            # The script exits with iperf3's own exit code so the framework check works.
            ps1_args = (
                f'-ExecutionPolicy Bypass -File "{self._DUT_WLAN_MONITOR_PS1}" '
                f'-IpeRf3Exe "{self._DUT_IPERF3_EXE}" '
                f'-IpeRf3Args "{arguments}" '
                f'-OutPath "{out_path}" '
                f'-DataPath "{self.dut_data_path}"'
            )
            logging.info(
                f"Starting iperf3 [{self.test_type}] with WLAN monitoring: "
                f"{self._DUT_IPERF3_EXE} {arguments}"
            )
            self._call(["powershell.exe", ps1_args], timeout=timeout_s, expected_exit_code="0")
        else:
            cmd = f'/c {self._DUT_IPERF3_EXE} {arguments} > {out_path} 2>&1'
            logging.info(f"Starting iperf3 [{self.test_type}]: {self._DUT_IPERF3_EXE} {arguments}")
            self._call(["cmd.exe", cmd], timeout=timeout_s, expected_exit_code="0")

        logging.info("iperf3 exited cleanly.")

    def tearDown(self):
        # Download the raw iperf3 output from the DUT
        self._copy_data_from_remote(
            dest=self.result_dir,
            source=f"{self.dut_data_path}\\{self._OUT_FILENAME}",
            single_file=True,
        )

        # Parse iperf3 output and write the summary CSV
        output_file = os.path.join(self.result_dir, self._OUT_FILENAME)
        metrics     = self._parse_iperf3_output(output_file)
        self._write_metrics_csv(metrics)

        if self.wlan_logging:
            # Retrieve all WLAN telemetry files written by wlan_monitor.ps1
            for fname in self._WLAN_FILES:
                self._copy_data_from_remote(
                    dest=self.result_dir,
                    source=f"{self.dut_data_path}\\{fname}",
                    single_file=True,
                )
            # Parse the before/after stat snapshots and event log; append to iperf3.csv
            self._parse_wlan_delta()

        super().tearDown()

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _build_arguments(self):
        """Return the iperf3 argument string for the configured test type."""
        if self.test_type == 'custom':
            if not self.custom_arguments.strip():
                raise ValueError(
                    "test_type is 'custom' but custom_arguments is empty. "
                    "Provide a full iperf3 argument string in the [iperf3] section of your profile. "
                    "Example:  custom_arguments: -c 192.168.1.1 -u -b100M -t 60"
                )
            return self.custom_arguments.strip()

        if self.test_type not in self._TEST_ARGS:
            raise ValueError(
                f"Unknown test_type '{self.test_type}'. Valid values: T1, T2, T3, T4, custom."
            )

        return self._TEST_ARGS[self.test_type].format(
            server_ip=self.server_ip,
            duration=self.duration,
        )

    def _parse_iperf3_output(self, output_file):
        """
        Parse an iperf3 output file and return a dict of metrics.

        TCP tests produce 'sender' and 'receiver' throughput lines.
        UDP tests produce throughput, jitter (ms), and packet loss (%) lines.
        Both are captured; keys not present for a given protocol are simply omitted.
        """
        metrics = {
            'iperf3_test_type' : self.test_type,
            'server_ip' : self.server_ip,
            'duration_s': self.duration,
        }

        try:
            with open(output_file, 'r', encoding='utf-8', errors='replace') as f:
                content = f.read()
        except FileNotFoundError:
            logging.error(f"iperf3 output file not found: {output_file}")
            return metrics

        # ------------------------------------------------------------------
        # TCP: summary lines end with 'sender' or 'receiver'.
        # With -P8 (parallel streams) iperf3 prints per-stream lines and a
        # [SUM] line — iterating finditer means the last sender/receiver match
        # is always the final [SUM] summary, which is what we want.
        #
        # Example:
        #   [SUM]   0.00-300.00 sec   338 GBytes  9.69 Gbits/sec  842   sender
        #   [SUM]   0.00-300.00 sec   337 GBytes  9.67 Gbits/sec         receiver
        # ------------------------------------------------------------------
        tcp_re = re.compile(
            r'\[\s*(?:\d+|SUM)\]\s+[\d.]+-[\d.]+\s+sec\s+[\d.]+\s+\w+Bytes\s+'
            r'([\d.]+)\s+(\w+bits/sec).*?(sender|receiver)',
            re.IGNORECASE,
        )
        for m in tcp_re.finditer(content):
            val, unit, role = m.group(1), m.group(2), m.group(3).lower()
            if role == 'sender':
                metrics['throughput_sender']      = float(val)
                metrics['throughput_sender_unit'] = unit
            else:
                metrics['throughput_receiver']      = float(val)
                metrics['throughput_receiver_unit'] = unit

        # ------------------------------------------------------------------
        # UDP: summary line includes jitter (ms) and lost/total datagrams with loss %.
        # We keep the last match, which is the final summary interval.
        #
        # Example:
        #   [  5]   0.00-300.00 sec  17.9 GBytes  50.0 Mbits/sec  1.200 ms  15/14648 (0.10%)
        # ------------------------------------------------------------------
        udp_re = re.compile(
            r'\[\s*(?:\d+|SUM)\]\s+[\d.]+-[\d.]+\s+sec\s+[\d.]+\s+\w+Bytes\s+'
            r'([\d.]+)\s+(\w+bits/sec)\s+([\d.]+)\s+ms\s+[\d]+/[\d]+\s+\(([\d.]+)%\)'
        )
        last_udp = None
        for m in udp_re.finditer(content):
            last_udp = m

        if last_udp:
            metrics['throughput']      = float(last_udp.group(1))
            metrics['throughput_unit'] = last_udp.group(2)
            metrics['jitter_ms']       = float(last_udp.group(3))
            metrics['loss_pct']        = float(last_udp.group(4))

        logging.info(f"iperf3 parsed metrics: {metrics}")
        return metrics

    def _write_metrics_csv(self, metrics):
        """Write the parsed metrics dict to iperf3.csv in the results directory."""
        csv_path = os.path.join(self.result_dir, 'iperf3.csv')
        with open(csv_path, 'w') as f:
            for key, val in metrics.items():
                f.write(f"{key},{val}\n")
        logging.info(f"iperf3 metrics written to {csv_path}")

    def _parse_wlan_delta(self):
        """
        Parse the WLAN telemetry files written by wlan_monitor.ps1 and append
        the derived metrics to iperf3.csv.

        Metrics produced
        ----------------
        wlan_outbound_errors_delta   -- outbound packet errors (proxy for TX retries/failures)
        wlan_outbound_discard_delta  -- outbound packets discarded (e.g. buffer overflow)
        wlan_inbound_errors_delta    -- inbound packet errors
        wlan_inbound_discard_delta   -- inbound packets discarded
        wlan_event_connect           -- number of (re)association events
        wlan_event_disconnect        -- number of disassociation events
        wlan_event_roam_start        -- roaming sequences initiated
        wlan_event_roam_success      -- roaming sequences completed
        wlan_event_channel_switch    -- channel switch notifications received

        Note: Get-NetAdapterStatistics is used rather than netsh wlan show statistics
        because the netsh wlan subcommand is inaccessible in restricted service-account
        contexts. The error/discard counters are proxy indicators of retry pressure.
        """
        # ------------------------------------------------------------------
        # Adapter error/discard counters — diff the before/after snapshots.
        # The stats file written by wlan_monitor.ps1 uses explicit "Key : Value"
        # lines, e.g.:  OutboundPacketErrors     : 42
        # ------------------------------------------------------------------
        stat_re = re.compile(r'(\w+)\s*,\s*(\d+)\s*$', re.MULTILINE)

        counters_of_interest = {
            'OutboundPacketErrors'     : 'wlan_outbound_errors_delta',
            'OutboundDiscardedPackets' : 'wlan_outbound_discard_delta',
            'ReceivedPacketErrors'     : 'wlan_inbound_errors_delta',
            'ReceivedDiscardedPackets' : 'wlan_inbound_discard_delta',
        }

        def _read_stats(filename):
            path = os.path.join(self.result_dir, filename)
            try:
                with open(path, 'r', encoding='utf-8', errors='replace') as f:
                    return f.read()
            except FileNotFoundError:
                logging.warning(f"WLAN stats file not found: {path}")
                return ''

        def _extract_totals(content):
            """Return {field_name: int} for all matched Key : Value rows."""
            return {
                m.group(1).strip(): int(m.group(2))
                for m in stat_re.finditer(content)
            }

        before = _extract_totals(_read_stats('wlan_stats_before.csv'))
        after  = _extract_totals(_read_stats('wlan_stats_after.csv'))

        wlan_metrics = {}
        for stat_name, csv_key in counters_of_interest.items():
            delta = after.get(stat_name, 0) - before.get(stat_name, 0)
            # Counters are cumulative; clamp negatives from adapter resets mid-run.
            wlan_metrics[csv_key] = max(0, delta)

        # ------------------------------------------------------------------
        # WLAN AutoConfig event log — count occurrences by event ID
        # ------------------------------------------------------------------
        events_path = os.path.join(self.result_dir, 'wlan_events.txt')
        event_map = {
            '8001' : 'wlan_event_connect',
            '8002' : 'wlan_event_disconnect',
            '11001': 'wlan_event_roam_start',
            '11004': 'wlan_event_roam_success',
            '20019': 'wlan_event_channel_switch',
        }
        for csv_key in event_map.values():
            wlan_metrics[csv_key] = 0

        try:
            with open(events_path, 'r', encoding='utf-8', errors='replace') as f:
                for line in f:
                    for eid, csv_key in event_map.items():
                        # CSV rows contain the event ID as a standalone field
                        if f',{eid},' in line:
                            wlan_metrics[csv_key] += 1
        except FileNotFoundError:
            logging.warning(f"wlan_events.txt not found: {events_path}")

        # ------------------------------------------------------------------
        # Append to iperf3.csv (written earlier by _write_metrics_csv)
        # ------------------------------------------------------------------
        csv_path = os.path.join(self.result_dir, 'iperf3.csv')
        with open(csv_path, 'a') as f:
            for key, val in wlan_metrics.items():
                f.write(f"{key},{val}\n")

        logging.info(f"WLAN metrics appended to {csv_path}: {wlan_metrics}")
