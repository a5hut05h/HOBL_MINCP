# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os
from core.parameters import Params


def run(scenario):
    logging.debug('Executing code block: code_1M2K62W.py')

    module = getattr(scenario, '_module', '') or scenario.__module__.split('.')[-1]
    plist_path = f"{scenario.dut_data_path}/powermetrics.plist"
    saved_pid = str(Params.get(module, 'powertool_pid') or '').strip()
    if saved_pid.isdigit():
        kill_cmd = f"kill -9 {saved_pid}"
        logging.info(f"Killing saved powermetrics PID from Params: {saved_pid}")
        logging.info(f"Executing on DUT: {kill_cmd}")
        scenario._call(["bash", f"-c \"{kill_cmd}\""], expected_exit_code="")
    else:
        logging.warning("powertool_pid is not set or invalid; skipping kill")

    if scenario._check_remote_file_exists(plist_path, in_exec_path=False):
        sudo_password = str(Params.get('global', 'dut_password') or '').strip()
        if not sudo_password and hasattr(scenario, 'password'):
            sudo_password = str(scenario.password or '').strip()

        staged_plist_path = f"{scenario.dut_data_path}/powermetrics_copyback.plist"
        cp_cmd = (
            f"cp \"{plist_path}\" \"{staged_plist_path}\" && "
            f"chmod 666 \"{staged_plist_path}\""
        )

        logging.info(f"Preparing readable staged powermetrics plist at {staged_plist_path}")
        if sudo_password:
            escaped_password = sudo_password.replace("'", "'\"'\"'")
            sudo_cp_cmd = (
                f"printf '%s\\n' '{escaped_password}' | "
                f"sudo -S -p '' bash -c '{cp_cmd}'"
            )
        else:
            sudo_cp_cmd = f"sudo -n bash -c '{cp_cmd}'"

        stage_ready = False
        try:
            scenario._call(["bash", f"-c \"{sudo_cp_cmd}\""], expected_exit_code="")
            scenario._call([
                "bash",
                f"-c \"test -r '{staged_plist_path}' && test -w '{staged_plist_path}'\""
            ], expected_exit_code="")
            stage_ready = True
        except Exception as exp:
            logging.warning(f"Failed to prepare staged plist for copyback: {exp}")

        source_path = None
        if stage_ready:
            source_path = staged_plist_path
        else:
            # Avoid noisy RPC errors by only attempting fallback when file is readable and writable by the DUT user.
            try:
                scenario._call([
                    "bash",
                    f"-c \"test -r '{plist_path}' && test -w '{plist_path}'\""
                ], expected_exit_code="")
                source_path = plist_path
            except Exception:
                logging.warning(
                    f"Skipping direct copy from {plist_path}; file exists but is not read/write accessible by DUT user"
                )

        if source_path:
            logging.info(f"Copying powermetrics plist to result dir from {source_path}")
            try:
                scenario._copy_data_from_remote(scenario.result_dir, source=source_path, single_file=True)

                # Always keep a single canonical plist filename in the host result folder.
                if source_path == staged_plist_path:
                    staged_host_path = os.path.join(scenario.result_dir, os.path.basename(staged_plist_path))
                    canonical_host_path = os.path.join(scenario.result_dir, os.path.basename(plist_path))
                    if os.path.exists(staged_host_path):
                        if os.path.exists(canonical_host_path):
                            os.remove(canonical_host_path)
                        os.replace(staged_host_path, canonical_host_path)
                        logging.info(f"Normalized staged plist filename to {canonical_host_path}")
            except Exception as exp:
                logging.warning(f"Failed to copy powermetrics plist from DUT: {exp}")
        else:
            logging.info(
                "Skipping powermetrics plist copyback because no read/write-accessible source file was found"
            )

        if stage_ready:
            cleanup_cmd = f"rm -f '{staged_plist_path}'"
            if sudo_password:
                escaped_password = sudo_password.replace("'", "'\"'\"'")
                cleanup_cmd = (
                    f"printf '%s\\n' '{escaped_password}' | "
                    f"sudo -S -p '' bash -c '{cleanup_cmd}'"
                )
            else:
                cleanup_cmd = f"sudo -n bash -c '{cleanup_cmd}'"
            try:
                scenario._call(["bash", f"-c \"{cleanup_cmd}\""], expected_exit_code="")
            except Exception as exp:
                logging.warning(f"Failed to remove staged plist on DUT: {exp}")
    else:
        logging.warning(f"powermetrics plist not found on DUT at {plist_path}")