# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging

def run(scenario):
    logging.debug('Executing code block: code_1LKY8MT.py')
    # Disable system proxy so Office telemetry can upload to dashboard
    services = scenario._safe_call("networksetup -listallnetworkservices", "list services")
    if services:
        for service in services.splitlines():
            service = service.strip()
            if not service or service.startswith("*") or service.startswith("An asterisk"):
                continue
            scenario._safe_call(f"networksetup -setwebproxystate '{service}' off", f"proxy off {service}")
            scenario._safe_call(f"networksetup -setsecurewebproxystate '{service}' off", f"sproxy off {service}")
        logging.info("System proxy disabled for telemetry upload")

    logging.info("Proxy off - ready for fresh boot")

    