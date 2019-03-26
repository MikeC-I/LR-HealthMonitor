########################################################################################################################
##                                                                                                                    ##
##                             Welcome to the best health monitoring script in the world                              ##
##                                                                                                                    ##
##                                                                                                                    ##
##                                   WHERE ALL YOUR MONITORING DREAMS COME TRUE!!!!                                   ##
##                                                                                                                    ##
##                                                                                                                    ##
##                                          (c) 2019 Mike Contasti-Isaac                                              ##
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

[CmdletBinding()]
param([switch]$EmailWarnings, [switch]$EmailReport, [switch]$OutputReport, [switch]$OutputWarnings)

$file = "C:\LogRhythm\Scripts\LR-HealthMonitor\hosts.json"
$hosts = Get-Content -Raw $file | ConvertFrom-Json
$drivewarning = $hosts.config.drivewarning # Percentage of drive free under which a warning is issued
$dxrpwarning = $hosts.config.DXRPWarning # Number of files in DXReliablePersist folder above which a warning is issued
$aiedatawarning = $hosts.config.AIEWarning # Number of files in AIE Data folder above which a warning is issued
$smtpserver = $hosts.config.smtpserver
$mailfrom = $hosts.config.mailfrom
$mailrecipients = @($hosts.config.recipients)
$reportsubject = $hosts.config.reportsubject
$warningsubject = $hosts.config.warningsubject

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
        $dxstatus
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
        $cluster = Get-ClusterInfo $_.clusteraddress
        $thisCluster | Add-Member -MemberType NoteProperty -Name Cluster -Value $_.clustername
        $thisCluster | Add-Member -MemberType NoteProperty -Name Nodes -Value $cluster.number_of_nodes 
        $thisCluster | Add-Member -MemberType NoteProperty -Name Status -Value $cluster.status
        $thisCluster | Add-Member -MemberType NoteProperty -Name ActivePercent -Value $cluster.active_shards_percent_as_number
        $clusterstatus += $thisCluster
    }
    $clusterstatus
}

Function Write-Hosts($hoststatus,$clusterstatus) {
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
        $warncluster = $false
        if ($_.Nodes -lt ($hosts.clusters | where clustername -eq $_.Cluster).numberofnodes) { $nodeswarnings += $_.Nodes }
        if ($_.Status -ne "green") { $statuswarnings += $_.Status }
        if ($_.ActivePercent -lt 100) { $shardswarnings += $_.ActivePercent }
        if (($statuswarnings.Count -gt 0) -or ($nodeswarnings.Count -gt 0) -or ($shardswarnings.Count -gt 0)) {
            $warncluster = New-Object -TypeName psobject
            $warncluster | Add-Member -MemberType NoteProperty -Name Cluster -Value $_.Cluster
            if ($statuswarnings.Count -gt 0) { $warncluster | Add-Member -MemberType NoteProperty -Name Status -Value $statuswarnings }
            if ($nodeswarnings.Count -gt 0) { $warncluster | Add-Member -MemberType NoteProperty -Name Nodes -Value $nodeswarnings }
            if ($shardswarnings.Count -gt 0) { $warncluster | Add-Member -MemberType NoteProperty -Name ActiveShards -Value $shardsswarnings }
        }
        if ($warncluster -ne $false) { $clusterwarns += $warncluster }
    }
    $clusterwarns
}

Function Write-Warnings($hostwarnings, $clusterwarnings) {
    if (($hostwarnings.Count -eq 0) -and ($clusterwarnings.Count -eq 0)) { break }
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
        }
    }
}
    

Function Email-Warnings($hostwarnings,$clusterwarnings) {
    $msgbody = Write-Warnings $hostwarnings $clusterwarnings | Out-String
    Send-MailMessage -SmtpServer $smtpserver -From $mailfrom -To $mailrecipients -Subject $warningsubject -Body $msgbody
}

Function Email-Report($hoststatus,$clusterstatus) {
    $msgbody = Write-Hosts $hoststatus $clusterstatus | Out-String
    Send-MailMessage -SmtpServer $smtpserver -From $mailfrom -To $mailrecipients -Subject $reportsubject -Body $msgbody
}

$allhoststatus = Get-HostsData $hosts
$allclusterstatus = Get-ClustersStatus $hosts
$warns = Get-Warnings $allhoststatus
$clusterwarnings = Get-ClusterWarnings $allclusterstatus

if ($EmailWarnings.IsPresent) { Email-Warnings $warns $clusterwarnings }
if ($EmailReport.IsPresent) { Email-Report $allhoststatus $allclusterstatus }
if ($OutputReport.IsPresent) { Write-Hosts $allhoststatus $allclusterstatus }
if ($OutputWarnings.IsPresent) { Write-Warnings $warns $clusterwarnings }