# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging

def run(scenario):
    logging.debug('Executing code block: code_1LKYM3Y.py')
    if hasattr(scenario, 'web_replay_run') and scenario.web_replay_run == '1':
        services = scenario._safe_call(
            "networksetup -listallnetworkservices",
            "list services")
        if services and hasattr(scenario, 'web_replay_ip') and hasattr(scenario, 'web_replay_http_port'):
            for service in services.splitlines():
                service = service.strip()
                if not service or service.startswith("*") or service.startswith("An asterisk"):
                    continue
                scenario._safe_call(
                    f"networksetup -setwebproxy '{service}' {scenario.web_replay_ip} {scenario.web_replay_http_port}",
                    f"restore http proxy {service}")
                scenario._safe_call(
                    f"networksetup -setsecurewebproxy '{service}' {scenario.web_replay_ip} {scenario.web_replay_https_port}",
                    f"restore https proxy {service}")
            logging.info("System proxy re-enabled for web_replay")
        else:
            logging.info("web_replay proxy settings not available, skipping restore")
    else:
        logging.info("web_replay not active, no proxy to restore")
