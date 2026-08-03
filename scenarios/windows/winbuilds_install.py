# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

#PREP STEP:

# 1. Copy the lkg dev image contents from release server for the specific project from the \image\[Project] folder. (Do not copy the IMAGE folder itself, just all the contents inside the folder to the LKG folder)
# 2. Profile should include these line to properly execute os_install.py:

    # [os_install]
    # ; Sets the path and user information to the root share *if needed comment out if this is not needed
    # share_path: \\"server"\prelaunch
    # install_path_password: "domain password"
    # install_path_username: "domain account"
    # ; Sets the path for the WIM image
    # image_path: \\"server"\prelaunch\Images\[product]\[lkg]

# 4. Plug the DUT into a wired ethernet conncetion on scenarios and make sure the profile is pointing the that ip address.
# 5. You are now ready to run the automation.

#RUNNING THE AUTOMATION: 

# 6. On the Host, open PowerShell as an admin. OS_Install.py can be run directly or in the hobl dashboard. It is also included as the first step in the hobl_prep.ps1 (comented by default)
# 7. At the end of the process you should be booted into the new OS and SimpleRemote should start automatically (The device will reboot multiple times during the installation process.)
# 8. Or if you chose the whole prep then at the end you should be able to run hobl straight away (Be sure all prep and training scenarios were completed successfully before starting hobl)

###NOTES and known issues: ####

#1. Ignore any windows that pop-up when the drives are being partitioned and formated. Windows is automatically triggers this when it discovers new drives. We can ignore this since it does not interfere with automation.
#2. Occationally, if SurfaceBlockCopyTool.exe runs into failure while installing the OS it it possible that the device will not boot post-reboot. This error occurs outside the control of this automation and there is not way to get a status from the tool. If the device gets into this state you can fix it by doing a USB Key based OS install like we did in the past for manual installs. 
#3. This automation is for DEV images ONLY. We do not support Selfhost images or PLE images as of now since those builds don't have WinPE image.

import logging
import os
import subprocess
import sys
import time
from core.parameters import Params
import core.app_scenario
import scenarios.windows.dut_setup as dut_setup

import builtins
import shutil
from distutils.dir_util import copy_tree
from os import listdir
import core.call_rpc as rpc
import ntpath
import binascii
import scenarios.windows.recharge as recharge
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By


