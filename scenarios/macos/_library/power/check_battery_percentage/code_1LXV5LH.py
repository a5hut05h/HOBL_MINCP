# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
from parameters import Params

def run(scenario):
    logging.debug('Executing code block: code_1LXV5LH.py')

    module = getattr(scenario, '_module', '') or scenario.__module__.split('.')[-1]

    # Get battery percentage as a number from DUT
    try:
        logging.info('Attempting to retrieve battery percentage from DUT.')
        battery_str = scenario._call(
            ["bash", "-c \"pmset -g batt | grep -Eo '\\d+%' | tr -d '%'\""]
        ).strip()
        logging.info(f"Raw battery string: {battery_str}")
        battery_percent = int(battery_str) if battery_str.isdigit() else None
        logging.info(f"Parsed battery percentage: {battery_percent}")

        # Get battery_threshold parameter from scenario (default to 0 if not set)
        try:
            battery_threshold = Params.get(module, 'battery_threshold') or 0  # Fallback to 0 if None
            battery_threshold = int(battery_threshold)
            logging.info(f"Retrieved battery_threshold: {battery_threshold}")
        except Exception as e:
            battery_threshold = 0
            logging.warning(f"Failed to retrieve battery_threshold, defaulting to 0. Error: {e}")

        # Set isDischarged = 1 if battery_percent < battery_threshold
        is_discharged = 1 if battery_percent is not None and battery_percent < battery_threshold else 0
        logging.info(f"Decision: isDischarged set to {is_discharged} based on battery_percent ({battery_percent}) and battery_threshold ({battery_threshold}).")
        Params.setParam(module, 'isDischarged', str(is_discharged))
        logging.info(f"isDischarged parameter updated in Params: {is_discharged}")
        
        return battery_percent
    except Exception as e:
        logging.error(f"Failed to get battery percentage: {e}")
        return None