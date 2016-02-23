#Requires -version 2

<#
.SYNOPSIS
	Script to backup your Windows Server
		
	
.NOTES
	Author		: Alexandre Augagneur (www.alexwinner.com)
	File Name	: Backup-task.ps1

.EXAMPLE
	.Backup-Task.ps1 –ConfigFile e:\WSB-Script\Backup-Config.xml –Compress –Sync –Notify
	
.EXAMPLE
	Backup-Task.ps1 –ConfigFile e:\WSB-Script\Backup-Config.xml –BackupType BareMetal
	
	
.PARAMETER ConfigFile
	Specify the XML file containing the configuration of your task

.PARAMETER BackupType
	Choose between "SystemState" or "BareMetal" backup
	
.PARAMETER Compress
	Compress the backup based on 7Zip (required the binary)
	
.PARAMETER Sync
	Synchronize remotely the backup folder with Robocopy
	
.PARAMETER Notify
	Send the backup job result via Email.
#>

param
(
	[Parameter(mandatory=$true)]
	[ValidateScript({Test-Path $_ -PathType any})]
	[String] $ConfigFile,
	
	[Parameter()]
    [ValidateSet("SystemState","BareMetal")]
	[String] $BackupType = "SystemState",

	[Parameter()]
	[Switch] $Compress,
	
	[Parameter()]
	[Switch] $Sync,
	
	[Parameter()]
	[Switch] $Notify
)

####################################################
# Environment Variable declaration
####################################################

[IO.FileInfo] $script:ScriptName = $MyInvocation.MyCommand.Name

# Specific backup folder
$BackupFolder = -join ($env:COMPUTERNAME, "-Backup")

# Tools folder
$ToolsFolder = $PWD, "Tools" -join "\"

# Log indentation
$Indent = 1

# Object to store job result
$JobResult = New-Object PSObject | Select-Object ConfigFile,LogFile,BackupType,RotationType,Options,State,HResult,StartTime,EndTime,Filename,FailureLogPath,Compression,RemovedBackups,RetainedBackups,Synchronization,Message

# List of messages
$Messages = @{
	1 = "Unable to find 7z.exe or/and 7z.dll in {0}`n";
	2 = "{0} successfully installed`n" ;
	3 = "Not able to import ServerManager module: the script is probably not running on a server`n" ;
	4 = "Number of {0} backups found: {1}`n" ;
	5 = "Removing stale backup: {0}`n" ;
	6 = "Removing stale backup: not able to remove {0}`n" ;
	7 = "Backup job state: {0} at {1}`n" ;
	8 = "Backup job result: HResult error code {0}`n" ;
	9 = "Consult the log file {0}`n" ;
	10 = "Unable to load PowerShell Snapin Windows.ServerBackup`n" ;
	11 = "Not able to find the last job status. The job probably failed`n" ;
	12 = "Estimated size needed for the backup: {0} GB`n" ;
	13 = "Not able to calculate the size of the last backup. Use the default value (value={0} GB)`n" ;
	14 = "No space available for a backup operation and nothing to remove. Please provide a correct location or cleanup this one`n" ;
	15 = "Extra backup file removed. The space available still not sufficient. Please provide a correct location or cleanup this one`n" ;
	16 = "Error during compression of the backup folder {0}. Consult the log file {1} for more information`n" ;
	17 = "Backup folder {0} successfully compressed to {1}`n" ;
	18 = "Not able to load the configuration file '{0}' (file not found)`n" ;
	20 = "Logging file: '{0}'`n" ;
	21 = "Not able to create the logging file '{0}'`n" ;
	22 = "Unable to access to the folder '{0}'`n" ;
	23 = "Configuration file: '{0}'`n" ;
	24 = "Unable to compress the backup. Unable to find the folder`n" ;
	25 = "Config file validation failed. Please read log file for more information`n" ;
	26 = "Starting synchronization to {0}`n" ;
}

# XML Schema validator for the config file
$XMLSchema =
@"
<xs:schema attributeFormDefault="unqualified" elementFormDefault="qualified" xmlns:xs="http://www.w3.org/2001/XMLSchema">
  <xs:element name="CONFIG">
    <xs:complexType>
      <xs:sequence>
        <xs:element name="GENERAL">
          <xs:complexType>
            <xs:sequence>
              <xs:element type="xs:integer" name="MonthRetention" default="2"/>
              <xs:element type="xs:integer" name="WeekRetention" default="4"/>
              <xs:element type="xs:integer" name="DayRetention" default="15"/>
              <xs:element type="xs:integer" name="MininumSpaceInGB" default="20"/>
              <xs:element type="xs:string" name="BackupRootFolder" minOccurs="1"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name="DESTINATION" minOccurs="0">
          <xs:complexType>
            <xs:sequence>
              <xs:element type="xs:string" name="SyncServerName"/>
              <xs:element type="xs:string" name="SyncFolderName"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
        <xs:element name="NOTIFICATION" minOccurs="0">
          <xs:complexType>
            <xs:sequence>
              <xs:element type="xs:string" name="SmtpServerName"/>
              <xs:element type="xs:integer" name="SmtpServerPort"/>
              <xs:element type="xs:string" name="SmtpServerUsername"/>
              <xs:element type="xs:string" name="SmtpServerPassword"/>
              <xs:element type="xs:boolean" name="Ssl"/>
              <xs:element type="xs:string" name="Recipient" minOccurs="0" maxOccurs="unbounded"/>
              <xs:element type="xs:string" name="Sender"/>
            </xs:sequence>
          </xs:complexType>
        </xs:element>
      </xs:sequence>
    </xs:complexType>
  </xs:element>
