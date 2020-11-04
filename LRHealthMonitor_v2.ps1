########################################################################################################################
##                                                                                                                    ##
##                       Welcome to the best health monitoring script in the world Version 2.0                        ##
##                                                                                                                    ##
##                                                                                                                    ##
##                                   WHERE ALL YOUR MONITORING DREAMS COME TRUE!!!!                                   ##
##                                                                                                                    ##
##                                                                                                                    ##
##                                          (c) 2020 Mike Contasti-Isaac                                              ##
##                                                                                                                    ##
##                                                                                                                    ##
##                                                    DISCLAIMER                                                      ##
##                                                                                                                    ##
##                                                                                                                    ##
##                        By using this script, you are assuming all risk and liability of damage                     ##
##                                      that this may cause on relevant systems                                       ##
##                                                                                                                    ##
##                                                                                                                    ##
##                                                                                                                    ##
########################################################################################################################

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
 #>

[CmdletBinding()]
param([switch]$EmailWarnings, [switch]$EmailReport, [switch]$OutputReport, [switch]$OutputWarnings, [switch]$NoSQL)

$file = "C:\LogRhythm\Scripts\LR-HealthMonitor\hosts_v2.json"
$hosts = Get-Content -Raw $file | ConvertFrom-Json
$drivewarning = $hosts.config.drivewarning # Percentage of drive free under which a warning is issued
$dxrpwarning = $hosts.config.DXRPWarning # Number of files in DXReliablePersist folder above which a warning is issued
$aiedatawarning = $hosts.config.AIEWarning # Number of files in AIE Data folder above which a warning is issued
$smtpserver = $hosts.config.smtpserver
$mailfrom = $hosts.config.mailfrom
$mailrecipients = @($hosts.config.recipients)
$reportsubject = $hosts.config.reportsubject
$warningsubject = $hosts.config.warningsubject
$sqlserver = $hosts.database.server
$sqluser = $hosts.database.user
$sqlpassword = $hosts.database.password
#$sqlcredential = New-Object System.Management.Automation.PsCredential($sqluser, $sqlpassword)

Function Get-DriveStatus([String]$hostname, [String]$driveletter) {
    Try {
        $thisdisk = Get-WmiObject win32_logicaldisk -ComputerName $hostname -Filter "DeviceID='$driveletter'"
        [math]::truncate($thisdisk.Size / 1GB)
        [math]::truncate($thisdisk.FreeSpace / 1GB)
        $percent = [math]::round(($thisdisk.FreeSpace / $thisdisk.Size),2)
        $percent
    }
    Catch {
        "Error retrieving drive statistics"
    }
}

Function Get-ServerServices([String]$hostname) {
    Try {
        $serverservices = Get-WmiObject Win32_service -Computer $hostname
        $serverservices
    }
    Catch {
        "Error retrieving server services"
    }
}

Function Get-DirFileCount($hostname, $directory) {
    Try {
        $directory = $directory -replace "\\","\\"
        $filecount = Get-WmiObject CIM_DataFile -ComputerName $hostname -filter "Drive='$($directory.SubString(0,2))' AND path='$($directory.SubString(2))'"
        $filecount.Count
    }
    Catch {
    "Error Reading Remote Directory"
    }
}

Function Get-ClusterInfo($hostname) {
    Try {
        $dxstatus = Invoke-RestMethod "http://$($hostname):9200/_cluster/health?level=indices&pretty"
        $dxindices = (Invoke-WebRequest -Uri "http://$($hostname):9200/_cat/indices").Content | FindStr "logs-"  | Measure-Object -Line
        Return $dxstatus, $dxindices
    }
    Catch {
        "Error retreiving cluster statistics"
    }
}
    

Function Get-HostsData($hostjson) {
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
            $thishost | Add-Member -MemberType NoteProperty -Name DXRPCount -Value $DXRPCount
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
    $hoststatus
}

Function Get-ClustersStatus($hostjson) {
    $clusterstatus = @()
    $hostjson.clusters | ForEach-Object {
        $thisCluster = New-Object -TypeName psobject
        $cluster, $clusterindices = Get-ClusterInfo $_.clusteraddress
        $thisCluster | Add-Member -MemberType NoteProperty -Name Cluster -Value $_.clustername
        $thisCluster | Add-Member -MemberType NoteProperty -Name Nodes -Value $cluster.number_of_nodes 
        $thisCluster | Add-Member -MemberType NoteProperty -Name Status -Value $cluster.status
        $thisCluster | Add-Member -MemberType NoteProperty -Name ActivePercent -Value $cluster.active_shards_percent_as_number
        $thisCluster | Add-Member -MemberType NoteProperty -Name ActiveIndices -Value $clusterindices.Lines
        <# DEBUG CODE #>
        # Write-Host "Cluster $($_.clustername) Active Indices: $($thisCluster.ActiveIndi"

        $clusterstatus += $thisCluster
    }
    $clusterstatus
}

