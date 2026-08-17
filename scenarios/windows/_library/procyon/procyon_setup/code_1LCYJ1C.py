import logging
import time
from core.parameters import Params

def run(scenario):
    logging.debug('Executing code block: code_1L9EY7T.py')
    logging.info("Preparing Procyon for first use.")

    # Get and verify parameters
    host_path = Params.get('procyon_setup', 'host_path')
    if host_path == "" or host_path is None:
        logging.warning("Procyon host_path is not set, not installing.")
        return
    license_key = Params.get('procyon_setup', 'key')
    if license_key == "":
        logging.error("Procyon license key is not set.")
        scenario.fail("Procyon license key is not set.")

    # Check if already installed
    if not scenario.checkPrepStatusNew([("procyon", [host_path])]):
        logging.info("Procyon already installed.")
        return

    # Upload installer
    target = f"{scenario.dut_exec_path}\\procyon_setup"
    logging.info(f"Uploading Procyon setup files to {target}")
    scenario._upload(host_path + "\\*", target, check_modified=False)

    # Run installer
    logging.info("Running Procyon setup script.")
    scenario._call([f"{target}\\procyon-setup.exe", "/s /sms"], expected_exit_code="0")

    # Register license
    logging.info("Registering license.")
    scenario._call(["C:\\Program Files\\UL\\Procyon\\ProcyonCmd.exe", f"--register={license_key}"])

    # Create prep status file to indicate completion
    scenario.createPrepStatusControlFile(suffix=[host_path], module="procyon")
    scenario._sleep_to_now()
