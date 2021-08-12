<#
.SYNOPSIS
    LR-HealthMonitor_v2.ps1 is a robust health monitoring script for LogRhythm deployments
.DESCRIPTION
    LR-HealthMonitor_v2.ps1 is a robust health monitoring script for LogRhythm deployments which check various health indicators related to a 
    The script currently checks the following:
        -Service status (for Windows servers)
        -Server disc space (for Windows servers)
        -Backlog for AIE Data folders and Mediator DXReliablePersist folders
        -Indexer cluster status, node count and active index count
        -Database maintenance job status and last runtime
        -LogRhythm_Events partition size
    The script can either output/email a report of the status of all these metrics, or output/email warnings based on configurable threshold
    Configuration is stored in the hosts_v2.json file
.NOTES
    This version created by Mike Contasti-Isaac, September 2020
.PARAMETER OutputReport
    Outputs a report of all metrics
.PARAMETER EmailReport
    Emails a report of all metrics
.PARAMETER OutputWarnings
    Outputs any warnings based on configurable thresholds
.PARAMETER EmailWarnings
    Emails any warnings based on configurable thresholds
.PARAMETER NoSQL
    Bypasses checks on database metrics.  Use this if you cannot connect to the SQL database, or do not wish to report on these metrics
.EXAMPLE
    LR-HealthMonitor_v2.ps1 -OutputReport
    LR-HealthMonitor_v2.ps1 -EmailWarnings
    LR-HealthMonitor_v2.ps1 -OutputReport -NoSQL
.NOTES
    Change Log:
        2021/05/27 - Major update (including adding this change log) - added robust logging capabilities to enable alerting in LogRhythm
        2021/06/07 - Added Spooled Events folder file count check
        2021/06/21 - Fixed bug in log rotation, added date/time header for report and warnings
 #>

[CmdletBinding()]
param([switch]$EmailWarnings, [switch]$EmailReport, [switch]$OutputReport, [switch]$OutputWarnings, [switch]$NoSQL)

$file = "C:\LogRhythm\Scripts\LR-HealthMonitor\hosts.json"
$hosts = Get-Content -Raw $file | ConvertFrom-Json
$drivewarning = $hosts.config.drivewarning # Percentage of drive free under which a warning is issued
$dxrpwarning = $hosts.config.DXRPWarning # Number of files in DXReliablePersist folder above which a warning is issued
$spooledeventswarning = $hosts.config.SpooledEventsWarning
$aiedatawarning = $hosts.config.AIEWarning # Number of files in AIE Data folder above which a warning is issued
$smtpserver = $hosts.config.smtpserver
$mailfrom = $hosts.config.mailfrom
$mailrecipients = @($hosts.config.recipients)
$reportsubject = $hosts.config.reportsubject
$warningsubject = $hosts.config.warningsubject
$sqlserver = $hosts.database.server
$sqluser = $hosts.database.user
$sqlpassword = $hosts.database.password
$globalloglevel = $hosts.config.loglevel
$logfile = $hosts.config.logfile
#$sqlcredential = New-Object System.Management.Automation.PsCredential($sqluser, $sqlpassword)

Function Write-Log {  

    # This function provides logging functionality.  It writes to a log file provided by the $logfile variable, prepending the date and hostname to each line
    # Currently implemented 4 logging levels.  1 = DEBUG / VERBOSE, 2 = INFO, 3 = ERROR / WARNING, 4 = CRITICAL
    # Must use the variable $globalloglevel to define what logs will be written.  1 = All logs, 2 = Info and above, 3 = Warning and above, 4 = Only critical.  If no $globalloglevel is defined, defaults to 2
    # Must use the variable $logfile to define the filename (full path or relative path) of the log file to be written to
    # Auto-rotate feature written but un-tested (will rotate logfile after 10 MB)
           
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)] [string]$logdetail,
        [Parameter(Mandatory = $false)] [int32]$loglevel = 2
    )
    if (($globalloglevel -ne 1) -and ($globalloglevel -ne 2) -and ($globalloglevel -ne 3) -and ($globalloglevel -ne 4)) {
        $globalloglevel = 2
    }

    if ($loglevel -ge $globalloglevel) {
        try {
            $logfile_exists = Test-Path -Path $logfile
            if ($logfile_exists -eq 1) {
                if ((Get-Item $logfile).length/1MB -ge 10) {
                    $logfilename = [io.path]::GetFileNameWithoutExtension($logfile)
                    $newfilename = "$($logfilename)"+ (Get-Date -Format "yyyyMMddhhmmss").ToString() + ".log"
                    Rename-Item -Path $logfile -NewName $newfilename
                    New-Item $logfile -ItemType File
                    $this_Date = Get-Date -Format "MM\/dd\/yyyy hh:mm:ss tt"
                    Add-Content -Path $logfile -Value "$this_Date [$env:COMPUTERNAME] $logdetail"
                }
                else {
                    $this_Date = Get-Date -Format "MM\/dd\/yyyy hh:mm:ss tt"
                    Add-Content -Path $logfile -Value "$this_Date [$env:COMPUTERNAME] $logdetail"
                }
            }
            else {
                New-Item $logfile -ItemType File
                $this_Date = Get-Date -Format "MM\/dd\/yyyy hh:mm:ss tt"
                Add-Content -Path $logfile -Value "$this_Date [$env:COMPUTERNAME] $logdetail"
            }
        }
        catch {
            Write-Error "***ERROR*** An error occured writing to the log file: $_"
        }
    }
}