Function Get-DBJobHistory {
    $query_Sunday = "SELECT TOP 1 j.name as 'JobName', MIN(j.enabled) AS 'Enabled', run_date AS 'LastRunDate', SUM(run_time) AS 'TotalTime', MIN(run_status) AS 'Status' FROM msdb.dbo.sysjobs j INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id WHERE j.enabled = 1  AND j.name = 'LogRhythm Sunday Maintenance' GROUP BY j.name, run_date ORDER BY run_date DESC"
    $query_Saturday = "SELECT TOP 1 j.name as 'JobName', MIN(j.enabled) AS 'Enabled', run_date AS 'LastRunDate', SUM(run_time) AS 'TotalTime', MIN(run_status) AS 'Status' FROM msdb.dbo.sysjobs j INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id WHERE j.enabled = 1  AND j.name = 'LogRhythm Saturday Maintenance' GROUP BY j.name, run_date ORDER BY run_date DESC"
    $query_Weekday = "SELECT TOP 1 j.name as 'JobName', MIN(j.enabled) AS 'Enabled', run_date AS 'LastRunDate', SUM(run_time) AS 'TotalTime', MIN(run_status) AS 'Status' FROM msdb.dbo.sysjobs j INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id WHERE j.enabled = 1  AND j.name = 'LogRhythm Weekday Maintenance' GROUP BY j.name, run_date ORDER BY run_date DESC"
    $query_Backup = "SELECT TOP 1 j.name as 'JobName', MIN(j.enabled) AS 'Enabled', run_date AS 'LastRunDate', SUM(run_time) AS 'TotalTime', MIN(run_status) AS 'Status' FROM msdb.dbo.sysjobs j INNER JOIN msdb.dbo.sysjobhistory h ON j.job_id = h.job_id WHERE j.enabled = 1  AND j.name = 'LogRhythm Backup' GROUP BY j.name, run_date ORDER BY run_date DESC"
    $query_partitions = "EXEC LogRhythm_Events.dbo.LogRhythm_Events_Partitions_Query"
    $c_String = "Data Source=$sqlserver;Initial Catalog=msdb;User ID=$sqluser;Password=$sqlpassword;ApplicationIntent=ReadOnly"

    $history_weekday = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_Weekday
    $history_sunday = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_Sunday
    $history_saturday = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_Saturday
    $history_backup = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_Backup
    $events_partitions_data = Invoke-Sqlcmd -ConnectionString $c_String -Query $query_partitions

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
    Return $dbwarns          
}

Function Write-DBWarnings ($dbhistory, $dbwarns) {    
    Write-Output "Warnings are present for database health"
    Write-Output " "
    if ($dbwarns.MainLastRunWarning -eq $true) {
        Write-Output "Maintenance Jobs have not run in the last 24 hours."
        Write-Output " "
        $dbhistory | Format-Table -Property JobName, LastRunDate
    }
    if ($dbwarns.BackupLastRunWarning -eq $true) {
        Write-Output "Backup Jobs have not run in the last 24 hours."
        Write-Output " "
        $dbhistory | Select-Object -Last 1 | Format-Table -Property JobName, LastRunDate
    }
    if ($dbwarns.EnabledWarning -ne $null) {
        Write-Output "One or more maintenance job is not enabled"
        Write-Output " "
        $dbhistory | Format-Table -Property JobName, Enabled
    }
}

Function Write-DBReport ($dbhistory, $dbpartition) {
    Write-Output "Database Maintenance Job Status:"
    Write-Output $dbhistory | Format-Table
    Write-Output "EventsDB Partition Statistics:"
    Write-Output " "
    Write-Output "Max Partition Size: $($($dbpartition | Measure-Object -Maximum PartitionRow).Maximum)"
    Write-Output "Average Partition Size: $($($dbpartition | Measure-Object -Average PartitionRow).Average)"
    ForEach ($row in $dbpartition) {
        if ($row.PartitionDate.Date -eq (Get-Date).Date) { 
            Write-Output "Current Partition Size: $($row.PartitionRow)"
        }
    }
}

Function Write-Hosts($hoststatus,$clusterstatus,$dbstatus,$eventstatus) {
    $hoststatus | ForEach-Object {
        Write-Output "Hostname:",$_.Hostname
        Write-Output $_.Drives | Format-Table -AutoSize
        Write-Output $_.Services | Format-Table -AutoSize
        if ($_.PSobject.Properties.Name -contains "DXRPCount") {
            Write-Output "DX Reliable Persist File Count:  ",$_.DXRPCount
            Write-Output " "
        }
        if ($_.PSobject.Properties.Name -contains "AIEDataCount") {
            Write-Output "AIE Data File Count:  ",$_.AIEDataCount
            Write-Output " "
        }
    }
    Write-Output "Indexer Clusters:"
    Write-Output $clusterstatus | Format-Table -AutoSize
    if ($NoSQL.IsPresent -eq $false) {
        Write-DBReport $dbstatus $eventstatus
    }        
}

