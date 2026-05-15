# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import sys, importlib, importlib.abc, importlib.util

script_map = {
    "parameters":         "core.parameters",
    "arguments":          "core.arguments",
    "action_list":        "core.action_list",
    "utilities.call_rpc": "core.call_rpc",

    "scenarios.app_scenario": "core.app_scenario",

    "utilities.modules":        "utilities.open_source.modules",
    "utilities.dump_scenarios": "utilities.open_source.dump_scenarios",
    "utilities.dump_tools":     "utilities.open_source.dump_tools",
    "utilities.scenario_type":  "utilities.open_source.scenario_type",
    "utilities.device_ping":    "utilities.open_source.device_ping",

    "utilities.remote":              "utilities.third_party.remote",
    "utilities.remote.start_remote": "utilities.third_party.remote.start_remote",
}

if "-d" in sys.argv or "-dv" in sys.argv:
    script_map["core.app_scenario"] = "core.stub.app_scenario_stub"
    script_map["core.parameters"]   = "core.stub.parameters_stub"
    script_map["core.call_rpc"]     = "core.stub.call_rpc_stub"

class _AliasLoader(importlib.abc.Loader):
    def __init__(self, fullname, realname):
        self.fullname = fullname
        self.realname = realname

    def create_module(self, spec):
        return None

    def exec_module(self, module):
        real_module = importlib.import_module(self.realname)
        sys.modules[self.fullname] = real_module

class AliasFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        real = script_map.get(fullname)
        if not real:
            return None

        return importlib.util.spec_from_loader(
            fullname,
            _AliasLoader(fullname, real),
            origin=f"Alias of {real}"
        )

sys.meta_path.insert(0, AliasFinder())