Function Get-DriveStatus([String]$hostname, [String]$driveletter) {
    Write-Log -loglevel 1 -logdetail "[INFO] Retrieving disc space information for $($driveletter) on $($hostname)"
    Try {
        $thisdisk = Get-WmiObject win32_logicaldisk -ComputerName $hostname -Filter "DeviceID='$driveletter'"
        [math]::truncate($thisdisk.Size / 1GB)
        [math]::truncate($thisdisk.FreeSpace / 1GB)
        $percent = [math]::round(($thisdisk.FreeSpace / $thisdisk.Size),2)
        $percent
    }
    Catch {
        Write-Log -loglevel 3 -logdetail "***ERROR*** An error occured retrieving drive statistics for host $($hostname), drive $($driveletter): $_"
        "Error retrieving drive statistics"
    }
}

Function Get-ServerServices([String]$hostname) {
    Write-Log -loglevel 1 -logdetail "[INFO] Retrieving service information for host $($hostname)"
    Try {
        $serverservices = Get-WmiObject Win32_service -Computer $hostname
        $serverservices
        Write-Log -loglevel 1 -logdetail "[INFO] Succesfully retrieved service information for host $($hostname)"
    }
    Catch {
        Write-Log -loglevel 3 -logdetail "***ERROR*** An error occured retrieving service information for host $($hostname): $_"
        "Error retrieving server services"
    }
}

Function Get-DirFileCount($hostname, $directory) {
    $directory = $directory -replace "\\","\\"
    write-log -loglevel 1 -logdetail "[INFO] Retrieving file count for directory $($directory) on host $($hostname)"
    Try {        
        $filecount = Get-WmiObject CIM_DataFile -ComputerName $hostname -filter "Drive='$($directory.SubString(0,2))' AND path='$($directory.SubString(2))'"
        $filecount.Count
        Write-Log -loglevel 1 -logdetail "[INFO] Succesfully retrieved file count for directory $($directory) on host $($hostname)"
    }
    Catch {
        Write-Log -loglevel 3 -logdetail "***ERROR*** An error occured retrieving file count for directory $($directory) on host $($hostname): $_"
        "Error Reading Remote Directory"
    }
}

Function Get-ClusterInfo($hostname) {
    Write-Log -loglevel 1 -logdetail "[INFO] Retrieving cluster information for cluster on host $($hostname)"
    Try {
        $dxstatus = Invoke-RestMethod "http://$($hostname):9200/_cluster/health?level=indices&pretty"
        $dxindices = (Invoke-WebRequest -Uri "http://$($hostname):9200/_cat/indices").Content | FindStr "logs-"  | Measure-Object -Line
        Return $dxstatus, $dxindices
        Write-Log -loglevel 1 -logdetail "[INFO] Succesfully retrieved status for cluster on $($hostname)"
    }
    Catch {
        Write-Log -loglevel 3 -logdetail "***ERROR*** An error occured retrieving cluster info for cluster on host $($hostname): $_"
        "Error retreiving cluster statistics"
    }
}
    

Function Get-HostsData($hostjson) {
    Write-Log -loglevel 1 -logdetail "[INFO] Consolidating host data..."
    $hoststatus = @()
    $hostjson.hosts | ForEach-Object {
        $thisHost = New-Object -TypeName psobject
        $Hostname = $_.hostname
        $drives = @()
        ForEach ($drive in $_.drives) {
            $thisdrive = New-Object -TypeName psobject
            $thisdrivestatus = Get-DriveStatus $Hostname $drive
            $thisdrive | Add-Member -MemberType NoteProperty -Name DriveLabel -Value $drive
            $thisdrive | Add-Member -MemberType NoteProperty -Name DriveCapacityGB -Value $thisdrivestatus[0]
            $thisdrive | Add-Member -MemberType NoteProperty -Name DriveFreeGB -Value $thisdrivestatus[1]
            $thisdrive | Add-Member -MemberType NoteProperty -Name DrivePercentFree -Value $thisdrivestatus[2]
            $drives += $thisdrive
        }
        $services = @()
        $serverservices = Get-ServerServices($Hostname)
        ForEach ($service in $_.services) {
            $thisservice = New-Object -TypeName psobject
            $thisservicestatus = $($serverservices | where DisplayName -eq $service).State
            $thisservice | Add-Member -MemberType NoteProperty -Name ServiceName -Value $service
            $thisservice | Add-Member -MemberType NoteProperty -Name ServiceStatus -Value $thisservicestatus
            $services += $thisservice
        }
        if ($_.IsDP -eq "Yes") {
            $DXRPCount = Get-DirFileCount $_.hostname $_.DXRP_Directory
            $SpooledEventsCount = Get-DirFileCount $_.hostname $_.SpooledEventstDirectory
            $thishost | Add-Member -MemberType NoteProperty -Name DXRPCount -Value $DXRPCount
            $thishost | Add-Member -MemberType NoteProperty -Name SpooledEventsCount -Value $SpooledEventsCount
        }
        if ($_.IsAIE -eq "Yes") {
            $AIEDataCount = Get-DirFileCount $_.hostname $_.AIEData_Directory
            $thishost | Add-Member -MemberType NoteProperty -Name AIEDataCount -Value $AIEDataCount
        }

        $thishost | Add-Member -MemberType NoteProperty -Name Hostname -Value $Hostname
        $thishost | Add-Member -MemberType NoteProperty -Name Drives -Value $drives
        $thisHost | Add-Member -MemberType NoteProperty -Name Services -Value $services
        $hoststatus += $thisHost
    }
    Write-Log -loglevel 1 -logdetail "[INFO] Consolidation complete"
    $hoststatus
}

