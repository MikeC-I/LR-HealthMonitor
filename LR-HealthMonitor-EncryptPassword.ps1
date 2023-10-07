<#
.SYNOPSIS
    LR-HealthMonitor-EncryptPassword.ps1 is a utility script to encrypt the password for the sa account for secure storage.
    This script MUST be run using the same user account that will run LR-HealthMonitor.ps1
.DESCRIPTION
.NOTES
    This version created by Mike Contasti-Isaac, September 2020
.PARAMETER HostsFile
    Explicit or relative path the the hosts.json file.  Defaults to C:\LogRhythm\Scripts\LR-HealthMonitor\hosts.json
.PARAMETER EmailReport
    Emails a report of all metrics
.PARAMETER OutputWarnings
    Outputs any warnings based on configurable thresholds
.NOTES
    Change Log:
        2023/10/07 - Created
 #>

[CmdletBinding()]
param(
    [string]$HostsFile = "C:\LogRhythm\Scripts\LR-HealthMonitor\hosts.json"
)

Function Confirm-User {
    Write-Host "***** IMPORTANT! This script must be run as the same user that will run the LR-HealthMonitor.ps1 script *****"
    Write-Host ""
    $usercorrect = Read-Host "Current user is $($Env:UserName), is this correct? [Y/N]"
    Return $usercorrect.ToLower()
}

$confirmed = $false

While ($confirmed -eq $false) {
    $correct = Confirm-User
    Switch ($correct) {
        "n" { 
            Write-Host "Please re-run this script using the correct user.  Goodbye!"
            Exit
        }
        "y" {
            Write-Host "Thank you!"
            $confirmed = $true
        }
        default {
            Write-Host "Please input either 'y' for yes or 'n' for no"
        }
    }
}


$credential = Get-Credential -UserName "sa" -Message "Please enter the password for the SQL Server 'sa' account"
$securepassword = $credential.Password | ConvertFrom-SecureString

Try {
    $json = Get-Content $HostsFile | ConvertFrom-Json
}
Catch {
    Write-Error "Could not read content from hosts file $($HostsFile).  Exiting"
    Exit
}

$json.database.password = $securepassword

Try {
    $json | ConvertTo-Json -Depth 20 | Set-Content $HostsFile    
}
Catch {
    Write-Error "Could not write content to hosts file $($HostsFile).  Exiting"
    Exit
}

Write-Host "Encrypted Password successfully stored to $HostsFile"