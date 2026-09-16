# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

import logging
from core.parameters import Params

def run(scenario):
    logging.debug('Executing code block: code_W74E8F.py')

    browser = Params.get("global", "browser")
    if browser.lower() in ["chrome"]:
        # Prep only supported for Edge variants now
        return
    
    edge_version = 'Stable'
    if browser.lower() in ["edge dev", "edge beta", "edge canary"]:
        edge_version = self.browser[4].upper() + self.browser[5:]

    # Install administrative templates to be able to control settings
    scenario._upload("utilities\\open_source\\MicrosoftEdgePolicyTemplates\\windows\\admx\\msedge.admx", "c:\\Windows\\PolicyDefinitions")
    scenario._upload("utilities\\open_source\\MicrosoftEdgePolicyTemplates\\windows\\admx\\msedgeupdate.admx", "c:\\Windows\\PolicyDefinitions")
    scenario._upload("utilities\\open_source\\MicrosoftEdgePolicyTemplates\\windows\\admx\\msedgewebview2.admx", "c:\\Windows\\PolicyDefinitions")
    scenario._upload("utilities\\open_source\\MicrosoftEdgePolicyTemplates\\windows\\admx\\en-US\\msedge.adml", "c:\\Windows\\PolicyDefinitions\\en-US")
    scenario._upload("utilities\\open_source\\MicrosoftEdgePolicyTemplates\\windows\\admx\\en-US\\msedgeupdate.adml", "c:\\Windows\\PolicyDefinitions\\en-US")
    scenario._upload("utilities\\open_source\\MicrosoftEdgePolicyTemplates\\windows\\admx\\en-US\\msedgewebview2.adml", "c:\\Windows\\PolicyDefinitions\\en-US")
    # Change Edge policies
    scenario._call(["powershell.exe", 'Set-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -Key SOFTWARE\\Policies\\Microsoft\\Edge -ValueName AutoplayAllowed -Data 1 -Type DWord'])
    scenario._call(["powershell.exe", 'Set-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -Key SOFTWARE\\Policies\\Microsoft\\Edge -ValueName ShowRecommendationsEnabled -Data 0 -Type DWord'])
    scenario._call(["powershell.exe", 'Set-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -Key SOFTWARE\\Policies\\Microsoft\\Edge -ValueName HideFirstRunExperience -Data 1 -Type DWord'])
    scenario._call(["powershell.exe", 'Set-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -Key SOFTWARE\\Policies\\Microsoft\\Edge -ValueName HideRestoreDialogEnabled -Data 1 -Type DWord'])
    scenario._call(["powershell.exe", 'Set-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -Key SOFTWARE\\Policies\\Microsoft\\Edge -ValueName EdgeWorkspacesEnabled -Data 0 -Type DWord'])
    scenario._call(["powershell.exe", 'Set-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -Key SOFTWARE\\Policies\\Microsoft\\Edge -ValueName DefaultGeolocationSetting -Data 2 -Type DWord'])
    scenario._call(["cmd.exe", '/C reg add "HKLM\\Software\\Policies\\Microsoft\\Edge\\LocalNetworkAccessAllowedForUrls" /v 1 /t REG_SZ /d * /f'])
    scenario._call(["powershell.exe", 'Set-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -Key SOFTWARE\\Policies\\Microsoft\\EdgeUpdate -ValueName AutoUpdateCheckPeriodMinutes -Data 0 -Type DWord'])
    # This one prevents even manual updates, so commenting out
    # scenario._call(["powershell.exe", 'Set-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -Key SOFTWARE\\Policies\\Microsoft\\EdgeUpdate -ValueName InstallDefault -Data 0 -Type DWord'])
    scenario._call(["powershell.exe", 'Set-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -Key SOFTWARE\\Policies\\Microsoft\\EdgeUpdate -ValueName UpdateDefault -Data 0 -Type DWord'])
    result = scenario._call(["powershell.exe", 'Get-PolicyFileEntry -Path "$env:windir\\system32\\GroupPolicy\\Machine\\registry.pol" -All'])
    scenario._call(["cmd.exe", '/C gpupdate /wait:1200'])

    # Set reg key to not disable popups and disable offer to save passwrods popup
    logging.info('Setting reg keys.')
    regkey_path = 'HKCU\\SOFTWARE\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\CurrentVersion\\AppContainer\\Storage\\microsoft.microsoftedge'
    if edge_version.lower() in ["canary", "dev", "stable", "beta"]:
        regkey_path = regkey_path + '.' + edge_version.lower()
    regkey_path = regkey_path + '_8wekyb3d8bbwe\\MicrosoftEdge\\'
    
    scenario._call(["cmd.exe", '/C reg add "' + regkey_path + 'New Windows" /v PopupMgr /t REG_SZ /d no /f'])
    scenario._call(["cmd.exe", '/C reg add "' + regkey_path + 'Main" /v "FormSuggest passwords" /t REG_SZ /d no /f'])
    
    # Set reg key to prevent full screen notification
    scenario._call(["cmd.exe", '/C reg add "' + regkey_path + 'FullScreen\\AllowDomains" /v netflix.com /t REG_DWORD /d 1 /f'])   
    scenario._call(["cmd.exe", '/C reg add "' + regkey_path + 'FullScreen\\AllowDomains" /v youtube.com /t REG_DWORD /d 1 /f'])   
    
    # Set reg key to turn off opening apps for certain sites, such as Facebook
    scenario._call(["cmd.exe", '/C reg add "' + regkey_path + 'AppLinks" /v Enabled /d 0 /f '])

    # Work around to prevent extensions popup when upgrading from RS3 to RS4
    # scenario._call(["cmd.exe", '/C reg delete "HKEY_CURRENT_USER\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\CurrentVersion\\AppContainer\\Storage\\microsoft.microsoftedge_8wekyb3d8bbwe\\EdgeExtensions" /f'], expected_exit_code="")
    # scenario._call(["cmd.exe", '/C reg delete "HKEY_CURRENT_USER\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\CurrentVersion\\AppContainer\\Storage\\microsoft.microsoftedge_8wekyb3d8bbwe\\EdgeExtensions_WebDriver" /f'], expected_exit_code="")

    # Disable auto updating of Chrome and Edge with Chromium
    scenario._call(["cmd.exe", '/C reg add "HKLM\\Software\\Policies\\Microsoft\\EdgeUpdateDev" /v AutoUpdateCheckPeriodMinutes /d 0 /f'])
    scenario._call(["cmd.exe", '/C reg add "HKLM\\Software\\WOW6432Node\\Microsoft\\EdgeUpdateDev" /v AutoUpdateCheckPeriodMinutes /t REG_DWORD /d 0 /f'])
    scenario._call(["cmd.exe", '/C reg add "HKLM\\Software\\WOW6432Node\\Microsoft\\EdgeUpdateDev" /v IsEnrolledToDomain /t REG_DWORD /d 1 /f'])

    # If the environment variable:EDGE_FEATURE_OVERRIDES_SOURCE is set to server_default (value is case-insensitive), then official builds will get only 100% allocated configurations from the server.
    scenario._call(["cmd.exe", '/C setx /m EDGE_FEATURE_OVERRIDES_SOURCE server_default'])

    # Reset sleep time to now
    scenario._sleep_to_now()