Function Get-ClustersStatus($hostjson) {
    Write-Log -loglevel 1 -logdetail "[INFO] Consolidating cluster information"
    $clusterstatus = @()
    $hostjson.clusters | ForEach-Object {
        $thisCluster = New-Object -TypeName psobject
        $cluster, $clusterindices = Get-ClusterInfo $_.clusteraddress
        $thisCluster | Add-Member -MemberType NoteProperty -Name Cluster -Value $_.clustername
        $thisCluster | Add-Member -MemberType NoteProperty -Name Nodes -Value $cluster.number_of_nodes 
        $thisCluster | Add-Member -MemberType NoteProperty -Name Status -Value $cluster.status
        $thisCluster | Add-Member -MemberType NoteProperty -Name ActivePercent -Value $cluster.active_shards_percent_as_number
        $thisCluster | Add-Member -MemberType NoteProperty -Name ActiveIndices -Value $clusterindices.Lines
        $clusterstatus += $thisCluster
    }
    Write-Log -loglevel 1 -logdetail "[INFO] Consolidation complete"
    $clusterstatus
}

Function Get-DBJobHistory {
    $query_Sunday = "SELECT TOP 1 j.name as 'JobName', MIN(j.enabled) AS 'Enabled', run_date AS 'LastRunDate', SUM(run_time) AS 'TotalTime', MIN(run_status) AS 'Status' FROM msdb.dbo.sysjobs j INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id WHERE j.enabled = 1  AND j.name = 'LogRhythm Sunday Maintenance' GROUP BY j.name, run_date ORDER BY run_date DESC"
    $query_Saturday = "SELECT TOP 1 j.name as 'JobName', MIN(j.enabled) AS 'Enabled', run_date AS 'LastRunDate', SUM(run_time) AS 'TotalTime', MIN(run_status) AS 'Status' FROM msdb.dbo.sysjobs j INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id WHERE j.enabled = 1  AND j.name = 'LogRhythm Saturday Maintenance' GROUP BY j.name, run_date ORDER BY run_date DESC"
    $query_Weekday = "SELECT TOP 1 j.name as 'JobName', MIN(j.enabled) AS 'Enabled', run_date AS 'LastRunDate', SUM(run_time) AS 'TotalTime', MIN(run_status) AS 'Status' FROM msdb.dbo.sysjobs j INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id WHERE j.enabled = 1  AND j.name = 'LogRhythm Weekday Maintenance' GROUP BY j.name, run_date ORDER BY run_date DESC"
    $query_Backup = "SELECT TOP 1 j.name as 'JobName', MIN(j.enabled) AS 'Enabled', run_date AS 'LastRunDate', SUM(run_time) AS 'TotalTime', MIN(run_status) AS 'Status' FROM msdb.dbo.sysjobs j INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id WHERE j.enabled = 1  AND j.name = 'LogRhythm Backup' GROUP BY j.name, run_date ORDER BY run_date DESC"
    $query_partitions = "EXEC LogRhythm_Events.dbo.LogRhythm_Events_Partitions_Query"
    $c_String = "Data Source=$sqlserver;Initial Catalog=msdb;User ID=$sqluser;Password=$sqlpassword;ApplicationIntent=ReadOnly"

    Write-Log -loglevel 1 -logdetail "[INFO] Retrieving SQL Maintenance job history and EventsDB partition information from server $($sqlserver)"
    Try {
        $history_weekday = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_Weekday
        $history_sunday = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_Sunday
        $history_saturday = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_Saturday
        $history_backup = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_Backup
        $events_partitions_data = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_partitions
        Write-Log -loglevel 1 -logdetail "[INFO] Succesfully retrieved information from SQL"
    }
    Catch {
        Write-Log -loglevel 3 -logdetail "***ERROR*** An error occured retrieving information from SQL: $_"
    }
    $events_partitions = @()
    foreach ($row in $events_partitions_data) {
        $this_row = New-Object -TypeName psobject        
        $this_row | Add-Member -MemberType NoteProperty -Name PartitionNumber -Value $row.Item("PartitionNumber")
        $this_row | Add-Member -MemberType NoteProperty -Name PartitionRow -Value $row.Item("PartitionRows")
        $this_row | Add-Member -MemberType NoteProperty -Name PartitionDate -Value $row.Item("Value")
        $events_partitions += $this_row
    }
    Try {
        $weekday = New-Object -TypeName psobject
        $weekday | Add-Member -MemberType NoteProperty -Name JobName -Value $history_weekday[0]
        $weekday | Add-Member -MemberType NoteProperty -Name Enabled -Value $history_weekday[1]
        $weekday | Add-Member -MemberType NoteProperty -Name LastRunDate -Value $history_weekday[2]
        $weekday | Add-Member -MemberType NoteProperty -Name TotalRunTime -Value $history_weekday[3]
        $weekday | Add-Member -MemberType NoteProperty -Name RunStatus -Value $history_weekday[4]
    }
    Catch {
        $weekday = New-Object -TypeName psobject
        $weekday | Add-Member -MemberType NoteProperty -Name JobName -Value "LogRhythm Weekday Maintenance"
        $weekday | Add-Member -MemberType NoteProperty -Name Enabled -Value 0
        $weekday | Add-Member -MemberType NoteProperty -Name LastRunDate -Value "19000101"
        $weekday | Add-Member -MemberType NoteProperty -Name TotalRunTime -Value "N/A"
        $weekday | Add-Member -MemberType NoteProperty -Name RunStatus -Value "N/A"
    }
    Try{
        $saturday = New-Object -TypeName psobject
        $saturday | Add-Member -MemberType NoteProperty -Name JobName -Value $history_saturday[0]
        $saturday | Add-Member -MemberType NoteProperty -Name Enabled -Value $history_saturday[1]
        $saturday | Add-Member -MemberType NoteProperty -Name LastRunDate -Value $history_saturday[2]
        $saturday | Add-Member -MemberType NoteProperty -Name TotalRunTime -Value $history_saturday[3]
        $saturday | Add-Member -MemberType NoteProperty -Name RunStatus -Value $history_saturday[4]
    }
    Catch {
        $saturday = New-Object -TypeName psobject
        $saturday | Add-Member -MemberType NoteProperty -Name JobName -Value "LogRhythm Saturday Maintenance"
        $saturday | Add-Member -MemberType NoteProperty -Name Enabled -Value 0
        $saturday | Add-Member -MemberType NoteProperty -Name LastRunDate -Value "19000101"
        $saturday | Add-Member -MemberType NoteProperty -Name TotalRunTime -Value "N/A"
        $saturday | Add-Member -MemberType NoteProperty -Name RunStatus -Value "N/A"
    }    
    Try {
        $sunday = New-Object -TypeName psobject
        $sunday | Add-Member -MemberType NoteProperty -Name JobName -Value $history_sunday[0]
        $sunday | Add-Member -MemberType NoteProperty -Name Enabled -Value $history_sunday[1]
        $sunday | Add-Member -MemberType NoteProperty -Name LastRunDate -Value $history_sunday[2]
        $sunday | Add-Member -MemberType NoteProperty -Name TotalRunTime -Value $history_sunday[3]
        $sunday | Add-Member -MemberType NoteProperty -Name RunStatus -Value $history_sunday[4]
    }
    Catch {
        $sunday = New-Object -TypeName psobject
        $sunday | Add-Member -MemberType NoteProperty -Name JobName -Value "LogRHythm Sunday Maintenance"
        $sunday | Add-Member -MemberType NoteProperty -Name Enabled -Value 0
        $sunday | Add-Member -MemberType NoteProperty -Name LastRunDate -Value "19000101"
        $sunday | Add-Member -MemberType NoteProperty -Name TotalRunTime -Value "N/A"
        $sunday | Add-Member -MemberType NoteProperty -Name RunStatus -Value "N/A"
    }
    Try {
        $backup = New-Object -TypeName psobject
        $backup | Add-Member -MemberType NoteProperty -Name JobName -Value $history_backup[0]
        $backup | Add-Member -MemberType NoteProperty -Name Enabled -Value $history_backup[1]
        $backup | Add-Member -MemberType NoteProperty -Name LastRunDate -Value $history_backup[2]
        $backup | Add-Member -MemberType NoteProperty -Name TotalRunTime -Value $history_backup[3]
        $backup | Add-Member -MemberType NoteProperty -Name RunStatus -Value $history_backup[4]
    }
    Catch {
        $backup = New-Object -TypeName psobject
        $backup | Add-Member -MemberType NoteProperty -Name JobName -Value "LogRhythm Backup"
        $backup | Add-Member -MemberType NoteProperty -Name Enabled -Value 0
        $backup | Add-Member -MemberType NoteProperty -Name LastRunDate -Value "19000101"
        $backup | Add-Member -MemberType NoteProperty -Name TotalRunTime -Value "N/A"
        $backup | Add-Member -MemberType NoteProperty -Name RunStatus -Value "N/A"
    }    
    $history_results = @($weekday, $saturday, $sunday, $backup)      
    Return $history_results, $events_partitions
}