</xs:schema>	
"@

#Region Functions

####################################################
# Functions
####################################################

#---------------------------------------------------
# Function to verify prerequisites
#---------------------------------------------------
function Check-Prerequisites()
{
	Write-Verbose "Inside function Check-Prerequisites"
	
	# Modify XML schema if sync is enabled
	if ($Sync)
	{
        Write-Verbose "Sync is enabled"
		$XMLSchema = $XMLSchema.Replace('name="DESTINATION" minOccurs="0">','name="DESTINATION" minOccurs="1">')
	}
	
	# Modify XML schema if mail notification is enabled
	if ($Notify)
	{
		$XMLSchema = $XMLSchema.Replace('name="NOTIFICATION" minOccurs="0">','name="NOTIFICATION" minOccurs="1">')
	}
	
	# Test XML config file
	if ( Test-XML -Path $script:ConfigFile -Schema $XMLSchema )
	{		
		# Loading configuration file
		Write-Verbose "Loading Config file: $script:ConfigFile"
		[XML] $script:Config = Get-Content $script:ConfigFile
        $JobResult.ConfigFile =  $script:ConfigFile
		
		$script:LogPath = $($script:Config.CONFIG.GENERAL.BackupRootFolder), "logs" -join "\"
	
		# Check/Create Log Path
		if ( !(Test-Path $script:LogPath ) )
		{
			New-Item $script:LogPath -Type Directory -Confirm:$false -Force -ErrorAction SilentlyContinue -ErrorVariable ErrLogPath | Out-Null

			if ( $ErrLogPath )
			{
				$JobResult.Message += $Messages.get_Item(26) -f $script:LogPath,$($env:TEMP)
				$JobResult.State = "WARNING"
				$script:LogPath = $($env:TEMP)
			}
		}
	
		Write-Verbose "Log path: $($script:LogPath)"
	
		# Create the log file
		$script:LogFile = New-Object IO.FileInfo "$($script:LogPath)\$($env:computername)-$(get-date -format MMddyyHHmmss).log"
		New-Item $script:LogFile -Type file -Force -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable ErrLogFile | Out-Null
		
		if ( $ErrLogFile )
		{
			$JobResult.Message += $Messages.get_Item(20) -f $script:LogFile
			Write-Verbose "Log file creation: $ErrLogFile"
			$JobResult.State = "ERROR"
			Generate-Report
		}
		else
		{
			Create-LogHeader -Path $script:LogFile
			Write-log -Message ($($Messages.get_Item(20)) -f $script:LogFile) -Indent $script:Indent -Path $script:LogFile
			$JobResult.LogFile = $script:LogFile
		}
		
		# Create the main log file (monthly log)
		$script:MainLog = New-Object IO.FileInfo "$($script:LogPath)\$($env:computername)-$($script:ScriptName.BaseName)-$(get-date -format MMyy).log"
		
		if ( -not(Test-Path $script:MainLog) )
		{ 
			New-Item $script:MainLog -Type file -Force -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable ErrMainLogFile | Out-Null

			if ( $ErrMainLogFile )
			{ 
				$JobResult.Message += $Messages.get_Item(21) -f $LogFile; $JobResult.State = "ERROR"
				Generate-Report
			}
			else
			{
				Create-LogHeader -Path $script:MainLog -Main $true
			}
		}	
	}
	else
	{
		$JobResult.Message += $Messages.get_Item(25)
		Return $false
	}
	
	$script:HomeBkpDir = $script:Config.CONFIG.GENERAL.BackupRootFolder

    if ( !(Test-Path $script:HomeBkpDir) )
    {
		$JobResult.Message += "Path $($script:HomeBkpDir) does not exist" -f $script:LogFile
		Write-Verbose "Path $($script:HomeBkpDir) does not exist"
		$JobResult.State = "ERROR"
		Generate-Report
    }
	
	# Load PowerShell module "servermanager"
	Import-Module -Name servermanager -ErrorAction SilentlyContinue -ErrorVariable ErrModule
	
	if ( !($ErrModule) )
	{	
		# Check if WSB features are missing
		$Features = Get-WindowsFeature -Name "*backup*"
		
		foreach ( $Feature in $Features )
		{
			if ($Feature.Installed -eq $False )
			{
				try
				{ 
					Add-WindowsFeature -Name $Feature.Name
					Write-log -Message ($Messages.get_Item(2) -f $($Feature.Name)) -Indent $script:Indent -Path $LogFile
				}
				catch
				{
					Write-log -Message "$($_.Exception).Message)" -Indent $script:Indent -Path $LogFile -Level "Error"
					$JobResult.Message += "$($_.Exception).Message)"
					Write-Verbose "$(($_.Exception).Message)"
					Return $false
				}
			}
		}
		
	    # Adding Powershell WSB module
        if ( $Host.Version.Major -lt 5 )
        {
            if ( (Get-PSSnapin -Name Windows.ServerBackup -ErrorAction SilentlyContinue) -eq $null )
            {
		        Add-PSSnapin Windows.ServerBackup -ErrorVariable ErrPSSnapin | Out-Null
            }
		
		    if ( $ErrPSSnapin )
		    {
			    Write-log -Message $Messages.get_Item(10) -Indent $script:Indent -Path $LogFile -Level "Error"
			    $JobResult.Message += $Messages.get_Item(10)
			    Return $false
		    }
        }
		
		if ($Compress)
		{
			# 7Zip
			if ( -not(Test-Path ($ToolsFolder, "7z.exe" -join "\")) -or -not(Test-Path ($ToolsFolder, "7z.dll" -join "\")) )
			{
				Write-log -Message ($($Messages.get_Item(1)) -f $ToolsFolder) -Indent $script:Indent -Path $LogFile -Level "Error"
				$JobResult.Message += $Messages.get_Item(1)
				Return $False
			}
		}
		
		Return $true
	}
	else
	{
		Write-log -Message "$($ErrModule.Exception)" -Indent $script:Indent -Path $LogFile -Level "Error"
		$JobResult.Message += "$($ErrModule.Exception)"
		Return $false
	}
}

#---------------------------------------------------
# Compress the new backup folder
#---------------------------------------------------
function Compress-Backup($Folder)
{
	Write-Verbose "Inside function Compress-Backup"
	
	if (Test-Path $Folder)
	{
		$strCMD = "$($ToolsFolder, '7z.exe' -join "\") a -t7z $($($HomeBkpDir,$BackupFolder -join "\"),'7z' -join '.') $Folder"
		$ZipSummary = @(Invoke-Expression $strCMD)
		Remove-Item -Path $Folder -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
		
		if ( $ZipSummary[-1] -match "Everything is Ok" )
		{ 
			$JobResult.Filename = $BackupFolder,'7z' -join '.'
			$JobResult.Compression = "SUCCESSFUL"
			Write-log -Message ($($Messages.get_Item(17)) -f $Folder,$JobResult.Filename) -Indent $script:Indent -Path $LogFile
			Return $True
		}
		else
		{
			$7ZipLog = ('7Zip-Error',(Get-Date -Format 'MMddyyyyhhmm') -join '-'),"log" -join "."
			$ZipSummary | Out-File $($script:LogPath, $7ZipLog -join '\')
			Write-log -Message ($($Messages.get_Item(16)) -f $Folder,$($script:LogPath, $7ZipLog -join '\')) -Indent $script:Indent -Path $LogFile -Level "Warning"
			$JobResult.Compression = "WARNING"
			$JobResult.Message += "check compression log file $7ZipLog for more information"
			Return $True
		}	
	}
	else
	{ 
		$JobResult.Compression = "ERROR"
		$JobResult.Message += $Messages.get_Item(24)
		Return $False
	}
}

#---------------------------------------------------
# Function to create the log file header
#---------------------------------------------------
function Create-LogHeader {

	#region Parameters
	
	Param(
		[Parameter(Mandatory=$true)] [ValidateNotNullOrEmpty()]
		[IO.FileInfo] $Path,
		
		[Parameter()]
		[Boolean] $Main=$false
	)
	
	#endregion
	
	Begin {}
	
	Process {
		Write-Log -Message "$('-' * 45)" -Path $Path
		Write-Log -Message " Script: 		$ScriptName" -Path $Path
		Write-Log -Message " Start time: 		$(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')" -Path $Path
		if (!$Main) { Write-Log -Message " Server:		$($env:computername)" -Path $Path }
		Write-Log -Message " Username:		$($env:username)" -Path $Path
		Write-Log -Message "$('-' * 45)" -Path $Path
		Write-Log -Message "`n" -Path $Path
	}
	
	End {}

}

#---------------------------------------------------
# Function to return the list of backups of a rotation type
# (Monthly,Weekly,Daily)
#---------------------------------------------------
function Get-BackupFiles($Type)
{
	Write-Verbose "Inside function Get-BackupFiles"
	
	try
	{
		$Backups = Get-ChildItem -Path $HomeBkpDir | where-object { ($_.Name -like "$env:COMPUTERNAME*") -and ($_.Name -like"*$type*") } | Sort-Object LastWriteTime
		Return $Backups
	}
	catch
	{ 
		Return $null
	}
}

#---------------------------------------------------
# Return the total size needed (in GB) for the backup 
# based on the last backup file(Size of compressed 
# file and uncompressed files)
#---------------------------------------------------
function Get-BackupSize($File)
{
	Write-Verbose "Inside function Get-BackupSize"
	
	$strCMD = "$($ToolsFolder, '7z.exe' -join '\') l $File"
	$FileSummary = @(Invoke-Expression $strCMD)
	
	if ( $FileSummary[-1] -notlike "*error*" )
	{
		try
		{
			[Double] $UncompressedSize = "{0:N2}" -f $($((-split $FileSummary[-1].trim())[0])/1GB)
			[Double] $CompressedSize = "{0:N2}" -f $($((-split $FileSummary[-1].trim())[1])/1GB)
			[Double] $TotalSize = $UncompressedSize+$CompressedSize
	
			Write-log -Message ($($Messages.get_Item(12)) -f $TotalSize) -Indent $script:Indent -Path $LogFile
			Return $TotalSize
		}
		catch
		{
			[int] $SpaceNeeded = $script:Config.CONFIG.GENERAL.MininumSpaceInGB
			Write-log -Message ($($Messages.get_Item(13)) -f $SpaceNeeded) -Indent $script:Indent -Path $LogFile -Level "Warning"
			$JobResult.Message += $Messages.get_Item(13) -f $SpaceNeeded
			Return $SpaceNeeded
		}
	}
	else
	{
		Write-log -Message "7Zip error: $($FileSummary[-1])" -Indent $script:Indent -Path $LogFile -Level "Error"
		[int] $SpaceNeeded = $script:Config.CONFIG.GENERAL.MininumSpaceInGB
		Write-log -Message ($($Messages.get_Item(13)) -f $SpaceNeeded) -Indent $script:Indent -Path $LogFile -Level "Warning"
		$JobResult.Message += $Messages.get_Item(13) -f $SpaceNeeded
		Return $SpaceNeeded
	}
}

<#
#---------------------------------------------------
# Return the freespace available on a specific 
# computer drive (in GB)
#---------------------------------------------------
Function Get-FreeDiskSpace($computer,$drive)
{
	Write-Verbose "Inside function Get-FreeDiskSpace"
	
 	$DriveData = Get-WmiObject -class Win32_LogicalDisk -computername $computer -filter "Name = '$drive'" 
	Return "{0:n2}" -f ($driveData.FreeSpace/1GB)
}
#>
#---------------------------------------------------
# Generate the final report and exit the script
#---------------------------------------------------
Function Generate-Report()
{
    if ($Compress)
    {
        if ( [string]::IsNullOrEmpty($JobResult.Compression) )
        {
            $JobResult.State = "ERROR"
			$JobResult.Compression = "ERROR"
        }
    }
    else
    {
        $JobResult.Compression = "DISABLED"
    }

    if ($Sync)
    {
        if ( [string]::IsNullOrEmpty($JobResult.Synchronization) )
        {
            $JobResult.State = "ERROR"
			$JobResult.Synchronization = "ERROR"
        }
    }
    else
    {
        $JobResult.Synchronization = "DISABLED"
    }

    if ( $JobResult.State -eq $null )
	{
		$JobResult.State = "SUCCESSFUL"
		Write-log -Message "$($env:computername) - SUCCESSFUL" -Indent $script:Indent -Path $MainLog
	}
	else
	{
		Write-log -Message "$($env:computername) - $($JobResult.State)" -Indent $script:Indent -Path $MainLog
	}

	if ($Notify)
	{
		Send-Email $JobResult
	}
	
	Write-Verbose "Log file: $($LogFile)"

   # Exit
}

#---------------------------------------------------
# Treat the WSB job result
#---------------------------------------------------
function Get-JobResult()
{
	Write-Verbose "Inside function Get-JobResult"
	
    # Retrieve backup job result
    $JobDetails = Get-WBJob -Previous 1
	
    # A backup already executed / Current backup job different than the previous
	if ( -[String]::IsNullOrEmpty($script:LastJob.StartTime) -or ($JobDetails.StartTime -notmatch  $script:LastJob.StartTime) )
	{
		Write-log -Message ($($Messages.get_Item(7)) -f $($JobDetails.JobState),$($JobDetails.EndTime)) -Indent $script:Indent -Path $LogFile
		$JobResult.EndTime = $JobDetails.EndTime
		$JobResult.StartTime = $JobDetails.StartTime
		
		if ( $JobDetails.HResult -eq 0 )
		{
			Write-log -Message "Backup job result: success" -Indent $script:Indent -Path $LogFile
		}
		else
		{ 
			Write-log -Message ($($Messages.get_Item(8)) -f $($JobDetails.HResult)) -Indent $script:Indent -Path $LogFile -Level "Error"
		}
		
		if ( $JobDetails.FailureLogPath -ne "" )
		{
		#>	if ( (Get-Content $JobDetails.FailureLogPath) -ne "" )
			{
				$JobResult.FailureLogPath = $JobDetails.FailureLogPath
				Write-log -Message ($($Messages.get_Item(9)) -f $($JobDetails.FailureLogPath)) -Indent $script:Indent -Path $LogFile -Level "Warning"
			}
		}
		
		$JobResult.HResult = $JobDetails.HResult
		Return $true
	}
	else
	{
		Write-log -Message $Messages.get_Item(11) -Indent $script:Indent -Path $LogFile -Level "Error"
		Return $false 
	}
}


#---------------------------------------------------
#Remove the backup specified
#---------------------------------------------------
function Remove-Backup($File)
{
	Write-Verbose "Inside function Remove-Backup"
	
	try
	{
		$File | Remove-Item -Force -Recurse -Confirm:$false

		Write-log -Message ($($Messages.get_Item(5)) -f $($File.Name)) -Indent ($script:Indent+1) -Path $LogFile
		
		if ($JobResult.RemoveBackups -eq $null)
		{
			$JobResult.RemovedBackups = $File.Name
		}
		else
		{ 
			$JobResult.RemovedBackups += "`t$($File.Name)"
		}
	}
	catch
	{
		$JobResult.State = "WARNING"
		$JobResult.Details = ($($Messages.get_Item(6)) -f $($File.Name))
		Write-log -Message ($($Messages.get_Item(6)) -f $($File.Name)) -Indent ($script:Indent+1) -Path $LogFile -Level "Warning"
	}
}

#---------------------------------------------------
# Start the backup job
#---------------------------------------------------
function Run-Backup()
{
	Write-Verbose "Inside function Run-Backup"
	
	# Create the backup policy
	$WBPolicy = New-WBPolicy

    if ($Script:BackupType -match "SystemState")
    {
	    Add-WBSystemState -Policy $WBPolicy | Out-Null
    }
    else
    {
        Add-WBBareMetalRecovery -Policy $WBPolicy | Out-Null
    }


	# Define the volume path to stock temporary the backup
	$BackupLocation = New-WBBackupTarget -NetworkPath $HomeBkpDir
	Add-WBBackupTarget -Policy $WBPolicy -Target $BackupLocation -WarningAction SilentlyContinue -Force | Out-Null
	$WBPolicy | Out-Null
	
	$script:LastJob = Get-WBJob -Previous 1
	$JobResult.StartTime = Get-Date -Format "M/d/yyyy"
	
	try
	{
		Start-WBBackup -Policy $WBPolicy -Force
	}
	catch
	{
		Write-Verbose "backup job failed: $($_.Exception.Message)"
		$JobResult.Message += $($_.Exception.Message)
		Write-log -Message $($_.Exception.Message) -Indent ($script:Indent) -Path $LogFile -Level "Error"
		Generate-Report
	}	
}

#---------------------------------------------------
# Run the rotation to remove stale backups
#---------------------------------------------------
function Run-Rotation($Type)
{
	Write-Verbose "Inside function Run-Rotation: $Type"
	
	$Backups = Get-BackupFiles $Type
	
	if ( $Backups -ne $null )
	{
		if ($Backups.Count -gt 0)
		{ 
			$NbrBackups = $Backups.count
		
			$i = 0
	
			while ($NbrBackups -ge $Rotation)
 			{
				Remove-Backup $Backups[$i]
				$NbrBackups -= 1
				$i++
 			}
		}
	}
	else
	{
		$NbrBackups = 0
	}
	
	Write-log -Message ($($Messages.get_Item(4)) -f $Type,$NbrBackups)  -Indent $script:Indent -Path $LogFile
}

#---------------------------------------------------
# Function to send a reporting by email
#---------------------------------------------------
function Send-Email($Job)
{
	Write-Verbose "Inside function Send-Email"
	
	$Subject = " ($($env:computername)) SKED Backup Notification - $($Job.RotationType) - $($Job.State)"

	$css = "<style>TABLE{border-width: 1px; padding: 8px; border-style: solid; border-color: #999999; `
			font-family: Arial; font-weight: normal; font-style: normal; font-variant: normal; font-size: small;}</style>"
	
	$Body = $Job | Out-String

    <# $Body = $Job | ConvertTo-Html -As List -Head $css | foreach { `
			#if ($_ -match "<tr><td>(.*)</td><td>(.*)</td></tr>*"){ `
            if ($_ -match "<tr><td>(.*)</td><td>(.*)(.|\n)*</td></tr>*"){ `
				$name,$value = $matches[1..2]; `
				# if ( $value -ne "") {"<tr><td width=150><b>$($name -replace ':','')</b></td><td width=600>$value</td></tr>"} } `
                if ( -not([string]::IsNullOrEmpty($value)) ) {"<tr><td width=150><b>$($name -replace ':','')</b></td><td width=600>$value</td></tr>"} } `
			else{$_} } | Out-String

        	
	<# $SMTPclient = new-object System.Net.Mail.SmtpClient $script:Config.CONFIG.NOTIFICATION.SmtpServerName
 
	<# SMTP Port
	$SMTPClient.port = $script:Config.CONFIG.NOTIFICATION.SmtpServerPort
 
	<# Enable SSL
	if ( $script:Config.CONFIG.NOTIFICATION.Ssl )
	{
		$SMTPclient.EnableSsl = $true
	}
 
	<# Credentials
	if ( $script:Config.CONFIG.NOTIFICATION.SmtpServerUsername -and $script:Config.CONFIG.NOTIFICATION.SmtpServerPassword)
	{
		$SMTPAuthUsername = $script:Config.CONFIG.NOTIFICATION.SmtpServerUsername
		$SMTPAuthPassword = $script:Config.CONFIG.NOTIFICATION.SmtpServerPassword
		$SMTPClient.Credentials = New-Object System.Net.NetworkCredential($SMTPAuthUsername, $SMTPAuthPassword)
 	}
  #>
    try
    {

      Send-MailMessage -SmtpServer $script:Config.CONFIG.NOTIFICATION.SmtpServerName -From $script:Config.CONFIG.NOTIFICATION.Sender -To $script:Config.CONFIG.NOTIFICATION.recipient -Subject $Subject -Body $Body -ErrorAction Stop


     <#   $MailMessage = new-object System.Net.Mail.MailMessage
        $MailMessage.From = $script:Config.CONFIG.NOTIFICATION.Sender
        $MailMessage.Subject = $Subject
        $MailMessage.Body = $Body 

	    $MailMessage.IsBodyHtml = $true

        foreach ( $Recipient in $script:Config.CONFIG.NOTIFICATION.Recipient )
        {
            $MailMessage.To.Add($Recipient)
        }

	    $SMTPclient.Send($MailMessage)

        Write-log -Message "Mail sent" -Indent $script:Indent -Path $LogFile
        #>

    }
    catch
    {
        Write-log -Message "Unable to send mail: $($_.Exception.Message)" -Indent $script:Indent -Path $LogFile -Level Error
    }
}

#---------------------------------------------------
# Function to define the type of backup and retention
#---------------------------------------------------
function Set-BackupType()
{
	Write-Verbose "Inside function Set-BackupType"
	
	$Date = Get-Date
	
	# Monthly Backup if we are the 1st day of the month
	if ($Date.Day -eq 1)
	{
		$StringMonth = Get-Date -Format MMMM
		$script:BackupFolder = -join ($script:BackupFolder,"-Monthly-$($StringMonth)")
		$script:Rotation = $script:Config.CONFIG.GENERAL.MonthRetention
		$Result = "Monthly"	
	}
	# Weekly Backup if we are monday
	elseif ($Date.DayOfWeek -match "Monday")
	{
		$IntWeek = Get-Date -UFormat %V
		$script:BackupFolder = -join ($script:BackupFolder,"-Weekly-W$IntWeek")
		$script:Rotation = $script:Config.CONFIG.GENERAL.WeekRetention
		$Result = "Weekly"
	}
	else
	{
		$IntWeek = Get-Date -UFormat %V
		$script:BackupFolder = -join ($script:BackupFolder,"-Daily-W$IntWeek-$($Date.DayOfWeek)")
		$script:Rotation = $script:Config.CONFIG.GENERAL.DayRetention
		$Result = "Daily"
	}
	
	Write-log -Message "Type of rotation: $Result" -Indent $script:Indent -Path $LogFile
	Write-log -Message "Rotation : $script:Rotation" -Indent $script:Indent -Path $LogFile
	$JobResult.RotationType = $Result
	Return $Result
}

#---------------------------------------------------
# Function sync backups using robocopy
#---------------------------------------------------
function Sync-Backup()
{
    Write-Verbose "Inside function Sync-Backup"

    if ( $script:Config.CONFIG.DESTINATION.SyncServerName -and $script:Config.CONFIG.DESTINATION.SyncFolderName )
	{
		$SyncPath = "\\$($script:Config.CONFIG.DESTINATION.SyncServerName)\$($script:Config.CONFIG.DESTINATION.SyncFolderName)\$($env:computername)"
		Write-log -Message ($($Messages.get_Item(26)) -f $SyncPath) -Indent $script:Indent -Path $script:LogFile

		if ( Test-Path $SyncPath )
		{
			$SourceContent = Get-ChildItem $HomeBkpDir | Sort-Object LastWriteTime
			$DestinationContent = Get-ChildItem $SyncPath | Sort-Object LastWriteTime
				
			if ( $SourceContent )
			{
				if ( $DestinationContent )
				{
					$DiffContent = Compare-Object $SourceContent $DestinationContent | Where-Object { $_.InputObject -notmatch "logs" }
				}

				if ( $DiffContent -or ($DestinationContent -eq $null) )
				{
					$strCMD = "ROBOCOPY $HomeBkpDir $SyncPath /MIR /LEV:1 /NJH /NP"
					$Result = Invoke-Expression -Command $strCMD
						
					# Create the robocopy log file
					$LogRobocopyFile = New-Object IO.FileInfo "$($script:LogPath)\$($env:computername)-ROBOCOPY-$(get-date -format MMddyyHHmmss).log"
					New-Item $LogRobocopyFile -Type file -Value $Result -Force -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable ErrLogFile | Out-Null
					Set-Content -Value $Result -Path $LogRobocopyFile
				}
					
				$DestinationContent = Get-ChildItem $SyncPath | Sort-Object LastWriteTime
					
				if ( $DestinationContent )
				{
					$DiffContent = Compare-Object $SourceContent $DestinationContent | Where-Object { $_.InputObject -notmatch "logs" }
				}
					
				if ($DiffContent -or ($DestinationContent -eq $null) )
				{
					$SyncMessage = "Content not similar or destination is empty. Please check synchronization job ($LogRobocopyFile)."
				}
				else
				{
					$JobResult.Synchronization = "SUCCESSFUL ($LogRobocopyFile)"
					Write-log -Message  "Synchronization done successfuly ($LogRobocopyFile)." -Indent $script:Indent -Path $LogFile
				}				
			}
		}
		else
		{
			$SyncMessage = " Unable to access to $($SyncPath)."
		}
	}
	else
	{
		$SyncMessage = " Synchronization failed. Missing parameters from the config file."
	}
		
	if ($SyncMessage)
	{
		Write-Verbose $SyncMessage
		$JobResult.Synchronization = "ERROR"
		$JobResult.State = "ERROR"
		Write-log -Message $SyncMessage -Indent $script:Indent -Path $LogFile -Level "Error"
		$JobResult.Message += $SyncMessage
	}
}

#---------------------------------------------------
# Function to test the XML Config file
#---------------------------------------------------
function Test-XML
{
    param
    (
        [Parameter(Mandatory=$true)]
        [IO.FileInfo] $Path,
		
		[Parameter(Mandatory=$true)]
        [String] $Schema
    )
    
	Write-Verbose "Inside function Test-XML"
	
	$script:IsValid = $true
	$SchemaStringReader = New-Object System.IO.StringReader $XMLSchema
	$XmlReader = [System.Xml.XmlReader]::Create($SchemaStringReader)
		
    $settings = new-object System.Xml.XmlReaderSettings     
    $settings.ValidationType = [System.Xml.ValidationType]::Schema
    $settings.ValidationFlags = [System.Xml.Schema.XmlSchemaValidationFlags]::None
    $schemaSet = New-Object system.Xml.Schema.XmlSchemaSet;
    $settings.ValidationFlags = $settings.ValidationFlags -bor [System.Xml.Schema.XmlSchemaValidationFlags]::ProcessSchemaLocation

 	$schemaSet.Add($null, $XmlReader) | Out-Null
    $settings.Schemas = $schemaSet
 
    $settings.add_ValidationEventHandler(
        {
            Write-Error $_.Message
            $script:IsValid = $false
        })
 
    $reader = [System.Xml.XmlReader]::Create($Path.FullName, $settings)

    try
    {
        while($reader.Read()){}
        $reader.Close()
        $true -and $script:IsValid
    }
    catch
    {
        if (!$reader.ReadState -eq "Closed") { $reader.Close() }
        $false
    }
}

#---------------------------------------------------
# Function to manage the log file
#---------------------------------------------------
function Write-Log {

	#region Parameters
		Param(
			[Parameter(ValueFromPipeline=$true,Mandatory=$true)] [ValidateNotNullOrEmpty()]
			[string] $Message,
			
			[Parameter()] [ValidateRange(1,30)]
			[Int16] $Indent = 0,

			[Parameter()]
			[IO.FileInfo] $Path = ”$env:temp\PowerShellLog.txt”,
			
			[Parameter()] [ValidateSet("Error","Warning","Info")]
			[String] $Level = "Info"
		)
	#endregion

	Begin {}

	Process {
		$msg = '{0} *{1}*	{2}{3}' -f (Get-Date -Format “yyyy-MM-dd HH:mm:ss”), $Level.ToUpper(), (" " * $Indent), $Message
		$msg | Out-File -FilePath $Path -Append
		
		switch($Level) {
			"Error" { $script:JobResult.State = $Level.ToUpper() }
			"Warning" { if ($script:JobResult.State -notmatch "Error") { $script:JobResult.State = $Level.ToUpper() } }
		}
	}

	End {}
}

#EndRegion

####################################################
# Main
####################################################

# Check the prerequisites
if ( -not(Check-Prerequisites) ) 
{ 
	$JobResult.State = "ERROR"
	Generate-Report
}

$JobResult.BackupType = $BackupType
Write-log "Backup type: $BackupType" -Path $LogFile -Indent $script:Indent

$OptionsMsg = "Options: "

if ( $Compress )
{
    $Optionsmsg += "`nCompress"
}
if ( $Sync )
{
    $Optionsmsg += "`nSync"
}

if ( $Notify )
{
    $Optionsmsg += "`nNotify"
}

Write-log $OptionsMsg -Path $LogFile -Indent $script:Indent

# Return the backup type and define the rotation
$RotationType = Set-BackupType

# Launch the backup rotation (based on the backup type)
Run-Rotation $RotationType

# Get the backup files list (based on the backup type)
$BackupsFiles =  Get-BackupFiles $RotationType
	
<# Evaluate space
$SpaceAvailable = Get-FreeDiskSpace "localhost" (Split-Path $HomeBkpDir -Qualifier)
	
if ($BackupsFiles -ne $null)
{
	if ($BackupsFiles.count -eq $null) 
	{
		$SpaceNeeded = Get-BackupSize ($HomeBkpDir,$BackupsFiles -join "\") 
	}
	else
	{ 
		$SpaceNeeded = Get-BackupSize ($HomeBkpDir,$BackupsFiles[0] -join "\") 
	}
}
else
{
	[int] $SpaceNeeded = $script:Config.CONFIG.GENERAL.MininumSpaceInGB
	Write-log -Message ($($Messages.get_Item(13)) -f $SpaceNeeded) -Indent $script:Indent -Path $LogFile -Level "Warning"
	$JobResult.Message += $Messages.get_Item(13) -f $SpaceNeeded
}

<# Compare the space needed with the space available
if ( $SpaceNeeded -ge (Get-FreeDiskSpace "localhost" (Split-Path $HomeBkpDir -Qualifier)) )
{
	if ( $BackupsFiles -eq $null )
	{ 
		Write-log -Message $Messages.get_Item(14) -Indent $script:Indent -Path $LogFile -Level "Error"
		Generate-Report
	}
	else
	{
		Remove-Backup $BackupsFiles[0]
			
		if ( $SpaceNeeded -ge (Get-FreeDiskSpace localhost (Split-Path $HomeBkpDir -Qualifier)) )
		{
			Write-log -Message $Messages.get_Item(15) -Indent $script:Indent -Path $LogFile -Level "Error"
			Generate-Report
		}
	}
}

#>
	
# Launch backup
Run-Backup
	
# Identify the current backup folder
$BackupTempFolder = $HomeBkpDir ,"WindowsImageBackup" -join "\"
	
# Compress WindowsImageBackup folder if specified
if ($Compress)
{
	if (Get-JobResult)
	{		
		if ( Test-Path $BackupTempFolder )
		{
            # Compress and synchronize folder
			if (Compress-Backup $BackupTempFolder)
            { 
                if ($Sync)
	            {
                    Sync-Backup
                }
	        }
		}
	}
	else
	{
		if ( Test-Path $BackupTempFolder )
		{
			Remove-Item -Path $BackupTempFolder -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
		}
	}
}
else
{
    $JobResult.Compression = "DISABLED"

	if (Get-JobResult -and Test-Path $BackupTempFolder )
	{	
		$BackupDestination = $HomeBkpDir,$BackupFolder -join "\"
				
		if ( $BackupDestination )
		{
			Remove-Item -Path $BackupDestination -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
		}
				
		Move-Item -Path $BackupTempFolder -Destination $BackupDestination -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

        # Synchronize folders
	    if ($Sync)
	    {
            Sync-Backup
	    }
	}
	else
	{
		if ( Test-Path $BackupTempFolder )
		{
			Remove-Item -Path $BackupTempFolder -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
		}
	}
}

Generate-Report