param(
    [string]$ConfigPath = '',
    [switch]$Preview,
    [switch]$ValidateOnly,
    [switch]$StartupCheck,
    [switch]$InteractionCheck
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$v3Root = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $v3Root
if (-not $ConfigPath) { $ConfigPath = Join-Path $v3Root 'automation.config.json' }
$xamlPath = Join-Path $PSScriptRoot 'scheduler.xaml'
$allowedProfilesPath = Join-Path $PSScriptRoot 'allowed_profiles.json'
$profilesDir = Join-Path (Split-Path -Qualifier $PSScriptRoot) 'profiles'
$commonPath = Join-Path $v3Root 'lib\common.ps1'
$registerTasksPath = Join-Path $v3Root 'register_tasks.ps1'
$manageTaskPath = Join-Path $v3Root 'manage_task.ps1'
$removeJobPath = Join-Path $v3Root 'remove_job.ps1'
$removeAllJobsPath = Join-Path $v3Root 'remove_all_jobs.ps1'
$emailPath = Join-Path $v3Root 'send_report_email.ps1'
$testplanParser = Join-Path $repoRoot 'automation_v2\lib\testplan.ps1'
$allowedPlans = [ordered]@{
    hobl = 'testplans/hobl.ps1'
    mincp_only = 'testplans/mincp_only.ps1'
    Mincp_NewOutlook = 'testplans/Mincp_NewOutlook.ps1'
    etl_trace = 'testplans/etl_trace.ps1'
}

. $commonPath

function Get-UiContext { return Get-HoblV3Config -ConfigPath $ConfigPath }
function Test-IsAdministrator {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-ProfileNames {
    if (-not (Test-Path -LiteralPath $profilesDir -PathType Container)) { return @() }
    if (-not (Test-Path -LiteralPath $allowedProfilesPath -PathType Leaf)) { throw "Approved profile list not found: $allowedProfilesPath" }
    [string[]]$allowed = Get-Content -LiteralPath $allowedProfilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($allowed | Where-Object { Test-Path -LiteralPath (Join-Path $profilesDir "$_.ini") -PathType Leaf })
}
function Show-UiError([string]$Message) {
    [System.Windows.MessageBox]::Show(" ERROR - $Message", 'HOBL Automation V3 Scheduler', 'OK', 'Error') | Out-Null
}
function Invoke-V3Script {
    param([Parameter(Mandatory)][string]$Path, [string[]]$Arguments = @())
    $output = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $detail=($output -replace '(?m)^\s*ERROR\s*-\s*','').Trim()
        if(-not $detail){$detail="$(Split-Path -Leaf $Path) failed with exit code $LASTEXITCODE."}
        throw $detail
    }
}
function Get-TaskName([string]$JobId) { return Get-HoblV3TaskName -JobId $JobId }

$context = $null
$profiles = @()
try {
    foreach ($required in @($ConfigPath,$xamlPath,$allowedProfilesPath,$commonPath,$registerTasksPath,$manageTaskPath,$removeJobPath,$removeAllJobsPath,$emailPath,$testplanParser)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file not found: $required" }
    }
    $context = Get-UiContext
    Test-HoblV3Config -Context $context -ThrowOnError | Out-Null
    $profiles = Get-ProfileNames
} catch {
    Write-Host " ERROR - $($_.Exception.Message)" -ForegroundColor Red
    Exit 1
}

if ($ValidateOnly) {
    $errors = @()
    if ($profiles.Count -eq 0) { $errors += "No approved .ini profiles were found in $profilesDir." }
    foreach ($planPath in $allowedPlans.Values) {
        $absolute = Join-Path $repoRoot ($planPath.Replace('/','\'))
        if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { $errors += "Testplan not found: $absolute" }
    }
    if ($errors.Count) { $errors | ForEach-Object { Write-Host " ERROR - $_" -ForegroundColor Red }; Exit 1 }
    Write-Host "V3 WPF validation succeeded. Approved profiles found: $($profiles.Count); jobs: $(@($context.Config.jobs).Count)."
    Exit 0
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$controlNames = @(
    'ModeBadge','ModeText','ExistingTaskBanner','ExistingTaskText','TopRunButton','TopDeleteButton','FooterStatus','SaveButton',
    'FrequencyCombo','HourCombo','MinuteCombo','WeekdayPanel','WeekdayCombo','MonthDayPanel','MonthDayCombo','OnceDatePanel','OnceDatePicker',
    'EmailYesRadio','EmailNoRadio','RecipientPanel','RecipientText','EmailDatePicker','EmailHourCombo','EmailMinuteCombo',
    'DutGrid','TaskStatusText','RefreshButton','RunButton','ToggleButton','DeleteButton','DeleteAllButton','LogsButton'
)
foreach ($name in $controlNames) { Set-Variable -Name $name -Value $window.FindName($name) }

$config = $context.Config
$enabledJobs = @($config.jobs | Where-Object { $_.enabled })
$schedule = if ($enabledJobs.Count) { $enabledJobs[0].schedule } else { [pscustomobject]@{ frequency='Daily';time='10:35';dayOfWeek='Monday';dayOfMonth=1 } }
[void]$FrequencyCombo.Items.Add('Once'); [void]$FrequencyCombo.Items.Add('Daily'); [void]$FrequencyCombo.Items.Add('Weekly'); [void]$FrequencyCombo.Items.Add('Monthly')
$FrequencyCombo.SelectedItem = [string]$schedule.frequency
foreach ($value in 0..23) { [void]$HourCombo.Items.Add($value.ToString('00')) }
foreach ($value in 0..59) { [void]$MinuteCombo.Items.Add($value.ToString('00')) }
$parts = ([string]$schedule.time) -split ':'
$HourCombo.SelectedItem = if ($parts.Count -eq 2) { $parts[0] } else { '10' }
$MinuteCombo.SelectedItem = if ($parts.Count -eq 2) { $parts[1] } else { '35' }
foreach ($day in @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')) { [void]$WeekdayCombo.Items.Add($day) }
$WeekdayCombo.SelectedItem = if ($schedule.dayOfWeek) { [string]$schedule.dayOfWeek } else { 'Monday' }
foreach ($day in 1..28) { [void]$MonthDayCombo.Items.Add([string]$day) }
$MonthDayCombo.SelectedItem = if ($schedule.dayOfMonth) { [string]$schedule.dayOfMonth } else { '1' }
$onceDate=(Get-Date).Date.AddDays(1)
if($schedule.date){$parsedOnceDate=[datetime]::MinValue;if([datetime]::TryParseExact([string]$schedule.date,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsedOnceDate)){$onceDate=$parsedOnceDate}}
$OnceDatePicker.SelectedDate=$onceDate
$RecipientText.Text = [string]$config.email.to
$EmailYesRadio.IsChecked = [bool]$config.email.enabled
$EmailNoRadio.IsChecked = -not [bool]$config.email.enabled
foreach ($value in 0..23) { [void]$EmailHourCombo.Items.Add($value.ToString('00')) }
foreach ($value in 0..59) { [void]$EmailMinuteCombo.Items.Add($value.ToString('00')) }
$emailDate=(Get-Date).Date.AddDays(1)
if($config.email.sendDate){$parsedEmailDate=[datetime]::MinValue;if([datetime]::TryParseExact([string]$config.email.sendDate,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsedEmailDate)){$emailDate=$parsedEmailDate}}
$EmailDatePicker.SelectedDate=$emailDate
$emailTime=if($config.email.sendTime){[string]$config.email.sendTime}elseif($config.email.checkTime){[string]$config.email.checkTime}else{'23:30'}
$emailParts=$emailTime -split ':';$EmailHourCombo.SelectedItem=$emailParts[0];$EmailMinuteCombo.SelectedItem=$emailParts[1]

$jobTable = New-Object System.Data.DataTable
[void]$jobTable.Columns.Add('IsExisting',[bool]); [void]$jobTable.Columns.Add('IsAvailable',[bool]); [void]$jobTable.Columns.Add('CanAdd',[bool]); [void]$jobTable.Columns.Add('CanEdit',[bool]); [void]$jobTable.Columns.Add('Included',[bool]); [void]$jobTable.Columns.Add('JobId',[string]); [void]$jobTable.Columns.Add('Profile',[string]); [void]$jobTable.Columns.Add('Status',[string]); [void]$jobTable.Columns.Add('PlanHobl',[bool]); [void]$jobTable.Columns.Add('PlanMincp',[bool]); [void]$jobTable.Columns.Add('PlanMincpNewOutlook',[bool]); [void]$jobTable.Columns.Add('PlanEtlTrace',[bool]); [void]$jobTable.Columns.Add('Runs',[int])
function Get-RowPlan($Row) {
    $selected=@()
    if([bool]$Row.PlanHobl){$selected+='hobl'}
    if([bool]$Row.PlanMincp){$selected+='mincp_only'}
    if([bool]$Row.PlanMincpNewOutlook){$selected+='Mincp_NewOutlook'}
    if([bool]$Row.PlanEtlTrace){$selected+='etl_trace'}
    if($selected.Count -ne 1){return ''}
    return $selected[0]
}
function Load-DutRows {
    $jobTable.Rows.Clear()
    $allProfiles=@($profiles)
    foreach($configuredProfile in @($config.jobs|ForEach-Object{[string]$_.profile})){if($allProfiles -inotcontains $configuredProfile){$allProfiles+=$configuredProfile}}
    foreach ($profile in $allProfiles) {
        $job=@($config.jobs|Where-Object{[string]$_.profile -ieq $profile})|Select-Object -First 1
        $existing=($null -ne $job);$available=($profiles -icontains $profile);$plan=if($existing){[IO.Path]::GetFileNameWithoutExtension([string]$job.testplan)}else{''}
        $status=if($existing -and -not $available){'Configured - profile unavailable'}elseif($existing -and $job.enabled){'Configured and scheduled'}elseif($existing){'Configured - disabled'}else{'Available'}
        $row=$jobTable.NewRow();$row.IsExisting=$existing;$row.IsAvailable=$available;$row.CanAdd=($available -and -not $existing);$row.CanEdit=($available -and -not $existing);$row.Included=$false;$row.JobId=if($existing){[string]$job.id}else{''};$row.Profile=$profile;$row.Status=$status;$row.PlanHobl=($plan -eq 'hobl');$row.PlanMincp=($plan -eq 'mincp_only');$row.PlanEtlTrace=($plan -eq 'etl_trace');$row.Runs=if($existing){[int]$job.runsPerDay}else{1};[void]$jobTable.Rows.Add($row)
        $row.PlanMincpNewOutlook=($plan -eq 'Mincp_NewOutlook')
    }
}
$script:updatingJobRow=$false
$jobTable.add_ColumnChanged({
    param($tableSource,$columnEvent)
    if($script:updatingJobRow -or [bool]$columnEvent.Row.IsExisting){return}
    $script:updatingJobRow=$true
    try {
        switch($columnEvent.Column.ColumnName){
            'Included' {$columnEvent.Row.Status=if([bool]$columnEvent.Row.Included){'Selected - save to configure'}else{'Available'}}
            'PlanHobl' {if([bool]$columnEvent.Row.PlanHobl){$columnEvent.Row.PlanMincp=$false;$columnEvent.Row.PlanMincpNewOutlook=$false;$columnEvent.Row.PlanEtlTrace=$false}}
            'PlanMincp' {if([bool]$columnEvent.Row.PlanMincp){$columnEvent.Row.PlanHobl=$false;$columnEvent.Row.PlanMincpNewOutlook=$false;$columnEvent.Row.PlanEtlTrace=$false}}
            'PlanMincpNewOutlook' {if([bool]$columnEvent.Row.PlanMincpNewOutlook){$columnEvent.Row.PlanHobl=$false;$columnEvent.Row.PlanMincp=$false;$columnEvent.Row.PlanEtlTrace=$false}}
            'PlanEtlTrace' {if([bool]$columnEvent.Row.PlanEtlTrace){$columnEvent.Row.PlanHobl=$false;$columnEvent.Row.PlanMincp=$false;$columnEvent.Row.PlanMincpNewOutlook=$false}}
        }
    } finally {$script:updatingJobRow=$false}
})
function Update-ScheduleVisibility {
    $WeekdayPanel.Visibility = if ($FrequencyCombo.SelectedItem -eq 'Weekly') {'Visible'}else{'Collapsed'}
    $MonthDayPanel.Visibility = if ($FrequencyCombo.SelectedItem -eq 'Monthly') {'Visible'}else{'Collapsed'}
    $OnceDatePanel.Visibility = if ($FrequencyCombo.SelectedItem -eq 'Once') {'Visible'}else{'Collapsed'}
}
function Update-EmailVisibility { $RecipientPanel.Visibility = if ($EmailYesRadio.IsChecked) {'Visible'}else{'Collapsed'} }
function Get-SelectedJobId {
    $view = $DutGrid.SelectedItem -as [System.Data.DataRowView]
    if (-not $view) { return '' }
    if ([string]$view.JobId) { return [string]$view.JobId }
    $plan=Get-RowPlan $view
    if ($view.Profile -and $plan) { return Get-HoblV3SafeId "$($view.Profile)-$plan" }
    return ''
}
function Get-TaskDetails {
    $jobId=Get-SelectedJobId
    if(-not $jobId){return 'Select a DUT row to view and manage its task.'}
    $taskName=Get-TaskName $jobId;$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $job=@($config.jobs|Where-Object{[string]$_.id -ieq $jobId})|Select-Object -First 1
    $paths=Get-HoblV3JobPaths -Context (Get-UiContext) -JobId $jobId;$state=Read-HoblV3Json -Path $paths.CurrentState
    if(-not $task){return "Job: $jobId`r`nTask: $taskName`r`nTask state: Not registered`r`nRun state: $(if($state){$state.status}else{'Never run'})"}
    $info=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    return @("Job: $jobId","Profile: $($job.profile)","Task: $taskName","Task state: $($task.State)","Enabled: $($task.Settings.Enabled)","Run state: $(if($state){$state.status}else{'Never run'})","Plan ID: $(if($state){$state.lastPlanId}else{''})","Next run: $($info.NextRunTime)","Last result: $($info.LastTaskResult)") -join "`r`n"
}
function Refresh-TaskStatus {
    try {
        $script:context=Get-UiContext;$script:config=$script:context.Config
        $TaskStatusText.Text=Get-TaskDetails
        $registered=0;foreach($job in @($config.jobs)){if(Get-ScheduledTask -TaskName (Get-TaskName ([string]$job.id)) -ErrorAction SilentlyContinue){$registered++}}
        if($registered){$ExistingTaskText.Text="$registered independent worker task(s) registered. Select a DUT row for details.";$ExistingTaskBanner.Visibility='Visible'}else{$ExistingTaskBanner.Visibility='Collapsed'}
    } catch {$TaskStatusText.Text=" ERROR - $($_.Exception.Message)"}
}
function Invoke-SelectedAction([string]$Action) {
    $jobId=Get-SelectedJobId;if(-not $jobId){throw 'Select a saved DUT row first.'}
    if(-not @($config.jobs|Where-Object{[string]$_.id -ieq $jobId}).Count){throw 'Save this new DUT before managing its task.'}
    Invoke-V3Script -Path $manageTaskPath -Arguments @('-ConfigPath',$ConfigPath,'-Action',$Action,'-JobId',$jobId)
    Refresh-TaskStatus
}
$DutGrid.ItemsSource=$jobTable.DefaultView;Load-DutRows;if($DutGrid.Items.Count){$DutGrid.SelectedIndex=0}
$DutGrid.Add_BeginningEdit({param($sender,$eventArgs);$rowView=$eventArgs.Row.Item -as [System.Data.DataRowView];if($rowView -and [bool]$rowView.IsExisting){$eventArgs.Cancel=$true}})
$FrequencyCombo.Add_SelectionChanged({Update-ScheduleVisibility});$EmailYesRadio.Add_Click({Update-EmailVisibility});$EmailNoRadio.Add_Click({Update-EmailVisibility});$DutGrid.Add_SelectionChanged({Refresh-TaskStatus})
$RefreshButton.Add_Click({Refresh-TaskStatus})
$RunButton.Add_Click({try{Invoke-SelectedAction 'Start'}catch{Show-UiError $_.Exception.Message}});$TopRunButton.Add_Click({try{Invoke-SelectedAction 'Start'}catch{Show-UiError $_.Exception.Message}})
$ToggleButton.Add_Click({try{$id=Get-SelectedJobId;if(-not $id){throw 'Select a DUT row first.'};$task=Get-ScheduledTask -TaskName (Get-TaskName $id) -ErrorAction Stop;if($task.Settings.Enabled){Invoke-SelectedAction 'Disable'}else{Invoke-SelectedAction 'Enable'}}catch{Show-UiError $_.Exception.Message}})
$deleteConfigurationAction={
    try {
        $row=$DutGrid.SelectedItem -as [System.Data.DataRowView]
        if(-not $row -or -not [bool]$row.IsExisting){throw 'Select an existing configured DUT first.'}
        $id=[string]$row.JobId
        if([System.Windows.MessageBox]::Show("Delete configuration '$id' and its scheduled task? Runtime logs and reports will be retained.",'Confirm configuration deletion','YesNo','Warning') -ne 'Yes'){return}
        Invoke-V3Script -Path $removeJobPath -Arguments @('-ConfigPath',$ConfigPath,'-JobId',$id)
        $script:context=Get-UiContext;$script:config=$script:context.Config;Load-DutRows;if($DutGrid.Items.Count){$DutGrid.SelectedIndex=0};$FooterStatus.Text="Deleted configuration '$id'. The DUT is available to add again.";Refresh-TaskStatus
    } catch {Show-UiError $_.Exception.Message}
}
$DeleteButton.Add_Click($deleteConfigurationAction);$TopDeleteButton.Add_Click($deleteConfigurationAction)
$DeleteAllButton.Add_Click({
    try {
        $count=@($config.jobs).Count
        if($count -eq 0){throw 'There are no DUT configurations to delete.'}
        if([System.Windows.MessageBox]::Show("Delete all $count DUT configurations and their scheduled tasks? Runtime logs and reports will be retained. This action will be refused if any DUT is running.",'Confirm deletion of all configurations','YesNo','Warning') -ne 'Yes'){return}
        Invoke-V3Script -Path $removeAllJobsPath -Arguments @('-ConfigPath',$ConfigPath)
        $script:context=Get-UiContext;$script:config=$script:context.Config;Load-DutRows;if($DutGrid.Items.Count){$DutGrid.SelectedIndex=0};$FooterStatus.Text="Deleted all $count DUT configurations. Available DUTs can now be configured again.";Refresh-TaskStatus
    } catch {Show-UiError $_.Exception.Message}
})
$LogsButton.Add_Click({try{$id=Get-SelectedJobId;if(-not $id){throw 'Select a DUT row first.'};$paths=Get-HoblV3JobPaths -Context (Get-UiContext) -JobId $id;if(Test-Path -LiteralPath $paths.Logs){Start-Process explorer.exe -ArgumentList $paths.Logs}else{throw "Log directory does not exist yet: $($paths.Logs)"}}catch{Show-UiError $_.Exception.Message}})

$SaveButton.Add_Click({
    $originalConfig=$null
    $configPathToRestore=''
    try {
        if(-not(Test-IsAdministrator)){throw 'Run from an Administrator PowerShell to save and register V3 tasks.'}
        if(-not $profiles.Count){throw "No approved profiles were found in $profilesDir."}
        if(-not(Get-Command ConvertFrom-HoblTestplan -ErrorAction SilentlyContinue)){. $testplanParser}
        $latest=Get-UiContext;$current=$latest.Config;$originalConfig=Read-HoblV3Json -Path $latest.ConfigPath;$configPathToRestore=$latest.ConfigPath;$newJobs=@();$newIds=@();$seenProfiles=@{};foreach($job in @($current.jobs)){$seenProfiles[([string]$job.profile).ToLowerInvariant()]=$true}
        $runDate=''
        if($FrequencyCombo.SelectedItem -eq 'Once'){if(-not $OnceDatePicker.SelectedDate){throw 'Select a date for the one-time DUT run.'};$runDate=([datetime]$OnceDatePicker.SelectedDate).ToString('yyyy-MM-dd');$runAt=[datetime]::ParseExact("$runDate $($HourCombo.SelectedItem):$($MinuteCombo.SelectedItem)",'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture);if($runAt -le (Get-Date)){throw 'The one-time DUT schedule must be in the future.'}}
        $commonSchedule=[pscustomobject][ordered]@{frequency=[string]$FrequencyCombo.SelectedItem;time=("{0}:{1}" -f $HourCombo.SelectedItem,$MinuteCombo.SelectedItem);date=$runDate;dayOfWeek=[string]$WeekdayCombo.SelectedItem;dayOfMonth=[int]$MonthDayCombo.SelectedItem}
        foreach($row in @($jobTable.Rows|Where-Object{[bool]$_.Included -and -not [bool]$_.IsExisting})){
            $profile=[string]$row.Profile;$plan=Get-RowPlan $row;$runs=[int]$row.Runs
            if($profiles -notcontains $profile){throw "Profile '$profile' is not approved or its .ini file is missing."};if(-not $plan){throw "Select exactly one scenario set (HOBL, MinCP, MinCP New Outlook, or ETL trace) for profile '$profile'."};if($runs -lt 1){throw 'Every selected DUT must have a run count of 1 or greater.'}
            $profileKey=$profile.ToLowerInvariant();if($seenProfiles.ContainsKey($profileKey)){throw "Profile '$profile' already has a configuration."};$seenProfiles[$profileKey]=$true
            $jobId=Get-HoblV3SafeId "$profile-$plan";$planPath=$allowedPlans[$plan];$absolute=Join-Path $repoRoot ($planPath.Replace('/','\'));$parsed=ConvertFrom-HoblTestplan -Path $absolute;$null=Assert-HoblV3ScenariosAvailable -HoblDut $profile -Rows @($parsed.Rows)
            $newJobs += [pscustomobject][ordered]@{id=$jobId;name="${profile}_${plan}";enabled=$true;profile=$profile;testplan=$planPath;runsPerDay=$runs;schedule=$commonSchedule};$newIds+=$jobId
        }
        $recipient=$RecipientText.Text.Trim();$sendDate='';$sendTime=''
        if($EmailYesRadio.IsChecked){
            $addresses=@($recipient -split '[;,]'|ForEach-Object{$_.Trim()}|Where-Object{$_});if(-not $addresses.Count){throw 'Enter at least one email recipient.'};foreach($address in $addresses){if($address -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$'){throw "Invalid email recipient: $address"}};$recipient=$addresses -join ';'
            if(-not $EmailDatePicker.SelectedDate){throw 'Select an email send date.'};$sendDate=([datetime]$EmailDatePicker.SelectedDate).ToString('yyyy-MM-dd');$sendTime="{0}:{1}" -f $EmailHourCombo.SelectedItem,$EmailMinuteCombo.SelectedItem
            $sendAt=[datetime]::ParseExact("$sendDate $sendTime",'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture);if($sendAt -le (Get-Date)){throw 'Email send date and time must be in the future.'}
            if($FrequencyCombo.SelectedItem -eq 'Once' -and $sendDate -ne $runDate){throw 'For a one-time DUT run, the email send date must match the DUT run date.'};if($FrequencyCombo.SelectedItem -eq 'Once' -and $sendAt -le $runAt){throw 'Email send time must be after the one-time DUT start time.'}
        }
        $current.jobs=@($current.jobs)+@($newJobs);$current.email.enabled=[bool]$EmailYesRadio.IsChecked;$current.email.to=$recipient
        $current.email|Add-Member -NotePropertyName sendDate -NotePropertyValue $sendDate -Force;$current.email|Add-Member -NotePropertyName sendTime -NotePropertyValue $sendTime -Force;if($sendTime){$current.email.checkTime=$sendTime}
        if(@($current.jobs|Where-Object{$_.enabled}).Count -eq 0){throw 'At least one configured DUT must be enabled.'}
        Test-HoblV3Config -Context $latest -ThrowOnError|Out-Null
        Write-HoblV3JsonAtomic -Path $latest.ConfigPath -Value $current -Depth 12
        if($newIds.Count){
            foreach($newId in $newIds){Invoke-V3Script -Path $registerTasksPath -Arguments @('-ConfigPath',$latest.ConfigPath,'-JobId',$newId)}
        }else{Invoke-V3Script -Path $registerTasksPath -Arguments @('-ConfigPath',$latest.ConfigPath,'-CoordinatorOnly')}
        $emailTaskName=if($current.email.taskName){[string]$current.email.taskName}else{'HOBL Automation V3 - Report Email'}
        if($current.email.enabled){Invoke-V3Script -Path $emailPath -Arguments @('-ConfigPath',$latest.ConfigPath,'-Register','-TaskName',$emailTaskName)}elseif(Get-ScheduledTask -TaskName $emailTaskName -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $emailTaskName -Confirm:$false}
        $script:context=Get-UiContext;$script:config=$script:context.Config;Load-DutRows;$FooterStatus.Text="Added $($newIds.Count) DUT configuration(s) and saved the report email schedule.";Refresh-TaskStatus
    } catch {
        $failure=$_.Exception.Message
        if($originalConfig -and $configPathToRestore){
            try{Write-HoblV3JsonAtomic -Path $configPathToRestore -Value $originalConfig -Depth 12}
            catch{$failure="$failure`n`nConfiguration rollback failed: $($_.Exception.Message)"}
        }
        Show-UiError $failure
    }
})

if($Preview){$window.Title='HOBL Automation V3 Scheduler (Preview Only)';$SaveButton.Content='Preview only - no changes will be saved';foreach($button in @($SaveButton,$RunButton,$TopRunButton,$ToggleButton,$DeleteButton,$DeleteAllButton,$TopDeleteButton)){$button.IsEnabled=$false}}
else{$ModeText.Text='LIVE V3 CONFIGURATION';$ModeBadge.Background='#DCEEFF';$ModeText.Foreground='#235078'}
Update-ScheduleVisibility;Update-EmailVisibility;Refresh-TaskStatus
if($InteractionCheck){
    $testRow=@($jobTable.Rows|Where-Object{[bool]$_.CanEdit})|Select-Object -First 1
    if(-not $testRow){throw 'No available DUT row exists for the checkbox interaction check.'}
    foreach($selection in @(
        @{Column='PlanMincpNewOutlook';Plan='Mincp_NewOutlook'},
        @{Column='PlanHobl';Plan='hobl'},
        @{Column='PlanMincpNewOutlook';Plan='Mincp_NewOutlook'},
        @{Column='PlanMincp';Plan='mincp_only'},
        @{Column='PlanMincpNewOutlook';Plan='Mincp_NewOutlook'},
        @{Column='PlanEtlTrace';Plan='etl_trace'}
    )){
        $testRow[$selection.Column]=$true
        if((Get-RowPlan $testRow) -ne $selection.Plan){throw "$($selection.Plan) checkbox exclusivity failed."}
    }
    $testRow.Included=$true;if([string]$testRow.Status -ne 'Selected - save to configure'){throw 'Add checkbox status update failed.'}
    Write-Host 'V3 WPF checkbox interaction check succeeded.';$window.Close();Exit 0
}
if($StartupCheck){Write-Host 'V3 WPF UI startup check succeeded.';$window.Close();Exit 0}
[void]$window.ShowDialog()