Function Get-DBJobWarnings($historyresults) {
    Write-Log -loglevel 1 -logdetail "[INFO] Consolidating warnings"
    $time_tolerance = New-TimeSpan -days 2
    $weekdaydate = [datetime]::ParseExact(($historyresults[0].LastRunDate).ToString(),'yyyyMMdd',$null)
    $saturdaydate = [datetime]::ParseExact(($historyresults[1].LastRunDate).ToString(),'yyyyMMdd',$null)
    $sundaydate = [datetime]::ParseExact(($historyresults[2].LastRunDate).ToString(),'yyyyMMdd',$null)
    $backupdate = [datetime]::ParseExact(($historyresults[3].LastRunDate).ToString(),'yyyyMMdd',$null)
    $dbwarns = New-Object -TypeName psobject
    if ((((get-date) - $sundaydate) -gt $time_tolerance) -and (((get-date) - $saturdaydate) -gt $time_tolerance) -and (((get-date) - $weekdaydate) -gt $time_tolerance)) {
        $dbwarns | Add-Member -MemberType NoteProperty -Name MainLastRunWarning -Value $true
    }
    if (((get-date) - $backupdate) -gt $time_tolerance) {
        $dbwarns | Add-Member -MemberType NoteProperty -Name BackupLastRunWarning -Value $true
    }
    $enabledwarnings = @()
    $historyresults | ForEach-Object {
        if ($_.Enabled -ne 1 ) {
            $enabledwarnings += $_.JobName
        }
    }
    if ($enabledwarnings.Count -gt 0) { 
        $dbwarns | Add-Member -MemberType NoteProperty -Name EnabledWarning -Value $enabledwarnings
    }
    Write-Log -loglevel 1 -logdetail "[INFO] Consolidation complete"
    Return $dbwarns          
}

