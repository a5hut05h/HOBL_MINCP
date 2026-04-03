# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
#
# Copy OneDrive resources to DUT and configure settings 
#
##

import logging
import time
import os
import core.app_scenario
from selenium.webdriver.common.keys import Keys
from core.parameters import Params
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By
import core.call_rpc as rpc


class oneDrivePrep(core.app_scenario.Scenario):
    module = __module__.split('.')[-1]

    #Get parameters
    onedrive_username = Params.get('global', 'msa_account')
    onedrive_password = Params.get('global', 'dut_password')

    is_prep = True
    new_onedrive = True

    def setUp(self):
        logging.info("Launching WinAppDriver.exe on DUT.")
        self._call([(self.dut_exec_path + "\\WindowsApplicationDriver\\WinAppDriver.exe"), (self.dut_resolved_ip + " " + self.app_port)], blocking=False)
        time.sleep(1)
        desired_caps = {}
        desired_caps["app"] = "Root"
        self.driver = self._launchApp(desired_caps)
        core.app_scenario.Scenario.setUp(self)
        
    def unCheck(self, driver, checkbox_name):
        time.sleep(1)
        try:
            if self.new_onedrive:
                elem = driver.find_element_by_xpath('//Button[contains(@Name,"' + checkbox_name + '")]')
            else:
                elem = driver.find_element_by_xpath('//CheckBox[contains(@Name,"' + checkbox_name + '")]')
            if elem.is_selected():
                elem.click()
                logging.info("'" + checkbox_name + "' has been unchecked")
            else:
                logging.info("'" + checkbox_name + "' is already unchecked")
        except:
            logging.info("'" + checkbox_name + "' not found, skipping")


    def handle_signin(self):
            logging.info("Signing in to Onedrive account")
            logging.info("Using Onedrive account: " + self.onedrive_username)
            """
            try:
                email_field = self.driver.find_element_by_name("Enter your email address")
                email_field.click()
            except:
                try:
                    email_field = self.driver.find_element_by_name(self.onedrive_username)
                    email_field.click()
                except:
                    try:
                        # Try to see if teams username is in the email field
                        logging.info("Attempting to see if teams email is in the email field")
                        email_field = self.driver.find_element_by_name(self.teams_email)
                        email_field.click()
                    except:
                        self.fail("Could not find email field to enter email address.")
            """
            try:
                # self.driver.find_element_by_xpath('//Window[contains(@Name,"Microsoft OneDrive")]/Pane/Edit').click()
                self.driver.find_element_by_name("Enter your email address").click()
            except:
                self.fail("Could not find email field to enter email address.")

            time.sleep(1)
            ActionChains(self.driver).key_down(Keys.CONTROL).send_keys("a").key_up(Keys.CONTROL).perform()
            time.sleep(1)
            # self._call([os.path.join(self.dut_exec_path, "InputInject", "InputInject.exe"), r"""[{'cmd':'type','delay':['50'],'keys':'""" + self.onedrive_username + r"""'}]"""])
            rpc.plugin_call(self.dut_ip, self.rpc_port, "InputInject", "Type", self.onedrive_username, 50) # Clear any previous input

            # email_field.send_keys(self.onedrive_username)
            # ActionChains(self.driver).send_keys(self.onedrive_username).perform()
            time.sleep(1)
            self.driver.find_element_by_name("Sign in").click()
            time.sleep(10)
            try:
                logging.info("Entering email password for OneDrive")
                self.driver.find_element_by_xpath('//*[contains(@Name, "Enter the password for")]').click()
                # ActionChains(self.driver).send_keys(self.onedrive_password).perform()
                rpc.plugin_call(self.dut_ip, self.rpc_port, "InputInject", "Type", self.onedrive_password, 50) # Clear any previous input
                time.sleep(1)
                self.driver.find_element_by_name("Sign in").click()
                time.sleep(20)
            except:
                pass


    def runTest(self):
        # What does this do?
        self._call(["cmd.exe", r'/C reg add HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Modules\GlobalSettings\Sizer /v PageSpaceControlSizer /t REG_BINARY /d a0000000010000000000000056050000 /f'])
        # Prevent "Deleted files are removed everywhere" reminder
        self._call(["cmd.exe", r'/C reg add HKLM\SOFTWARE\Policies\Microsoft\OneDrive /v DisableFirstDeleteDialog /t REG_DWORD /d 1 /f'])
        # Prevent mass delete popup
        self._call(["cmd.exe", r'/C reg add HKCU\Software\Microsoft\OneDrive\Accounts\Personal /v MassDeleteNotificationDisabled /t REG_DWORD /d 1 /f'])
        # Prevent first delete popup
        self._call(["cmd.exe", r'/C reg add HKCU\Software\Microsoft\OneDrive /v FirstDeleteDialogsShown /t REG_DWORD /d 1 /f'])
        time.sleep(2)

        # Inject ESCAPE just in case Start menu was left open
        ActionChains(self.driver).send_keys(Keys.ESCAPE).perform()
        time.sleep(1)

        ## Launch OneDrive by command
        logging.info("Launching OneDrive")
        # self._call(["cmd.exe", r'/C start shell:onedrive'])
        self._call(["cmd.exe", r'/C explorer %UserProfile%\OneDrive'], expected_exit_code="") # Explorer doesn't set exit codes
        time.sleep(5)

        # Now close that window to reveal signin window
        logging.info("Closing File Explorer window to reveal OneDrive sign-in prompt.")
        try:
            self.driver.find_element_by_xpath('//Window[contains(@Name,"File Explorer")]').find_element_by_name("Close").click()
        except:
            pass
        time.sleep(2)

        # Sign-in
        try:
            self.driver.find_element_by_xpath('//*[contains(@Name, "Sign in to OneDrive")]')
        except:
            logging.info("OneDrive account is already signed in")
        else:
            self.handle_signin()

        # else:
        #     logging.info("We should sign in to Onedrive account")
        #     logging.info("Using Onedrive account of " + self.onedrive_username)
        #     """
        #     try:
        #         email_field = self.driver.find_element_by_name("Enter your email address")
        #         email_field.click()
        #     except:
        #         try:
        #             email_field = self.driver.find_element_by_name(self.onedrive_username)
        #             email_field.click()
        #         except:
        #             try:
        #                 # Try to see if teams username is in the email field
        #                 logging.info("Attempting to see if teams email is in the email field")
        #                 email_field = self.driver.find_element_by_name(self.teams_email)
        #                 email_field.click()
        #             except:
        #                 self.fail("Could not find email field to enter email address.")
        #     """
        #     try:
        #         time.sleep(3)
        #         self.driver.find_element_by_xpath('//Window[contains(@Name,"Microsoft OneDrive")]/Pane/Edit').click()
        #     except:
        #         self.fail("Could not find email field to enter email address.")

        #     time.sleep(1)
        #     ActionChains(self.driver).key_down(Keys.CONTROL).send_keys("a").key_up(Keys.CONTROL).perform()
        #     time.sleep(1)
        #     # self._call([os.path.join(self.dut_exec_path, "InputInject", "InputInject.exe"), r"""[{'cmd':'type','delay':['50'],'keys':'""" + self.onedrive_username + r"""'}]"""])
        #     rpc.plugin_call(self.dut_ip, self.rpc_port, "InputInject", "Type", self.onedrive_username, 50) # Clear any previous input

        #     # email_field.send_keys(self.onedrive_username)
        #     # ActionChains(self.driver).send_keys(self.onedrive_username).perform()
        #     time.sleep(1)
        #     self.driver.find_element_by_name("Sign in").click()
        #     time.sleep(10)
        #     try:
        #         logging.info("Entering email password for OneDrive")
        #         self.driver.find_element_by_xpath('//*[contains(@Name, "Enter the password for")]').click()
        #         # ActionChains(self.driver).send_keys(self.onedrive_password).perform()
        #         rpc.plugin_call(self.dut_ip, self.rpc_port, "InputInject", "Type", self.onedrive_password, 50) # Clear any previous input
        #         time.sleep(1)
        #         self.driver.find_element_by_name("Sign in").click()
        #         time.sleep(20)
        #     except:
        #         pass

        #     # Check if were inifite loop on loading screen. 
        #     try:
        #         logging.info("Click Next")
        #         self.driver.find_element_by_name("Next").click()
        #         time.sleep(2)
        #     except:
        #         try:
        #             logging.info("Killing OneDrive to reattempt login.")
        #             self._kill("OneDrive.exe")
        #             time.sleep(5)
        #             logging.info("Launching OneDrive")
        #             self._call(["cmd.exe", r'/C start shell:onedrive'])
        #             time.sleep(3)
        #             logging.info("We should sign in to Onedrive account")
        #             logging.info("Using Onedrive account of " + self.onedrive_username)
        #             """
        #             try:
        #                 email_field = self.driver.find_element_by_name("Enter your email address")
        #                 email_field.click()
        #             except:
        #                 try:
        #                     email_field = self.driver.find_element_by_name(self.onedrive_username)
        #                     email_field.click()
        #                 except:
        #                     try:
        #                         # Try to see if teams username is in the email field
        #                         logging.info("Attempting to see if teams email is in the email field")
        #                         email_field = self.driver.find_element_by_name(self.teams_email)
        #                         email_field.click()
        #                     except:
        #                         self.fail("Could not find email field to enter email address.")
        #             """
        #             try:
        #                 time.sleep(3)
        #                 self.driver.find_element_by_xpath('//Window[contains(@Name,"Microsoft OneDrive")]/Pane/Edit').click()
        #             except:
        #                 self.fail("Could not find email field to enter email address.")
        #             time.sleep(1)
        #             ActionChains(self.driver).key_down(Keys.CONTROL).send_keys("a").key_up(Keys.CONTROL).perform()
        #             time.sleep(1)
        #             # self._call([os.path.join(self.dut_exec_path, "InputInject", "InputInject.exe"), r"""[{'cmd':'type','delay':['50'],'keys':'""" + self.onedrive_username + r"""'}]"""])
        #             rpc.plugin_call(self.dut_ip, self.rpc_port, "InputInject", "Type", self.onedrive_username, 50) # Clear any previous input
        #             # email_field.send_keys(self.onedrive_username)
        #             # ActionChains(self.driver).send_keys(self.onedrive_username).perform()
        #             time.sleep(1)
        #             self.driver.find_element_by_name("Sign in").click()
        #             time.sleep(5)
        #             try:
        #                 logging.info("Entering email password for OneDrive")
        #                 self.driver.find_element_by_xpath('//*[contains(@Name, "Enter the password for")]').click()
        #                 # ActionChains(self.driver).send_keys(self.onedrive_password).perform()
        #                 rpc.plugin_call(self.dut_ip, self.rpc_port, "InputInject", "Type", self.onedrive_password, 50) # Clear any previous input
        #                 time.sleep(1)
        #                 self.driver.find_element_by_name("Sign in").click()
        #                 time.sleep(20)
        #             except:
        #                 pass
        #             logging.info("Click Next")
        #             self.driver.find_element_by_name("Next").click()
        #         except:
        #             self.fail("Failed to log into onedrive")

        #     try:
        #         self.driver.find_element_by_name("Use this folder").click()
        #         time.sleep(3)
        #     except:
        #         pass
        #     # ActionChains(self.driver).send_keys(Keys.TAB).perform()
        #     # ActionChains(self.driver).send_keys(Keys.ENTER).perform()
        #     time.sleep(15)
        #     try:
        #         self.driver.find_element_by_name("Next").click()
        #     except:
        #         try:
        #             self.driver.find_element_by_name("I'll do it later").click()
        #         except:
        #             pass
        #     time.sleep(3)
        #     try:
        #         self.driver.find_element_by_name("Not now").click()
        #     except:
        #         pass
        #     try:
        #         self.driver.find_element_by_name("Continue").click()
        #     except:
        #         pass
        #     try:
        #         time.sleep(15)
        #         self.driver.find_element_by_name("Next").click()
        #         time.sleep(3)
        #         self.driver.find_element_by_name("Next").click()
        #         time.sleep(3)
        #         self.driver.find_element_by_name("Next").click()
        #         time.sleep(3)
        #         self.driver.find_element_by_name("Later").click()
        #         time.sleep(3)
        #         # self.driver.find_element_by_name("Next").click()
        #         # time.sleep(3)
        #         logging.info("Opening my OneDrive folder")
        #         self.driver.find_element_by_name("Open my OneDrive folder").click()
        #         time.sleep(5)
        #     except:
        #         try:
        #             self.driver.find_element_by_xpath('//Window[contains(@Name,"OneDrive")]').find_element_by_xpath('//*[contains(@Name,"Close")]').click()
        #         except:
        #             pass


        time.sleep(10)
        # Check for second Sign-in popup
        logging.info('Checking for "Microsoft respects your privacy" dialog.')
        try:
            self.driver.find_element_by_xpath('//*[contains(@Name, "Microsoft respects your privacy")]')
            logging.info("Clicking Next.")
            self.driver.find_element_by_name("Next").click()
            time.sleep(5)
        except:
            logging.info("Dialog not found, continuing.")

        # Check for second Sign-in popup
        logging.info('Checking for "Set up your OneDrive folder" dialog.')
        try:
            self.driver.find_element_by_xpath('//*[contains(@Name, "Set up your OneDrive folder")]')
            logging.info("Clicking Next.")
            self.driver.find_element_by_name("Next").click()
            time.sleep(3)
        except:
            logging.info("Dialog not found, continuing.")

        # Check for an additional "Next"
        logging.info('Checking for additional "Next" button.')
        try:
            self.driver.find_element_by_name("Next").click()
            time.sleep(3)
        except:
            logging.info("Button not found, continuing.")

        # Closing dialog
        logging.info("Closing OneDrive setup dialog if still open.")
        try:
            self.driver.find_element_by_xpath('//Window[contains(@Name,"OneDrive")]').find_element_by_name("Close").click()
            time.sleep(5)
        except:
            pass


        # try:
        #     logging.info("Checking for sign-in prompt")
        #     self.driver.find_element_by_xpath('//*[contains(@Name, "Please enter your sign-in info")]')
        #     self.driver.find_element_by_name("OK").click()
        #     time.sleep(10)
        #     self._page_source(self.driver, name="password")
        #     self.driver.find_element_by_xpath('//*[contains(@Name, "Enter password")]')
        #     ActionChains(self.driver).send_keys(self.onedrive_password).perform()
        #     time.sleep(1)
        #     self.driver.find_element_by_name("Sign in").click()
        #     time.sleep(20)
        # except:
        #     pass


        # # Finish setting up OneDrive, if needed
        # try:
        #     ok_Click = WebDriverWait(self.driver, 10).until(EC.presence_of_element_located((By.NAME, "OK")))
        #     ok_Click.click()
        #     time.sleep(5)
            
        #     ## Commented out to launch by command instead of UI
        #     # start_button = self._get_search_button(self.driver)
        #     # start_button.click()
        #     # time.sleep(5)

        #     # self.slow_send_keys("app:OneDrive")
        #     # time.sleep(2)

        #     # WebDriverWait(self.driver, 60).until(EC.presence_of_element_located((By.NAME, 'Results')))
        #     # app_item = self.driver.find_element_by_name("Results").find_element_by_xpath('//*[contains(@Name,"OneDrive")]')
        #     # ActionChains(self.driver).click(app_item).perform()
        #     # time.sleep(5)

        #     ## Launch OneDrive by command
        #     self._call(["cmd.exe", r'/C start shell:onedrive'])
        # except:
        #     pass
        # finally:
        #     try:
        #         self.driver.find_element_by_xpath('//Window[contains(@Name,"OneDrive")]').find_element_by_xpath('//*[contains(@Name,"Close")]').click()
        #         time.sleep(5)
        #     except:
        #         pass
        
        # try:
        #     self.driver.find_element_by_xpath('//Window[contains(@Name,"File Explorer")]').find_element_by_xpath('//*[contains(@Name,"Close")]').click()
        #     time.sleep(5)
        # except:
        #     pass

        # Right click on OneDrive to open settings 
        try:
            time.sleep(2)
            # self._page_source(self.driver)
            try:
                self.driver.find_element_by_xpath('//Button[contains(@Name,"OneDrive")]')
            except:
                try:
                    self.driver.find_element_by_name("Notification Chevron").click()
                except:
                    self.driver.find_element_by_xpath('//*[contains(@Name,"Show Hidden Icons")]').click()
                time.sleep(8)
                pass
            ele = self.driver.find_element_by_xpath('//Button[contains(@Name,"OneDrive")]')
            ActionChains(self.driver).move_to_element(ele).perform()
            time.sleep(1)
            ActionChains(self.driver).context_click().perform()
            time.sleep(5)
            try:
                self.driver.find_element_by_xpath('//MenuItem[contains(@Name,"Settings")]').click()
            except:
                # on DUT Reset sometimes the OneDrive right click does not work as intended. Need to press gear icon (settings) to load menu items.
                # It can bug out on first time attempting to right click on OneDrive icon. Change focus on mouse to desktop and then back to OneDrive icon.
                # This workaround seems to help onedrive to focus on gear icon (settings) when right clicking and selecting it once allows right click to function as intended. 
                self.driver.find_element_by_xpath("//*[contains(@Name, 'Show Desktop')]").click()
                time.sleep(1)
                ActionChains(self.driver).move_to_element(ele).perform()
                time.sleep(1)
                ActionChains(self.driver).context_click().perform()
                time.sleep(1)
                ActionChains(self.driver).send_keys(Keys.ENTER).perform()
                time.sleep(1)
                self.driver.find_element_by_xpath("//*[contains(@Name, 'Show Desktop')]").click()
                ActionChains(self.driver).move_to_element(ele).perform()
                time.sleep(1)
                ActionChains(self.driver).context_click().perform()
                time.sleep(5)
                self.driver.find_element_by_xpath('//MenuItem[contains(@Name,"Settings")]').click()
            # try:
            #     ActionChains(self.driver).context_click(self.driver.find_element_by_name("Control Host").find_element_by_name("OneDrive - Personal")).perform()
            #     time.sleep(1)
            # except:
            #     pass
        except:
            ## Right-clicking on OneDrive in File Explorer no longer works in Win11, commmenting out
            # logging.info("Starting OneDrive thru start menu")
            # start_button = self._get_search_button(self.driver)
            # start_button.click()
            # time.sleep(5)    
            
            # self.slow_send_keys("app:OneDrive")
            # time.sleep(2)

            # self.driver.find_element_by_name("Maximize").click()
            # time.sleep(2)

            # app_item = self.driver.find_element_by_name("Results").find_element_by_xpath('//*[contains(@Name,"OneDrive")]')
            # ActionChains(self.driver).click(app_item).perform()
            # time.sleep(2)

            # ActionChains(self.driver).context_click(self.driver.find_element_by_name("Control Host").find_element_by_name("OneDrive")).perform()
            # time.sleep(1)
            try:
                # Finding "Settings" throws an exception in one of the latest OS and below one works
                self.driver.find_element_by_name("Help & Settings").click()
                time.sleep(2)
                self.driver.find_element_by_xpath('//MenuItem[contains(@Name,"Settings")]').click()
            except:
                self.fail("Could not get to OneDrive Settings menu.")

        # try:
        #     self.driver.find_element_by_name("Settings").click()
        #     time.sleep(1)
        # except:
        #     logging.info("Sending ESCAPE sequence")
        #     ActionChains(self.driver).send_keys(Keys.ESCAPE).perform()
        #     time.sleep(1)
        #     logging.info("Trying to move cursor")
        #     ActionChains(self.driver).move_by_offset(0, 10).perform()
        #     time.sleep(1)
        #     logging.info("Trying to right click on OneDrive")
        #     ActionChains(self.driver).context_click().perform()
        #     time.sleep(1)
        #     logging.info("Trying to select Settings")
        #     self.driver.find_element_by_name("Settings").click()
        #     time.sleep(1)

        # Settings tab settings
        try:
            settingsTab = self.driver.find_element_by_name("Settings")
            logging.info("Detected old OneDrive")
            self.new_onedrive = False
        except:
            # New Onedrive
            logging.info("Detected new OneDrive")
            self.new_onedrive = True

        if self.new_onedrive == False:
            settingsTab.click()
            time.sleep(1)
            self.unCheck(self.driver, "battery saver mode")
            self.unCheck(self.driver, "metered")
            self.unCheck(self.driver, "share with me or edit my shared")
            self.unCheck(self.driver, "files are deleted in the cloud")
            self.unCheck(self.driver, "from the cloud")
            self.unCheck(self.driver, "Notify me when sync is auto-paused")
            self.unCheck(self.driver, "sync pauses automatically")
            self.unCheck(self.driver, "new collection")
            # self.unCheck("Save space and download files as you use them")
            # time.sleep(1)
            # try:
            #     self.driver.find_element_by_xpath('//*[contains(@AutomationId,"CommandButton_")]').click()
            #     time.sleep(1)
            # except:
            #     logging.info("No need to confirm 'Disable Files On-Demand'")

            # Office tab settings
            try:
                self.driver.find_element_by_name("Microsoft OneDrive").find_element_by_name("Office").click()
                time.sleep(1)
                logging.info("Office tab detected")
                radio_1 = "Let me choose to merge changes or keep both copies"
                radio_2 = "Always keep both copies (rename the copy on this computer)"
                if self.driver.find_element_by_name(radio_1).is_selected():
                    self.driver.find_element_by_name(radio_2).click()
                    logging.info("'" + radio_2 + "' has been unchecked")
                    time.sleep(1)
                else:
                    logging.info("'" + radio_2 + "' is already unchecked")
                # self.driver.find_element_by_xpath('//*[contains(@Name,"OK")]').click()
                self.driver.find_element_by_name("OK").click()
                time.sleep(1)
            except:
                logging.info("No Office tab detected")

            logging.info("Closing OneDrive window")
            try:
                self.driver.find_element_by_xpath('//Window[contains(@Name,"File Explorer")]').find_element_by_xpath('//*[contains(@Name,"Close")]').click()
            except:
                pass

        else:  # New OneDrive
            desired_caps = {}
            desired_caps["app"] = "Root"
            self.desktop = self._launchApp(desired_caps)
            properly_logged_in = True

            try:
                # logging.info("looking for not account.")
                self.desktop.find_element_by_xpath(('//*[contains(@Name,"You don\'t have an account connected.")]'))
                logging.error("Did not properly log in.")
                properly_logged_in = False
            except:
                pass
            if not properly_logged_in:
                self.fail("Failed to properly log in")

            self.desktop.find_element_by_accessibility_id("syncTab").click()
            time.sleep(1)
            self.unCheck(self.desktop, "battery saver mode")
            self.unCheck(self.desktop, "metered")
            self.desktop.find_element_by_accessibility_id("notificationsTab").click()
            time.sleep(1)
            self.unCheck(self.desktop, "Notify me when syncing is paused")
            self.unCheck(self.desktop, "share with me or edit my shared")
            self.unCheck(self.desktop, "files are deleted in the cloud")
            self.unCheck(self.desktop, "memories")
            self.unCheck(self.desktop, "removed from the cloud")
            logging.info("Closing OneDrive window")
            try:
                self.driver.find_element_by_xpath('//Window[contains(@Name,"File Explorer")]').find_element_by_xpath('//*[contains(@Name,"Close")]').click()
            except:
                pass

        self.createPrepStatusControlFile()  

    def tearDown(self):
        logging.info("Performing teardown.")
        try:
            self.driver.find_element_by_xpath('//Window[contains(@Name,"OneDrive")]').find_element_by_name("Close").click()
        except:
            pass
        try:
            self.driver.find_element_by_xpath('//Window[contains(@Name,"File Explorer")]').find_element_by_name("Close").click()
        except:
            pass
        
    
        core.app_scenario.Scenario.tearDown(self)
        self._kill("WinAppDriver.exe")

        # Reboot for improved robustness
        logging.info("Rebooting after Office installation.")
        self._dut_reboot()


    def slow_send_keys(self, keys):
        for key in keys:
            ActionChains(self.driver).send_keys(key).perform()
            time.sleep(0.5)

