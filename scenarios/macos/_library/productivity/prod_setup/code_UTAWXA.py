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

    # Upload Word Normal.dotm template so custom shortcuts are available on the DUT.
    normal_dotm_source = os.path.join(os.path.dirname(__file__), "abl_docs", "Normal.dotm")
    if not os.path.exists(normal_dotm_source):
        normal_dotm_source = os.path.join(os.path.dirname(__file__), "abl_docs", "normal.dotm")

    if os.path.exists(normal_dotm_source):
        # Stage upload through a path without spaces to avoid chmod splitting in _upload.
        temp_template_upload_dest = "/Users/Shared"
        temp_template_file = "/Users/Shared/Normal.dotm"
        scenario._upload(normal_dotm_source, temp_template_upload_dest)

        template_dest = userprofile + "/Library/Group Containers/UBF8T346G9.Office/User Content.localized/Templates.localized"
        scenario._call(["bash", "-c \"mkdir -p \\\"" + template_dest + "\\\"\""], fail_on_exception=False)
        scenario._call([
            "bash",
            "-c \"cp -f \\\"" + temp_template_file + "\\\" \\\"" + template_dest + "/Normal.dotm\\\"\"",
        ], fail_on_exception=False)

        logging.info(f"Uploaded Word template {normal_dotm_source} to {template_dest}")
    else:
        scenario.fail("Normal.dotm was not found under scenarios\\macos\\_library\\productivity\\prod_setup\\abl_docs")
    
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