Function Write-DBWarnings ($dbhistory, $dbwarns) {    
    Write-Log -loglevel 1 -logdetail "[INFO] Outputing warnings"
    Write-Output "Warnings are present for database health"
    Write-Output " "
    if ($dbwarns.MainLastRunWarning -eq $true) {
        Write-Output "Maintenance Jobs have not run in the last 24 hours."
        Write-Output " "
        $dbhistory | Format-Table -Property JobName, LastRunDate
        $dbhistory | ForEach-Object {
            Write-Log -loglevel 3 -logdetail "***WARNING*** A maintenance job has not run in the last 24 hours. Job name: $($_.JobName)  Last Run: $($_.LastRunDate)"
        }
    }
    if ($dbwarns.BackupLastRunWarning -eq $true) {
        Write-Output "Backup Jobs have not run in the last 24 hours."
        Write-Output " "
        $dbhistory | Select-Object -Last 1 | Format-Table -Property JobName, LastRunDate
        $dbhistory | Select-Object -Last 1 | ForEach-Object {
            Write-Log -loglevel 3 -logdetail "***WARNING*** A backup job has not run in the last 24 hours. Job name: $($_.JobName)  Last Run: $($_.LastRunDate)" 
        }   
    }
    if ($dbwarns.EnabledWarning -ne $null) {
        Write-Output "One or more maintenance job is not enabled"
        Write-Output " "
        $dbhistory | Format-Table -Property JobName, Enabled
        $dbhistory | ForEach-Object {
            Write-Log -loglevel 3 -logdetail "***WARNING*** A maintenance job is not enabled. Job name: $($_.JobName)  Enabled Status: $($_.Enabled)"
        }
    }
}

Function Write-DBReport ($dbhistory, $dbpartition) {
    Write-Log -loglevel 1 -logdetail "[INFO] Outputing DB report"
    Write-Output "Database Maintenance Job Status:"
    Write-Output $dbhistory | Format-Table
    ForEach ($d in $dbhistory) {
        Write-Log -loglevel 2 -logdetail "DB Maintenance Status for job $($d.JobName) - Enabled: $($d.Enabled)  Last Run Date: $($d.LastRuneDate)  Total Run Time: $($d.TotalRunTime)  Run Status: $($d.RunStatus)"
    }
    Write-Output "EventsDB Partition Statistics:"
    Write-Output " "
    Write-Output "Max Partition Size: $($($dbpartition | Measure-Object -Maximum PartitionRow).Maximum)"
    Write-Output "Average Partition Size: $($($dbpartition | Measure-Object -Average PartitionRow).Average)"
    ForEach ($row in $dbpartition) {
        if ($row.PartitionDate.Date -eq (Get-Date).Date) { 
            Write-Output "Current Partition Size: $($row.PartitionRow)"
            Write-Log -loglevel 2 -logdetail "EventsDB Partition Statistics - Max Partition Size: $($($dbpartition | Measure-Object -Maximum PartitionRow).Maximum)  Average Partition Size: $($($dbpartition | Measure-Object -Average PartitionRow).Average)  Current Partition Size: $($row.PartitionRow)"
        }
    }
    Write-Log -loglevel 1 -logdetail "[INFO] Output complete"
}

