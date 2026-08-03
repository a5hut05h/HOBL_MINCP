# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
import os
import time
from core.parameters import Params
import core.app_scenario
import core.call_rpc as rpc
import tempfile

class WifiSwitch(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]

    # Set default parameters

    # Get default parameters from ini file
    dut_name = Params.get('global', 'dut_name')
    dut_wifi_name = Params.get('global', 'dut_wifi_name')
    dut_wifi_password = Params.get('global', 'dut_wifi_password')
    dut_wifi_authentication = Params.get('global', 'dut_wifi_authentication')

    is_prep = True


    def setUp(self):
        # Don't call base setUp so that we don't interact with DUT.
        return


    def runTest(self):
        if self.dut_wifi_name != '':
            self.switch_to_network()
            self.forget_other_networks()
            self.set_scheduled_task()
            # time.sleep(10)
        # Poll for simple remote to determine is DUT setup is complete
        self._wait_for_dut_comm()


    def switch_to_network(self):
        rpc.upload(self.dut_ip, self.rpc_port, "setup_src\\src_dut_win\\schedule_connect_wifi.ps1", self.dut_exec_path)
        result = self._call(["cmd.exe", '/c netsh wlan show interface name="Wi-Fi"' ])
        lines = result.split('\n')
        for line in lines:
            if " SSID" in line:
                dummy, ssid = line.strip().split(':')
                ssid = ssid.strip()
                if ssid == self.dut_wifi_name:
                    logging.info(f"Already connected to SSID {self.dut_wifi_name}")
                    return


        wifi_xml = '''<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
	<name>WIFI_NAME</name>
	<SSIDConfig>
		<SSID>
			<hex>WIFI_HEX</hex>
			<name>WIFI_NAME</name>
		</SSID>
        <nonBroadcast>true</nonBroadcast>
	</SSIDConfig>
	<connectionType>ESS</connectionType>
	<connectionMode>manual</connectionMode>
	<MSM>
		<security>
			<authEncryption>
				<authentication>WIFI_AUTH</authentication>
				<encryption>AES</encryption>
				<useOneX>false</useOneX>
                <transitionMode xmlns="http://www.microsoft.com/networking/WLAN/profile/v4">true</transitionMode>
			</authEncryption>
			<sharedKey>
				<keyType>passPhrase</keyType>
				<protected>false</protected>
				<keyMaterial>WIFI_PASSWORD</keyMaterial>
			</sharedKey>
		</security>
	</MSM>
</WLANProfile>
'''
        wifi_xml = wifi_xml.replace("WIFI_HEX", self.dut_wifi_name.encode('utf-8').hex().upper())
        wifi_xml = wifi_xml.replace("WIFI_NAME", self.dut_wifi_name)
        wifi_xml = wifi_xml.replace("WIFI_PASSWORD", self.dut_wifi_password)
        wifi_xml = wifi_xml.replace("WIFI_AUTH", self.dut_wifi_authentication)

        xml_filename = f"wifi_{self.dut_name}.xml"
        source_path = os.path.join(tempfile.gettempdir(), xml_filename)

        with open(source_path, "w") as text_file:
            text_file.write(wifi_xml)

        rpc.upload(self.dut_ip, self.rpc_port, source_path, self.dut_exec_path)

        os.remove(source_path)

        # Connect to wifi profile
        self._call(["cmd.exe", "/c netsh wlan add profile filename=" +  os.path.join(self.dut_exec_path, xml_filename) ])
        time.sleep(2)
        for i in range(20):
            # It an take a few tries to connect
            try:
                logging.info("Trying to connect to " + self.dut_wifi_name)
                self._call(["cmd.exe", "/c netsh wlan connect name=" + self.dut_wifi_name + " interface=Wi-Fi" ], timeout=10)
                break
            except:
                time.sleep(1)
                continue
        if i >= 19:
            logging.error("Time out trying to connect to network: " + self.dut_wifi_name)
            self.fail("Timeout trying to connect to network: " + self.dut_wifi_name)

        self._call(["cmd.exe", "/c netsh wlan set profileparameter name=" + self.dut_wifi_name + " connectionmode=auto nonBroadcast=yes" ])

        time.sleep(10)
        # Log which SSID we are now conected to
        result = self._call(["cmd.exe", '/c netsh wlan show interface name="Wi-Fi"' ])
        lines = result.split('\n')
        for line in lines:
            if " SSID" in line:
                logging.info("Switched to" + line.strip())


    def forget_other_networks(self):
        logging.info("Forgetting other Wi-Fi profiles...")
        result = self._call(["cmd.exe", '/c netsh wlan show profiles'])
        lines = result.split('\n')
        for line in lines:
            if "All User Profile" in line:
                dummy, ssid = line.strip().split(':')
                ssid = ssid.strip()
                if ssid != self.dut_wifi_name:
                    logging.info(f"  Forgetting profile: {ssid}")
                    self._call(["cmd.exe", f'/c netsh wlan delete profile name="{ssid}" >nul 2>&1'])
        result = self._call(["cmd.exe", '/c netsh wlan show profiles'])
        lines = result.split('\n')
        ssids = ""
        for line in lines:
            if "All User Profile" in line:
                dummy, ssid = line.strip().split(':')
                ssids += ssid.strip() + " "
        logging.info(f"Remaining Wi-Fi profiles: {ssids}")


    def set_scheduled_task(self):
        logging.info("Setting scheduled task to re-connect on reboot...")
        try:
            self._call(["cmd.exe", "/c SCHTASKS /Delete /TN ConnectWiFi /F"])
        except:
            pass
        self._call(["powershell.exe", f"-ExecutionPolicy Bypass -NoProfile {self.dut_exec_path}\schedule_connect_wifi.ps1 -network {self.dut_wifi_name}"])


    def tearDown(self):
        # Don't call base tearDown so that we don't interact with DUT.
        return


    def kill(self):
        # Prevent base kill routine from running
        return 0
