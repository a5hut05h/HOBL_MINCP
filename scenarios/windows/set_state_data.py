# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# Perf gate prep that will set the StateData every 30 mins instead of 24 hours. 
#   
##


from core.parameters import Params
from core.app_scenario import Scenario
import core.app_scenario
import logging


class SetStateData(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]
    Params.setDefault('module', 'set_default', '0')

    set_default = Params.get('module', 'set_default')
    
    # Params.setOverride("global", "collection_enabled", "0")
    Params.setOverride("global", "prep_tools", "")
    is_prep = True


    def runTest(self):
        if self.set_default == '0':
            logging.info("Setting the state data to fire every 30 minutes rather than 24 hours.")
            self._call(["cmd.exe", '/C sc stop dps > null 2>&1'])
            self._call(["cmd.exe", '/C reg add HKEY_LOCAL_MACHINE\Software\Microsoft\SQMClient /v IsTest /t REG_DWORD /d 1 /f > null 2>&1'])
            self._call(["cmd.exe", '/C reg add "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\SRUM\Telemetry" /v LongtermTimerInMinutes /t REG_DWORD /d 30 /f > null 2>&1'])
            self._call(["cmd.exe", '/C reg delete "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\SRUM\Telemetry" /v LastLongTermEventTime /f > null 2>&1'])
        elif self.set_default == '1':
            logging.info("Setting the state data back to default which is to fire every 24 hours.")
            self._call(["cmd.exe", '/C reg add "HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\SRUM\Telemetry" /v LongtermTimerInMinutes /t REG_DWORD /d 30 /f > null 2>&1'])


    def tearDown(self):
        core.app_scenario.Scenario.tearDown(self)

       