Function Write-Hosts($hoststatus,$clusterstatus,$dbstatus,$eventstatus) {
    Write-Log -loglevel 1 -logdetail "[INFO] Outputing host status"
    Write-Output "Health check for $(Get-Date)"
    $hoststatus | ForEach-Object {
        Write-Output "Hostname:",$_.Hostname
        Write-Output $_.Drives | Format-Table -AutoSize
        Write-Output $_.Services | Format-Table -AutoSize
        ForEach ($d in $_.Drives) {
            Write-Log -loglevel 2 -logdetail "Disk statistics - Host: $($_.Hostname)  Drive: $($d.DriveLabel)  Total Space: $($d.DriveCapacityGB)GB  Free Space: $($d.DriveFreeGB)GB  Percentage Free: $($d.DrivePercentFree * 100)"
        }
        ForEach ($s in $_.Services) {
            Write-Log -loglevel 2 -logdetail "Service Status for host $($_.Hostname) - Service Name: $($s.ServiceName)  Service Status: $($s.ServiceStatus)"
        }
        if ($_.PSobject.Properties.Name -contains "DXRPCount") {
            Write-Output "DX Reliable Persist File Count:  ",$_.DXRPCount
            Write-Output " "
            Write-Log -loglevel 2 -logdetail "DX Reliable Persist File Count for host $($_.Hostname) - $($_.DXRPCount)"
        }
        if ($_.PSobject.Properties.Name -contains "SpooledEventsCount") {
            Write-Output "Spooled Events File Count:  ",$_.SpooledEventsCount
            Write-Output " "
            Write-Log -loglevel 2 -logdetail "Spooled Events File Count for host $($_.Hostname) - $($_.SpooledEventsCount)"
        }
        if ($_.PSobject.Properties.Name -contains "AIEDataCount") {
            Write-Output "AIE Data File Count:  ",$_.AIEDataCount
            Write-Output " "
            Write-Log -loglevel 2 -logdetail "AIE Data Folder File Count for host $($_.Hostname) - $($_.AIEDataCount)"
        }
    }
    Write-Output "Indexer Clusters:"
    Write-Output $clusterstatus | Format-Table -AutoSize
    ForEach ($c in $clusterstatus) {
        Write-Log -loglevel 2 -logdetail "Cluster status for $($c.Cluster) - Nodes: $($c.Nodes)  Status: $($c.Status)  Active Percent: $($c.ActivePercent)  Active Indices: $($c.ActiveIdices)"
    }
    if ($NoSQL.IsPresent -eq $false) {
        Write-DBReport $dbstatus $eventstatus
    }   
    Write-Log -loglevel 1 -logdetail "[INFO] Output complete"     
}

Function Get-Warnings($hoststatus) {
    $hostwarnings = @()
    $hoststatus | ForEach-Object {
        $lowdrives = @()
        $servicewarnings = @()
        $dxrpwarnings = @()
        $aiewarnings = @()
        $spooledeventswarnings = @()
        $_.Drives | ForEach-Object {
            if ($_.DrivePercentFree -lt $drivewarning) {
                $lowdrives += $_
            }
        }
        $_.Services | ForEach-Object {
            if ($_.ServiceStatus -ne "Running") {
                $servicewarnings += $_
            }
        }
        if ($_.DXRPCount -gt $dxrpwarning) {
            $dxrpwarnings += $_.DXRPCount
        }
        if ($_.AIEDataCount -gt $aiedatawarning) {
            $aiewarnings += $_.AIEDataCount
        }
        if ($_.SpooledEventsCount -gt $spooledeventswarning) {
            $spooledeventswarnings += $_.SpooledEventsCount
        }
        if (($lowdrives.Count -gt 0) -or ($servicewarnings.Count -gt 0) -or ($dxrpwarnings.Count -gt 0) -or ($aiewarnings.Count -gt 0)) {
            $warnhost = New-Object -TypeName psobject
            $warnhost | Add-Member -MemberType NoteProperty -Name Hostname -Value $_.hostname
            if ($lowdrives.Count -gt 0) { $warnhost | Add-Member -MemberType NoteProperty -Name Drives -Value $lowdrives }
            if ($servicewarnings.Count -gt 0) { $warnhost | Add-Member -MemberType NoteProperty -Name Services -Value $servicewarnings }
            if ($dxrpwarnings.Count -gt 0) { $warnhost | Add-Member -MemberType NoteProperty -Name DXReliablePersist -Value $dxrpwarnings }
            if ($aiewarnings.Count -gt 0) { $warnhost | Add-Member -MemberType NoteProperty -Name AIEData -Value $aiewarnings }
            if ($spooledeventswarnings.Count -gt 0) { $warnhost | Add-Member -MemberType NoteProperty -Name SpooledEvents -Value $spooledeventswarnings }
            $hostwarnings += $warnhost
        }
    }
    $hostwarnings        
}

