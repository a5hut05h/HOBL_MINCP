# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
from parameters import Params
import os
import time

def run(scenario):
    logging.debug('Executing code block: code_UTAWXA.py (MacOS)')
    
    # For MacOS, Office themes are handled differently
    # This is a placeholder for MacOS-specific setup
    
    # Get user home directory
    if Params.get("global", "local_execution") == "0":
        userprofile = scenario._call(["bash", "-c \"echo $HOME\""]).strip()
    else:
        userprofile = os.environ['HOME']
    logging.debug(f"User profile: {userprofile}")
    
    # Create link to abl_docs if needed
    abl_docs_link = "/Users/Shared/abl_docs"
    onedrive_docs = userprofile+"/OneDrive/abl_docs"
    
    # Remove existing link if present
    scenario._call(["bash", "-c \"rm -f " + abl_docs_link + "\""], expected_exit_code="", fail_on_exception=False)
    
    # Create symbolic link
    scenario._call(["bash", "-c \"ln -s " + onedrive_docs + " " + abl_docs_link + "\""], fail_on_exception=False)
    
    # Upload Office docs for MacOS
    upload_successful = False
    doc_source = os.path.join(os.path.dirname(__file__), "abl_docs")
    doc_dest = userprofile+"/OneDrive"
    
    if os.path.exists(doc_source):
        for i in range(12):
            try:
                scenario._upload(doc_source, doc_dest)
                upload_successful = True
                logging.info("Successfully uploaded productivity content to OneDrive")
                break
            except Exception as e:
                logging.error(f"Could not copy productivity content to OneDrive: {e}")
                time.sleep(10)
        
        if not upload_successful:
            logging.error("Could not copy productivity content to OneDrive in 12 tries.")
            scenario.fail("Could not copy productivity content to OneDrive in 12 tries.")
    else:
        logging.warning(f"Source directory {doc_source} does not exist, skipping upload")