class WinbuildsInstall(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]
    original_dut_ip = Params.get('global', 'dut_ip')

    # Set default parameters
    Params.setDefault(module, 'winbuilds_path', '') # The host-side path to the image to be installed
    Params.setDefault(module, 'local_image_dest_path', 'C:\\winbuilds') # The dut-side folder to copy the image to before install
    Params.setDefault(module, 'install_wifi_name', '')
    Params.setDefault(module, 'install_wifi_password', '')
    Params.setDefault(module, 'install_dut_ip', original_dut_ip)
 
    # Override collection of config data, traces, and execution of callbacks 
    # Importing dut_setup sets local_execution to 1.  We need to set it back to 0 communicate with DUT.
    Params.setOverride("global", "local_execution", "0")
    # Params.setOverride("global", "collection_enabled", "0")
    Params.setOverride("global", "prep_tools", "")
    Params.setOverride("global", "attempts", "1")
    Params.setOverride("dut_setup", "reboot_prompt", "0")
    Params.setOverride("dut_setup", "run_cmd", "0")
    Params.setOverride("dut_setup", "upload_path", "C:\\dut_setup_files")
    Params.setOverride('global', 'dut_ip', Params.get(module, 'install_dut_ip'))

    # Get default parameters from ini file for setup dut
    winbuilds_path = Params.get(module, 'winbuilds_path')
    local_image_dest_path = Params.get(module, 'local_image_dest_path')
    install_wifi_name = Params.get(module, 'install_wifi_name')
    install_wifi_password = Params.get(module, 'install_wifi_password')
    dut_architecture = Params.get('global', 'dut_architecture')
    is_prep = True


    def setUp(self):
        # Don't call base setUp so that we don't interact with DUT.
        return


    def runTest(self):
        self._call(["cmd.exe", "/c if exist C:\\winbuilds rmdir C:\\winbuilds /S /Q"], expected_exit_code="")
        self._call(["cmd.exe", "/c if exist C:\\dut_setup_files rmdir C:\\dut_setup_files /S /Q"], expected_exit_code="")
        time.sleep(2)

        if self.install_wifi_name != '':
            self.switch_to_intall_network()
            time.sleep(10)

        # Copy over winbuilds setup files
        # if self._check_remote_file_exists(self.local_image_dest_path + "\\" + self.winbuilds_path.split ("\\")[-1] + "\\NUL"):
        #     logging.info("Image found on device already")
        # else:
        logging.info("Copying Image to device...")
        self._upload(self.winbuilds_path, self.local_image_dest_path)

        # Generate dut_setup files, including SimpleRemote, by directly calling the dut_setup module.
        # This will automatically upload the files to the proper directory (specified in the device profile), and reboot 
        logging.info("Copying files for DUT setup")
        ds = dut_setup.DutSetup()
        ds.runTest()
        time.sleep(2)

        #  Set dut setup to refresh
        logging.info("Set Runonce for Dut Setup")
        self._call(["cmd.exe", '/C reg add "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce" /v RunPowerTeamInstaller /t REG_SZ /d "C:\\dut_setup_files\\dut_setup.cmd" /f > null 2>&1'])

        # Disable privacy prompts
        logging.info("Set RegKey to skip privacy prompt at first boot")
        self._call(["cmd.exe", '/C reg add "HKLM\\Software\\Policies\\Microsoft\\Windows\\OOBE" /v DisablePrivacyExperience /t REG_DWORD /d 1 /f > null 2>&1'])

        # BCD edits
        self._call(["cmd.exe", "/C bcdedit /set flightsigning on"])
        # self._call(["cmd.exe", "/C bcdedit /set testsigning on"])

        # Reboot to get signing to stick
        self._dut_reboot()

        # Installing new build of windows over existing version
        logging.info("Installing Winbuild...")
        winbuild_folder=self.winbuilds_path.split ("\\")[-1]
        # self._call(["cmd.exe", "/c " + self.local_image_dest_path + "\\" + winbuild_folder + "\\Setup.exe /EULA accept /auto upgrade /showoobe none"], blocking=False)
        # self._call(["cmd.exe", "/c " + self.local_image_dest_path + "\\" + winbuild_folder + "\\Setup.exe /auto upgrade /eula Accept /Finalize /BitLocker AlwaysSuspend /quiet /CompactOS disable /DynamicUpdate disable /ShowOOBE none /Compat IgnoreWarning /Telemetry Disable"], blocking=False)
        self._call(["cmd.exe", "/c " + self.local_image_dest_path + "\\" + winbuild_folder + "\\Setup.exe /auto upgrade /eula Accept /BitLocker AlwaysSuspend /CompactOS disable /DynamicUpdate disable /ShowOOBE none /Compat IgnoreWarning /Telemetry Disable"], blocking=False)
        time.sleep(10)

        while(True):
            try:
                logging.debug("wait for device disconnect")
                rpc.call_rpc(self.dut_ip, self.rpc_port, "GetVersion", [])
                time.sleep(60)
            except:
                logging.debug("device disconnected")
                break

        # Poll for simple remote to determine is DUT setup is complete
        self._wait_for_dut_comm()

    def switch_to_intall_network(self):
        install_wifi_xml = '''<?xml version="1.0"?>
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
				<authentication>WPA2PSK</authentication>
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
        install_wifi_xml = install_wifi_xml.replace("WIFI_HEX", self.install_wifi_name.encode('utf-8').hex().upper())
        install_wifi_xml = install_wifi_xml.replace("WIFI_NAME", self.install_wifi_name)
        install_wifi_xml = install_wifi_xml.replace("WIFI_PASSWORD", self.install_wifi_password)

        source_path = os.path.join("C:\\", "install_wifi.xml")

        with open(source_path, "w") as text_file:
            text_file.write(install_wifi_xml)

        rpc.upload(self.dut_ip, self.rpc_port, source_path, self.dut_exec_path)

        # Connect to install wifi profile
        self._call(["cmd.exe", "/c netsh wlan add profile filename= " +  os.path.join(self.dut_exec_path, "install_wifi.xml") ])
        time.sleep(2)
        for i in range(20):
            # It an take a few tries to connect
            try:
                logging.info("Trying to connect to " + self.install_wifi_name)
                self._call(["cmd.exe", "/c netsh wlan connect name=" + self.install_wifi_name + " interface=Wi-Fi" ], timeout=10)
                break
            except:
                time.sleep(1)
                continue
        if i >= 19:
            logging.error("Time out trying to connect to install network: " + self.install_wifi_name)
            self.fail("Timeout trying to connect to install network: " + self.install_wifi_name)

        self._call(["cmd.exe", "/c netsh wlan set profileparameter name=" + self.install_wifi_name + " connectionmode=auto nonBroadcast=yes" ])

        time.sleep(10)
        # Log which SSID we are now conected to
        result = self._call(["cmd.exe", '/c netsh wlan show interface name="Wi-Fi"' ])
        lines = result.split('\n')
        for line in lines:
            if " SSID" in line:
                logging.info("Switched to" + line)

    def tearDown(self):
        # Don't call base tearDown so that we don't interact with DUT.
        return


    def kill(self):
        try:
            self._call(["shutdown.exe", "/r /f /t 5"])
            time.sleep(15)
            self._wait_for_dut_comm()
        except:
            pass