Function Get-ClusterWarnings($clusterstatus) {
    Write-Log -loglevel 1 -logdetail "[INFO] Checking for cluster warnings"
    $clusterwarns = @()
    $clusterstatus | ForEach-Object {
        $statuswarnings = @()
        $nodeswarnings = @()
        $shardswarnings = @()
        $indiceswarnings = @()
        $warncluster = $false
        if ($_.Nodes -lt ($hosts.clusters | where clustername -eq $_.Cluster).numberofnodes) { $nodeswarnings += $_.Nodes }
        if ($_.ActiveIndices -lt ($hosts.clusters | where clustername -eq $_.Cluster).retention_target) { $indiceswarnings += $_.ActiveIndices }
        if ($_.Status -ne "green") { $statuswarnings += $_.Status }
        if ($_.ActivePercent -lt 100) { $shardswarnings += $_.ActivePercent }
        if (($statuswarnings.Count -gt 0) -or ($nodeswarnings.Count -gt 0) -or ($shardswarnings.Count -gt 0) -or ($indiceswarnings.Count -gt 0)) {
            $warncluster = New-Object -TypeName psobject
            $warncluster | Add-Member -MemberType NoteProperty -Name Cluster -Value $_.Cluster
            if ($statuswarnings.Count -gt 0) { $warncluster | Add-Member -MemberType NoteProperty -Name Status -Value $statuswarnings }
            if ($nodeswarnings.Count -gt 0) { $warncluster | Add-Member -MemberType NoteProperty -Name Nodes -Value $nodeswarnings }
            if ($shardswarnings.Count -gt 0) { $warncluster | Add-Member -MemberType NoteProperty -Name ActiveShards -Value $shardsswarnings }
            if ($indiceswarnings.Count -gt 0) { $warncluster | Add-Member -MemberType NoteProperty -Name ActiveIndices -Value $indiceswarnings }
        }
        if ($warncluster -ne $false) { $clusterwarns += $warncluster }
    }
    Write-Log -loglevel 1 -logdetail "[INFO] Check complete"
    $clusterwarns
}

