import ctypes
import datetime
import json
import logging
import os
import subprocess

from core.app_scenario import Scenario
from core.parameters import Params


def _get_session_connect_state(session_id):
    buffer = ctypes.c_void_p()
    bytes_returned = ctypes.c_uint()
    query_succeeded = ctypes.windll.wtsapi32.WTSQuerySessionInformationW(
        None,
        session_id,
        8,
        ctypes.byref(buffer),
        ctypes.byref(bytes_returned),
    )
    if not query_succeeded or not buffer.value or bytes_returned.value < ctypes.sizeof(ctypes.c_int):
        return None
    try:
        return ctypes.cast(buffer, ctypes.POINTER(ctypes.c_int)).contents.value
    finally:
        ctypes.windll.wtsapi32.WTSFreeMemory(buffer)


class Tool(Scenario):
    """Collect IPCM power logs on the HOBL host."""

    module = __module__.split('.')[-1]
    _session_watch_process = None

    Params.setDefault(
        module,
        'duration',
        '30',
        desc='IPCM automatic stop duration in minutes. Use 0 to disable automatic stop.',
        valOptions=['0', '0.5', '1', '2', '3', '5', '10', '15', '20', '30'],
    )
    Params.setDefault(
        module,
        'sample_period',
        '500',
        desc='IPCM sample period in milliseconds.',
        valOptions=['20', '50', '100', '200', '500', '1000'],
    )
    Params.setDefault(
        module,
        'transfer_to_console',
        'false',
        desc='Preserve IPCM by transferring to console only if the RDP session disconnects.',
        valOptions=['false', 'true'],
    )

    def __init__(self, *args, **kwargs):
        self._ipcm_initialized = False
        self.skipped = False
        self.started = False
        super().__init__(*args, **kwargs)

        scenario = kwargs.get('scenario')
        if getattr(self, 'is_tool', False) and scenario is not None:
            try:
                self.initCallback(scenario)
                self.testBeginCallback()
                if not self.skipped:
                    logging.info('IPCM Preview started before scenario setup; Log is scheduled asynchronously.')
            except Exception:
                logging.exception('IPCM failed during early startup.')
                try:
                    self._stop()
                except Exception:
                    logging.exception('IPCM cleanup failed after an early startup error.')
                raise

    def initCallback(self, scenario):
        if self._ipcm_initialized:
            return

        self.scenario = scenario
        self.ipcm_directory = os.path.join(os.path.dirname(__file__), 'ipcm')
        self.start_script = os.path.join(self.ipcm_directory, 'Start-IPCM-HOBL.ps1')
        self.stop_script = os.path.join(self.ipcm_directory, 'Stop-IPCM-HOBL.ps1')
        self.timer_script = os.path.join(self.ipcm_directory, 'Run-IPCM-Timer.ps1')
        self.session_watch_script = os.path.join(
            self.ipcm_directory,
            'Watch-IPCM-Session.ps1',
        )
        self.duration = Params.get(self.module, 'duration')
        self.sample_period = Params.get(self.module, 'sample_period')
        self.transfer_to_console = Params.get(self.module, 'transfer_to_console')
        self.started = False
        self.diagnostic_path = os.path.join(self.scenario.result_dir, 'ipcm-diagnostic.json')
        self.output_directory = os.path.join(self.scenario.result_dir, 'IPCM')
        self.attempt_marker = os.path.join(self.output_directory, '.ipcm-attempted.json')

        os.makedirs(self.scenario.result_dir, exist_ok=True)
        os.makedirs(self.output_directory, exist_ok=True)
        process_session_id = ctypes.c_uint()
        session_resolved = ctypes.windll.kernel32.ProcessIdToSessionId(
            os.getpid(),
            ctypes.byref(process_session_id),
        )
        self.session_id = process_session_id.value if session_resolved else None
        active_session_id = ctypes.windll.kernel32.WTSGetActiveConsoleSessionId()
        session_connect_state = (
            _get_session_connect_state(self.session_id)
            if session_resolved
            else None
        )
        is_admin = bool(ctypes.windll.shell32.IsUserAnAdmin())
        self._write_diagnostic(
            'plugin_loaded',
            is_admin=is_admin,
            process_session_id=self.session_id,
            active_console_session_id=active_session_id,
            session_connect_state=session_connect_state,
            resolved_tools=Params.get('global', 'tools'),
        )

        if os.name != 'nt':
            raise RuntimeError('The ipcm_log tool is supported only on a Windows host.')
        if not is_admin:
            self._write_diagnostic('blocked_not_administrator')
            raise RuntimeError('HOBL must be run as Administrator when the ipcm_log tool is selected.')
        if not session_resolved or session_connect_state != 0:
            self._write_diagnostic('blocked_non_interactive_session')
            raise RuntimeError(
                'HOBL is not running in an active interactive Windows session. '
                'Keep the local desktop or RDP session connected and unlocked.'
            )

        required_paths = [
            os.path.join(self.ipcm_directory, 'IpcmView.exe'),
            os.path.join(self.ipcm_directory, 'ipcm-conf.json'),
            os.path.join(self.ipcm_directory, 'devices'),
            self.start_script,
            self.stop_script,
            self.timer_script,
            self.session_watch_script,
        ]
        missing_paths = [path for path in required_paths if not os.path.exists(path)]
        if missing_paths:
            self._write_diagnostic('blocked_missing_files', missing_paths=missing_paths)
            raise RuntimeError('Missing IPCM files: ' + ', '.join(missing_paths))

        try:
            marker_file = open(self.attempt_marker, 'x', encoding='utf-8')
        except FileExistsError:
            self.skipped = True
            self._ipcm_initialized = True
            self._write_diagnostic('retry_skipped', attempted_marker=self.attempt_marker)
            logging.info(
                'IPCM already ran for this HOBL result directory; skipping it for this retry.'
            )
            return

        with marker_file:
            json.dump(
                {
                    'created_at': datetime.datetime.now().isoformat(),
                    'hobl_process_id': os.getpid(),
                    'result_dir': self.scenario.result_dir,
                },
                marker_file,
                indent=2,
            )

        self._ipcm_initialized = True
        self._write_diagnostic('ready_to_start')
        logging.info(
            'IPCM configured for %s minutes at %s ms; results: %s',
            self.duration,
            self.sample_period,
            self.output_directory,
        )

    def _write_diagnostic(self, stage, **details):
        diagnostic = {
            'stage': stage,
            'process_id': os.getpid(),
            'result_dir': self.scenario.result_dir,
            'output_directory': self.output_directory,
            'duration': self.duration,
            'sample_period': self.sample_period,
            'transfer_to_console': self.transfer_to_console,
        }
        if os.path.exists(self.diagnostic_path):
            try:
                with open(self.diagnostic_path, 'r', encoding='utf-8') as diagnostic_file:
                    diagnostic.update(json.load(diagnostic_file))
            except (OSError, ValueError):
                pass
        diagnostic.update(details)
        diagnostic['stage'] = stage
        with open(self.diagnostic_path, 'w', encoding='utf-8') as diagnostic_file:
            json.dump(diagnostic, diagnostic_file, indent=2)

    def _run_script(self, script, extra_arguments=None, timeout=60):
        command = [
            'powershell.exe',
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            script,
            '-LogPath',
            self.output_directory,
        ]
        if extra_arguments:
            command.extend(extra_arguments)

        try:
            completed = subprocess.run(
                command,
                cwd=self.ipcm_directory,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            self._write_diagnostic(
                'start_script_timeout' if script == self.start_script else 'stop_script_timeout',
                timeout_seconds=timeout,
            )
            raise
        output = completed.stdout.strip()
        if output:
            logging.info(output)
        if completed.returncode != 0:
            raise RuntimeError(
                'IPCM command failed with exit code {}: {}'.format(
                    completed.returncode,
                    output,
                )
            )

    def _ensure_session_watchdog(self):
        if self.transfer_to_console != 'true':
            return

        existing = Tool._session_watch_process
        if existing is not None and existing.poll() is None:
            self._write_diagnostic('session_watchdog_reused', watchdog_process_id=existing.pid)
            return

        command = [
            'powershell.exe',
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            self.session_watch_script,
            '-LogPath',
            self.output_directory,
            '-SessionId',
            str(self.session_id),
            '-HoblProcessId',
            str(os.getpid()),
        ]
        Tool._session_watch_process = subprocess.Popen(
            command,
            cwd=self.ipcm_directory,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
        )
        self._write_diagnostic(
            'session_watchdog_started',
            watchdog_process_id=Tool._session_watch_process.pid,
            monitored_session_id=self.session_id,
            hobl_process_id=os.getpid(),
        )

    def testBeginCallback(self):
        if self.skipped or self.started:
            return

        self._ensure_session_watchdog()
        self._write_diagnostic('starting_ipcm')
        self._run_script(
            self.start_script,
            [
                '-Duration', self.duration,
                '-SamplePeriod', self.sample_period,
                '-TransferToConsole', self.transfer_to_console,
            ],
            timeout=90,
        )
        self.started = True
        self._write_diagnostic('preview_started_worker_launched')

    def _scenario_failed(self):
        outcome = getattr(self.scenario, '_outcome', None)
        if outcome is None:
            return False
        if getattr(outcome, 'success', True) is False:
            return True
        result = getattr(outcome, 'result', None)
        if result is None:
            return False
        failed_tests = list(getattr(result, 'failures', [])) + list(getattr(result, 'errors', []))
        return any(test is self.scenario for test, _ in failed_tests)

    def _stop(self, force=False):
        if self.skipped:
            return
        state_path = os.path.join(self.output_directory, '.ipcm-session.json')
        if not self.started and not os.path.exists(state_path):
            return
        if not force and self.duration != '0':
            return

        try:
            self._write_diagnostic('stopping_ipcm')
            self._run_script(self.stop_script, timeout=45)
            self._write_diagnostic('logging_finalized')
        finally:
            self.started = False

    def testEndCallback(self):
        self._stop(force=self._scenario_failed())

    def testScenarioFailed(self):
        self._stop(force=True)

    def testTimeoutCallback(self):
        self._stop(force=True)

    def cleanup(self):
        self._stop(force=self._scenario_failed())