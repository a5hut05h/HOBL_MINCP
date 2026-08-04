# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import json
import os

def run(scenario):
    logging.debug('Executing code block: code_10WJE37.py')

    # Filepath to the text file
    file_path = os.path.join(scenario.result_dir, "blender_result.txt")

    # Read the file and extract the JSON portion
    with open(file_path, "r") as file:
        content = file.read()

    # Find the position of "timestamp"
    timestamp_pos = content.find("timestamp")

    # Find the last "[" before "timestamp"
    json_start = content.rfind("[", 0, timestamp_pos)  # Search for "[" from the start to the position of "timestamp"
    json_end = len(content)  # Set to the last character of the file

    try:
        # if json_start != -1 and json_end != -1:
        json_data = content[json_start:json_end]  # Extract the JSON portion
        # Parse the JSON data
        parsed_data = json.loads(json_data)
        output_file_path = os.path.join(scenario.result_dir, "blender_result.json")
        with open(output_file_path, "w") as output_file:
            json.dump(parsed_data, output_file, indent=4)  # Write JSON with indentation for readability
                
    except:
        logging.error("No JSON Result found in blender_result.txt.")
        raise Exception("No JSON Result found in blender_result.txt. Check the file for errors.")