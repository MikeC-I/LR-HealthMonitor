# LR-HealthMonitor

Powershell script to monitor and report on health indicators for LogRhythm Windows servers (and DX clusters) including disk space, services status and log backlog

## Getting Started

Copy LR-HealthMonitor.ps1 and hosts.json into C:\LogRhythm\Scripts\LR-HealthMonitor\ (this is necessary as path to hosts.json is hard coded).

### Prerequisites

Powershell and an account the RPC rights to the hosts to be monitored

### Installing

Copy LR-HealthMonitor.ps1 and hosts.json into C:\LogRhythm\Scripts\LR-HealthMonitor\ (this is necessary as path to hosts.json is hard coded).

Options are:

-OutputReport

  Gathers data from hosts defined in hosts.json and outputs results to stdout
  
-OutputWarnins

  Gathers data from hosts defined in hosts.json and outputs any warnings found (per thresholds defined in hosts.json) and outputs results to stdout
  
-EmailReport

  Gathers data from hosts defined in hosts.json and emails results to recipients defined in hosts.json
  
-EmailReport

  Gathers data from hosts defined in hosts.json and emails any warnings found (per thresholds defined in hosts.json) to recipients defined in hosts.json
  

## Deployment

This script is designed to be run both on-demand and as a scheduled task.

For scheduled task, action should be 'Start a program'

  -Program/script: Powershell.exe
  
  -Arguments: 
  
    -Noninteractive -ExecutionPolicy Bypass -Command "C:\LogRhythm\Scripts\LR-HealthMonitor\LR-HealthMonitor.ps1 -EmailReport"
    
    -Noninteractive -ExecutionPolicy Bypass -Command "C:\LogRhythm\Scripts\LR-HealthMonitor\LR-HealthMonitor.ps1 -EmailWarnings"
    

## Authors

* **Mike Contasti-Isaac** - [GitHub](https://github.com/MikeC-I)

## License

This script isn't really licensed, and also USE AT YOUR OWN RISK, the author is not responsible for any loss or damage that may occur to relevant systems as a result of usin this script.

## Acknowledgments

* You know, Secure Sense who's on-the-clock time I spent developing this
