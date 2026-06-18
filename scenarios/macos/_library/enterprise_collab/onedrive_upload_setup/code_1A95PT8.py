# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import time
import threading

def _upload_large_files(scenario):
    """Encapsulates the content upload/download logic with retry loop."""
    #logging.debug('Starting download/upload thread logic: code_188PP26.py')
    logging.debug('Executing code block: code_1A95PT8.py')
    upload_successful = False
    last_exception = None
    for i in range(12):
        try:    
            # Get home directory from DUT and construct iCloud Drive path
            home_dir = scenario._call(["bash", "-c \"echo $HOME\""], expected_exit_code="").strip()
            # iCloud Drive path on macOS (equivalent to OneDrive on Windows)
            icloud_base = f"{home_dir}/Library/Mobile Documents/com~apple~CloudDocs"
            download_dir = f"{icloud_base}/onedrivetest"  # Using same subfolder name as Windows example        
            logging.info(f"Started uploadeding files to {download_dir}")
            scenario._upload("scenarios/MacOS/mac_enterprise_collab/resources/large", download_dir)
            logging.info(f"Successfully uploaded files to {download_dir}")
            
            # Verify upload - check if directory exists and count files
            #result = scenario._call(["bash", "-c", f"ls -lh '{download_dir}'"])
            #logging.info(f"Directory contents:\n{result}")
            
            upload_successful = True
            break
        except Exception as e:
            last_exception = e
            logging.warning(f"copy large files to onedrive (attempt {i+1}/12): {e} failed. Retrying...  ")
            time.sleep(1)  # Wait between retries
    if not upload_successful:
        logging.error("Could not copy large files to onedrive in 12 tries.")
        scenario.fail(f"OneDrive upload failed after 12 attempts: {last_exception}")

def run(scenario):
    logging.debug('Executing code block: code_1A95PT8.py')
    t = threading.Thread(target=_upload_large_files, args=(scenario,), name="upload_worker", daemon=True)
    scenario.upload_thread = t  # Persist thread object on scenario
    t.start()
    