Function Write-Warnings($hostwarnings, $clusterwarnings, $dbwarns, $ev) {
    Write-Log -loglevel 1 -logdetail "[INFO] Outputing host warnings"
    if (($hostwarnings.Count -eq 0) -and ($clusterwarnings.Count -eq 0) -and ($dbwarns | Get-Member -MemberType NoteProperty ).Count -eq 0)  { break }
    Write-Output "Health check for $(Get-Date)"
    if ($hostwarnings.Count -ne 0) {
        Write-Output "Warnings are present for the following hosts:" 
        Write-Output " "
        $hostwarnings | ForEach-Object {
            Write-Output $_.Hostname
            Write-Output ("-" * $_.Hostname.length)
            Write-Output " "
            if ($_.Drives.Count -gt 0) {
                Write-Output "Free space on one or more drives is below the threshold:"
                Write-Output $_.Drives | Format-Table -AutoSize
                Write-Output " "
                ForEach ($d in $_.Drives) {
                    Write-Log -loglevel 3 -logdetail "***WARNING*** Drive space is below threshold - Host: $($_.Hostname) Drive: $($d.DriveLabel)  Drive Capacity: $($d.DriveCapacityGB)GB  Free Space: $($d.DriveFreeGB)GB  Percentage Free: $($d.DrivePercentFree * 100)%"
                } 
            }
            if ($_.Services.Count -gt 0) {
                Write-Output "One or more monitored services is not in a running state:"
                Write-Output $_.Services | Format-Table -AutoSize
                Write-Output " "
                ForEach ($s in $_.Services) {
                    Write-Log -loglevel 3 -logdetail "***WARNING*** Service is not running - Host: $($_.Hostname)  Service: $($s.ServiceName)  Service Status: $($s.ServiceStatus)"
                }
            }
            if ($_.DXReliablePersist.Count -gt 0) {
                Write-Output "File count in the DXReliablePersist folder is above the threshold:"
                Write-Output $_.DXReliablePersist
                Write-Output " "
                Write-Log -loglevel 3 -logdetail "***WARNING*** File count in DX Reliable Persist folder is above the threshold - Host: $($_.Hostname)  DXRP File Count: $($_.DXReliablePersist)"
            }
            if ($_.AIEData.Count -gt 0) { 
                Write-Output "File count in the AIE data folder is above the threshold:"
                Write-Output $_.AIEData
                Write-Output " "
                Write-Log -loglevel 3 -logdetail "***WARNING*** File count in AIE Data folder is above the threshold - Host: $($_.Hostname)  Data Folder File Count: $($_.AIEData)"            
            }
            if ($_.SpooledEvents.Count -gt 0) { 
                Write-Output "File count in the Spooled Events folder is above the threshold:"
                Write-Output $_.SpooledEvents
                Write-Output " "
                Write-Log -loglevel 3 -logdetail "***WARNING*** File count in Spooled Events folder is above the threshold - Host: $($_.Hostname)  Data Folder File Count: $($_.SpooledEvents)"
            }
        }
    }
    if ($clusterwarnings.Count -ne 0) {
        Write-Output "Warnings are present for the following clusters:"
        Write-Output " "
        $clusterwarnings | ForEach-Object {
            Write-Output $_.Cluster
            Write-Output ("-" * $_.Cluster.length)
            Write-Output " "
            if ($_.Status.Count -gt 0) {
                Write-Output  "The status of the cluster is not green.  Current status: $($_.Status)"
                Write-Output " "
                Write-Log -loglevel 3 -logdetail "***WARNING*** The status of the cluster is not green - Cluster: $($_.Cluster)  Status: $($_.Status)"
            }
            if ($_.Nodes.Count -gt 0) {
                Write-Output "The number of active nodes is less than total nodes for this cluster"
                Write-Output "Active Nodes: $($_.Nodes)"
                Write-Output "Total Nodes: $( ($hosts.clusters | where clustername -eq $_.Cluster).numberofnodes )"
                Write-Output " "
                Write-Log -loglevel 3 -logdetail "***WARNING*** The number of active nodes is less than total nodes for this cluster - Cluster: $($_.Cluster)  Active Nodes: $($_.Nodes)  Total Nodes: $( ($hosts.clusters | where clustername -eq $_.Cluster).numberofnodes )"
            }
            if ($_.Shards.Count -gt 0) {
                Write-Output "The percent of active shards is below 100%"
                Write-Output "Current Percent: $($_.Shards)"
                Write-Output " "
                Write-Log -loglevel 3 -logdetail "***WARNING*** The percent of active shards is below 100% - Cluster: $($_.Cluster)  Current Percent: $($_.Shards)"
            }
            if ($_.ActiveIndices.Count -gt 0) {
                Write-Output "The number of active indices is below the retention target:"
                Write-Output "Retention Target: $( ($hosts.clusters | where clustername -eq $_.Cluster).retention_target )"
                Write-Output "Current Active Indices: $($_.ActiveIndices)"
                Write-Output " "
                Write-Log -loglevel 3 -logdetail "***WARNING*** The number of active indices is below the retention target - Cluster: $($_.Cluster)  Retention Target: $( ($hosts.clusters | where clustername -eq $_.Cluster).retention_target )  Active Indices: $($_.ActiveIndices)"
            }
        }
    }
    if (($NoSQL.IsPresent -eq $false) -and ($dbwarns | Get-Member -MemberType NoteProperty).Count -gt 0)  {
        Write-DBWarnings $ev $dbwarns
    }
}    

Function Email-Warnings($hostwarnings,$clusterwarnings,$db,$ev) {
    Write-Log -loglevel 2 -logdetail "Emailing warnings to $($mailrecipients)"
    $msgbody = Write-Warnings $hostwarnings $clusterwarnings $db $ev | Out-String
    Try {
        Send-MailMessage -SmtpServer $smtpserver -From $mailfrom -To $mailrecipients -Subject $warningsubject -Body $msgbody
    }
    Catch {
        Write-Log -loglevel 3 -logdetail "***ERROR*** An error occured emailing warnings: $_"
    }
}

Function Email-Report($hoststatus,$clusterstatus,$db,$ev) {
    Write-Log -loglevel 2 -logdetail "Emailing report to $($mailrecipients)"
    $msgbody = Write-Hosts $hoststatus $clusterstatus $db $ev | Out-String
    Try {
        Send-MailMessage -SmtpServer $smtpserver -From $mailfrom -To $mailrecipients -Subject $reportsubject -Body $msgbody
    }
    Catch {
        Write-Log -loglevel 3 -logdetail "***ERROR*** An error occured emailing report: $_"
    }
}

if ($NoSQL.IsPresent -eq $false) {
    Write-Log -loglevel 2 -logdetail "Initiating health check with SQL check enabled"
    $dbresults, $events = Get-DBJobHistory
    $dbwarnings = Get-DBJobWarnings $dbresults
}
else {
    Write-Log -loglevel 2 -logdetail "Initiating health check without SQL check enabled"
}

$allhoststatus = Get-HostsData $hosts
$allclusterstatus = Get-ClustersStatus $hosts
$warns = Get-Warnings $allhoststatus
$clusterwarnings = Get-ClusterWarnings $allclusterstatus

if ($EmailWarnings.IsPresent) { Email-Warnings $warns $clusterwarnings $dbwarnings $dbresults }
if ($EmailReport.IsPresent) { Email-Report $allhoststatus $allclusterstatus $dbresults $events }
if ($OutputReport.IsPresent) { Write-Hosts $allhoststatus $allclusterstatus $dbresults $events }
if ($OutputWarnings.IsPresent) { Write-Warnings $warns $clusterwarnings $dbwarnings $dbresults }