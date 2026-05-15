# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
import os
import logging
from parameters import Params

def run(scenario):
    logging.debug('Executing code block: code_1L054J5.py')
    # Get user home directory
    if Params.get("global", "local_execution") == "0":
        userprofile = scenario._call(["bash", "-c \"echo $HOME\""]).strip()
    else:
        userprofile = os.environ['HOME']
    logging.debug(f"User profile: {userprofile}")
    
    # Create link to abl_docs if needed
    word_doc_path = userprofile+"/Onedrive/abl_docs/test_long_doc.docx"
    scenario._call(["bash", "-c \"open "+ word_doc_path+"\""]).strip()