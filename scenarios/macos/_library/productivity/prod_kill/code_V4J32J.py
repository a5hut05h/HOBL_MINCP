# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging

def run(scenario):
    logging.debug('Executing code block: code_V4J32J.py (MacOS)')
    
    try:
        apps = ["Microsoft Excel", "Microsoft PowerPoint", "Microsoft Word", "Microsoft Outlook"]
        logging.debug(f"Killing {', '.join(apps)}")
        scenario._kill(apps)
    except:
        pass
