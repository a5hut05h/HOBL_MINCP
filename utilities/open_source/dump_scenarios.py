# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# Dump scenarios
##

import argparse
import os
import json
import ast

scenario_docs = {}

def extract_docstrings(file_path):
    with open(file_path, "r", encoding="utf-8") as file:
        tree = ast.parse(file.read())

    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.ClassDef, ast.Module)):
            if hasattr(node, "name"):
                docstring = ast.get_docstring(node)
                if docstring:
                    return docstring
    return None


def main(print_json=True, short=True):
    scenarios_dirs = [os.path.join(os.getcwd(), 'scenarios')]

    if print_json:
        arg_parser = argparse.ArgumentParser()
        arg_parser.add_argument('-hobl_external', '-he', default='')
        args = arg_parser.parse_args()
        hobl_ext_paths = args.hobl_external.split()

        [scenarios_dirs.append(os.path.join(ext, 'scenarios')) for ext in hobl_ext_paths]

    for scenarios_dir in scenarios_dirs:
        if not os.path.exists(scenarios_dir):
            continue

        for subdir in ["windows", "common", "macos"]:
            scenarios_dir_sub = os.path.join(scenarios_dir, subdir)

            if not os.path.exists(scenarios_dir_sub):
                continue

            for filename in os.listdir(scenarios_dir_sub):
                path = os.path.join(scenarios_dir_sub, filename)

                if os.path.isdir(path):
                    path = os.path.join(path, filename + ".py")
                    filename = filename + ".py"

                if not os.path.isfile(path):
                    continue

                if filename.endswith('.py') and filename != '__init__.py':
                    docstring = extract_docstrings(path)
                    if short and docstring is not None:
                        # get first paragraph only
                        docstring = docstring.split('\n\n')[0]
                    # remove '.py' extension
                    module_name = filename[:-3]
                    scenario_docs[module_name] = docstring

    if print_json:
        print(json.dumps(scenario_docs))


if __name__ == '__main__':
    main()