Function Get-Warnings($hoststatus) {
    $hostwarnings = @()
    $hoststatus | ForEach-Object {
        $lowdrives = @()
        $servicewarnings = @()
        $dxrpwarnings = @()
        $aiewarnings = @()
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
        if (($lowdrives.Count -gt 0) -or ($servicewarnings.Count -gt 0) -or ($dxrpwarnings.Count -gt 0) -or ($aiewarnings.Count -gt 0)) {
            $warnhost = New-Object -TypeName psobject
            $warnhost | Add-Member -MemberType NoteProperty -Name Hostname -Value $_.hostname
            if ($lowdrives.Count -gt 0) { $warnhost | Add-Member -MemberType NoteProperty -Name Drives -Value $lowdrives }
            if ($servicewarnings.Count -gt 0) { $warnhost | Add-Member -MemberType NoteProperty -Name Services -Value $servicewarnings }
            if ($dxrpwarnings.Count -gt 0) { $warnhost | Add-Member -MemberType NoteProperty -Name DXReliablePersist -Value $dxrpwarnings }
            if ($aiewarnings.Count -gt 0) { $warnhost | Add-Member -MemberType NoteProperty -Name AIEData -Value $aiewarnings }
            $hostwarnings += $warnhost
        }
    }
    $hostwarnings        
}

Function Get-ClusterWarnings($clusterstatus) {
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
    $clusterwarns
}

Function Write-Warnings($hostwarnings, $clusterwarnings, $dbwarns, $ev) {
    if (($hostwarnings.Count -eq 0) -and ($clusterwarnings.Count -eq 0) -and ($dbwarns | Get-Member -MemberType NoteProperty ).Count -eq 0)  { break }
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
            }
            if ($_.Services.Count -gt 0) {
                Write-Output "One or more monitored services is not in a running state:"
                Write-Output $_.Services | Format-Table -AutoSize
                Write-Output " "
            }
            if ($_.DXReliablePersist.Count -gt 0) {
                Write-Output "File count in the DXReliablePersist folder is above the threshold:"
                Write-Output $_.DXReliablePersist
                Write-Output " "
            }
            if ($_.AIEData.Count -gt 0) { 
                Write-Output "File count in the AIE data folder is above the threshold:"
                Write-Output $_.AIEData
                Write-Output " "
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
            }
            if ($_.Nodes.Count -gt 0) {
                Write-Output "The number of active nodes is less than total nodes for this cluster"
                Write-Output "Active Nodes: $($_.Nodes)"
                Write-Output "Total Nodes: $( ($hosts.clusters | where clustername -eq $_.Cluster).numberofnodes )"
                Write-Output " "
            }
            if ($_.Shards.Count -gt 0) {
                Write-Output "The percent of active shards is below 100%"
                Write-Output "Current Percent: $($_.Shards)"
                Write-Output " "
            }
            if ($_.ActiveIndices.Count -gt 0) {
                Write-Output "The number of active indices is below the retention target:"
                Write-Output "Retention Target: $( ($hosts.clusters | where clustername -eq $_.Cluster).retention_target )"
                Write-Output "Current Active Indices: $($_.ActiveIndices)"
                Write-Output " "
            }
        }
    }
    if (($NoSQL.IsPresent -eq $false) -and ($dbwarns | Get-Member -MemberType NoteProperty).Count -gt 0)  {
        Write-DBWarnings $ev $dbwarns
    }
}    

Function Email-Warnings($hostwarnings,$clusterwarnings,$db,$ev) {
    $msgbody = Write-Warnings $hostwarnings $clusterwarnings $db $ev | Out-String
    Send-MailMessage -SmtpServer $smtpserver -From $mailfrom -To $mailrecipients -Subject $warningsubject -Body $msgbody
}

Function Email-Report($hoststatus,$clusterstatus,$db,$ev) {
    $msgbody = Write-Hosts $hoststatus $clusterstatus $db $ev | Out-String
    Send-MailMessage -SmtpServer $smtpserver -From $mailfrom -To $mailrecipients -Subject $reportsubject -Body $msgbody
}

if ($NoSQL.IsPresent -eq $false) {
    $dbresults, $events = Get-DBJobHistory
    $dbwarnings = Get-DBJobWarnings $dbresults
}

$allhoststatus = Get-HostsData $hosts
$allclusterstatus = Get-ClustersStatus $hosts
$warns = Get-Warnings $allhoststatus
$clusterwarnings = Get-ClusterWarnings $allclusterstatus

if ($EmailWarnings.IsPresent) { Email-Warnings $warns $clusterwarnings $dbwarnings $dbresults }
if ($EmailReport.IsPresent) { Email-Report $allhoststatus $allclusterstatus $dbresults $events }
if ($OutputReport.IsPresent) { Write-Hosts $allhoststatus $allclusterstatus $dbresults $events }
if ($OutputWarnings.IsPresent) { Write-Warnings $warns $clusterwarnings $dbwarnings $dbresults }