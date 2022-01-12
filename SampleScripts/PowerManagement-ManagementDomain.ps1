<#
    .NOTES
    ===============================================================================================================
    .Created By:    Gary Blake / Sowjanya V
    .Group:         Cloud Infrastructure Business Group (CIBG)
    .Organization:  VMware
    .Version:       1.0 (Build 001)
    .Date:          2021-11-08
    ===============================================================================================================

    .CHANGE_LOG

    - 1.0.001   (Gary Blake / 2021-11-03) - Initial script creation

    ===============================================================================================================

    .SYNOPSIS
    Connects to the specified SDDC Manager and shutdown/startup a Management Workload Domain

    .DESCRIPTION
    This script connects to the specified SDDC Manager and either shutdowns or startups a Management Workload Domain

    .EXAMPLE
    PowerManagement-WorkloadDomain.ps1 -server sfo-vcf01.sfo.rainpole.io -user administrator@vsphere.local -pass VMw@re1!  -powerState Shutdown
    Initiates a shutdown of the Management Workload Domain 'sfo-m01'

    .EXAMPLE
    PowerManagement-WorkloadDomain.ps1 -server sfo-vcf01.sfo.rainpole.io -user administrator@vsphere.local -pass VMw@re1!  -powerState Startup
    Initiates the startup of the Management Workload Domain 'sfo-m01'
#>

Param (
        [Parameter (Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$server,
        [Parameter (Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$user,
        [Parameter (Mandatory = $true)] [ValidateNotNullOrEmpty()] [String]$pass,
        [Parameter (Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$force,
        [Parameter (Mandatory = $false)] [ValidateNotNullOrEmpty()] [String]$json,
        [Parameter (Mandatory = $true)] [ValidateSet("Shutdown", "Startup")] [String]$powerState
)

Clear-Host; Write-Host ""

# Check that the FQDN of the SDDC Manager is valid

if ($powerState -eq "shutdown") {
   Try {
        if (!(Test-Connection -ComputerName $server -Count 1 -ErrorAction SilentlyContinue)) {
            Write-Error "Unable to communicate with SDDC Manager ($server), check fqdn/ip address"
            Break
        }
        else {
            $log = ""
            if (-Not $force) {
                 Write-Host "";
                 $proceed_force =  Read-Host "Would you like to gracefully shutdown Non-VCF Management Workloads (Yes/No)? [No]"
                 if ($proceed_force -match "yes") {
                    $force = $true
                    $log = "Process WILL gracefully shutdown all Non-VCF Management Virtual Machines running within the Management Domain"
                } else {
                    $force = $false
                    $log =  "Process WILL NOT gracefully shutdown all Non-VCF Management Virtual Machines running within the Management Domain"
                }

            }
            Write-Host "";
            $regionalWSAYesOrNo = Read-Host "Have you deployed a Standalone Workspace ONE Access instance (Yes/No)"
            if ($regionalWSAYesOrNo -eq "yes") {
                 $regionalWSA = Read-Host "Enter the Virtual Machine name for the Standalone Workspace ONE Access instance"
                 if(([string]::IsNullOrEmpty($regionalWSA))) {
                    Write-LogMessage -Type WARNING -Message "Regional WSA information is null, hence Exiting"   -Colour Magenta
                    Exit
                }
            }

            Write-Host "";
            $edgenodesList  = @()
            $edgenodesList = Read-Host "Kindly provide space separated list of NSX edge nodes fqdn"
            if(([string]::IsNullOrEmpty($edgenodesList))) {
                Write-LogMessage -Type WARNING -Message "Edge nodes fqdn info is null, hence Exiting"   -Colour Magenta
                Exit
            } else {
                $edgenodesList = $edgenodesList.split()
            }
            Write-LogMessage -Type INFO -Message $log
        }
   }
   Catch {
        Debug-CatchWriter -object $_
   }
} else {
    $file = "./ManagementStartupInput.json"
    if ($json) {
        Write-LogMessage -Type INFO -Message "User has provided the input json file" -Colour Green
        $inputFile = $json
    } elseif (Test-Path -Path $file -PathType Leaf) {
        Write-LogMessage -Type INFO -Message "No path to json provided on the command line so script is using for auto created input json file ManagementStartupInput.json" -Colour Magenta
        $inputFile =  $file
    } else {
        Write-LogMessage -Type INFO -Message "No Automatically Created Startup Input JSON File Found, Using Template Startup Input JSON File (template-managementDomainStartup.json) to Start the Management Domain" -Colour Magenta
        $inputFile =  "./template-managementDomainStartup.json"
    }

    Write-Host "";
    $proceed =  Read-Host "Did you check the file $inputFile for its correctness and shall we proceed"
    if ($proceed -match "no" -or (-not $proceed)) {
        Write-LogMessage -Type WARNING -Message "Exiting script execution as the input is No"   -Colour Magenta
        Exit
    }
    Write-LogMessage -Type INFO -Message "$inputFile is checked for its correctness, moving on with execution"
}

# Setup a log file and gather details from SDDC Manager

# Execute the Shutdown procedures
Try {
    if ($powerState -eq "Shutdown") {
        Start-SetupLogFile -Path $PSScriptRoot -ScriptName $MyInvocation.MyCommand.Name
        Write-LogMessage -Type INFO -Message "Setting up the log file to path $logfile"

        Write-LogMessage -Type INFO -Message "Attempting to connect to VMware Cloud Foundation to Gather System Details"
        $StatusMsg = Request-VCFToken -fqdn $server -username $user -password $pass -WarningAction SilentlyContinue -ErrorAction SilentlyContinue -WarningVariable WarnMsg -ErrorVariable ErrorMsg
        if ( $StatusMsg ) { Write-LogMessage -Type INFO -Message $StatusMsg } if ( $WarnMsg ) { Write-LogMessage -Type WARNING -Message $WarnMsg -Colour Magenta } if ( $ErrorMsg ) { Write-LogMessage -Type ERROR -Message $ErrorMsg -Colour Red }
        if ($accessToken) {
            Write-LogMessage -Type INFO -Message "Gathering System Details from SDDC Manager Inventory"
            $workloadDomain = Get-VCFWorkloadDomain | Where-Object {  $_.type -eq "MANAGEMENT" }
            $cluster = Get-VCFCluster | Where-Object { $_.id -eq ($workloadDomain.clusters.id) }

            $var = @{}
            $var["Domain"] = @{}
            $var["Domain"]["name"] = $workloadDomain.name
            $var["Domain"]["type"] = "MANAGEMENT"

            $var["Cluster"] = @{}
            $var["Cluster"]["name"] = $cluster.name

            # Gather vCenter Server Details and Credentials
            $vcServer = (Get-VCFvCenter | Where-Object { $_.domain.id -eq ($workloadDomain.id)})
            #$mgmtVcServer = (Get-VCFvCenter | Where-Object { $_.domain.id -eq ($managementDomain.id)})
            $vcUser = (Get-VCFCredential | Where-Object {$_.accountType -eq "SYSTEM" -and $_.credentialType -eq "SSO"}).username
            $vcPass = (Get-VCFCredential | Where-Object {$_.accountType -eq "SYSTEM" -and $_.credentialType -eq "SSO"}).password

            $var["Server"] = @{}
            $var["Server"]["name"] = $vcServer.fqdn.Split(".")[0]
            $var["Server"]["fqdn"] = $vcServer.fqdn
            $var["Server"]["user"] = $vcUser
            $var["Server"]["password"] = $vcPass


            # Gather ESXi Host Details for the Management Workload Domain
            $esxiWorkloadDomain = @()
            foreach ($esxiHost in (Get-VCFHost | Where-Object {$_.domain.id -eq $workloadDomain.id}).fqdn)
            {
                $esxDetails = New-Object -TypeName PSCustomObject
                $esxDetails | Add-Member -Type NoteProperty -Name name -Value $esxiHost.Split(".")[0]
                $esxDetails | Add-Member -Type NoteProperty -Name fqdn -Value $esxiHost
                $esxDetails | Add-Member -Type NoteProperty -Name username -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $esxiHost -and $_.accountType -eq "USER"})).username
                $esxDetails | Add-Member -Type NoteProperty -Name password -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $esxiHost -and $_.accountType -eq "USER"})).password
                $esxiWorkloadDomain += $esxDetails
            }

            $var["Hosts"] = @()
            $var["Hosts"] = $esxiWorkloadDomain

            # Gather NSX Manager Cluster Details
            $nsxtCluster = Get-VCFNsxtCluster -id $workloadDomain.nsxtCluster.id
            $nsxtMgrfqdn = $nsxtCluster.vipFqdn
            $nsxMgrVIP = New-Object -TypeName PSCustomObject
            $nsxMgrVIP | Add-Member -Type NoteProperty -Name adminUser -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $nsxtMgrfqdn -and $_.credentialType -eq "API"})).username
            $nsxMgrVIP | Add-Member -Type NoteProperty -Name adminPassword -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $nsxtMgrfqdn -and $_.credentialType -eq "API"})).password
            $nsxtNodesfqdn = $nsxtCluster.nodes.fqdn
            $nsxtNodes = @()
            foreach ($node in $nsxtNodesfqdn) {
                [Array]$nsxtNodes += $node.Split(".")[0]
            }
            $var["NsxtManager"] = @{}
            $var["NsxtManager"]["vipfqdn"] = $nsxtMgrfqdn
            $var["NsxtManager"]["nodes"] = $nsxtNodesfqdn
            $var["NsxtManager"]["user"] = $nsxMgrVIP.adminUser
            $var["NsxtManager"]["password"] = $nsxMgrVIP.adminPassword


            # Gather NSX Edge Node Details
            #$nsxtEdgeCluster = (Get-VCFEdgeCluster | Where-Object {$_.nsxtCluster.id -eq $workloadDomain.nsxtCluster.id})
            #$nsxtEdgeNodesfqdn = $nsxtEdgeCluster.edgeNodes.hostname
            $nsxtEdgeNodesfqdn = $edgenodesList
            $nsxtEdgeNodes = @()
            foreach ($node in $nsxtEdgeNodesfqdn) {
                [Array]$nsxtEdgeNodes += $node.Split(".")[0]
            }

            $var["NsxEdge"] = @{}
            $var["NsxEdge"]["edgenodes"] = @{}
            $var["NsxEdge"]["edgenodes"]["hostname"] = @()
            foreach ($val in $nsxtEdgeNodes) {
                 $var["NsxEdge"]["edgenodes"]["hostname"] += $val
            }

            # Gather vRealize Suite Details
            $vrslcm = New-Object -TypeName PSCustomObject
            $vrslcm | Add-Member -Type NoteProperty -Name status -Value (Get-VCFvRSLCM).status
            $vrslcm | Add-Member -Type NoteProperty -Name fqdn -Value (Get-VCFvRSLCM).fqdn
            $vrslcm | Add-Member -Type NoteProperty -Name adminUser -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $vrslcm.fqdn -and $_.credentialType -eq "API"})).username
            $vrslcm | Add-Member -Type NoteProperty -Name adminPassword -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $vrslcm.fqdn -and $_.credentialType -eq "API"})).password
            $vrslcm | Add-Member -Type NoteProperty -Name rootUser -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $vrslcm.fqdn -and $_.credentialType -eq "SSH"})).username
            $vrslcm | Add-Member -Type NoteProperty -Name rootPassword -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $vrslcm.fqdn -and $_.credentialType -eq "SSH"})).password

            $var["Vrslcm"] = @{}
            if ($vrslcm.fqdn) {
                $var["Vrslcm"]["name"] = $vrslcm.fqdn.Split(".")[0]
            } else {
                $var["Vrslcm"]["name"] = $null
            }
            $var["Vrslcm"]["fqdn"] = $vrslcm.fqdn
            $var["Vrslcm"]["status"] = $vrslcm.status
            $var["Vrslcm"]["adminUser"] = $vrslcm.adminUser
            $var["Vrslcm"]["adminPassword"] = $vrslcm.adminPassword
            $var["Vrslcm"]["rootUser"] = $vrslcm.rootUser
            $var["Vrslcm"]["rootPassword"] = $vrslcm.rootPassword

            $wsa = New-Object -TypeName PSCustomObject
            $wsa | Add-Member -Type NoteProperty -Name status -Value (Get-VCFWSA).status
            $wsa | Add-Member -Type NoteProperty -Name fqdn -Value (Get-VCFWSA).loadBalancerFqdn
            $wsa | Add-Member -Type NoteProperty -Name adminUser -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $wsa.fqdn -and $_.credentialType -eq "API"})).username
            $wsa | Add-Member -Type NoteProperty -Name adminPassword -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $wsa.fqdn -and $_.credentialType -eq "API"})).password
            $wsaNodes = @()
            foreach ($node in (Get-VCFWSA).nodes.fqdn | Sort-Object) {
                [Array]$wsaNodes += $node.Split(".")[0]
            }

            $var["Wsa"] = @{}
            if ($wsa.fqdn) {
                $var["Wsa"]["name"] = $wsa.fqdn.Split(".")[0]
            } else {
                $var["Wsa"]["name"] = $null
            }
            $var["Wsa"]["fqdn"] = $wsa.fqdn
            $var["Wsa"]["status"] = $wsa.status
            $var["Wsa"]["adminUser"] = $wsa.adminUser
            $var["Wsa"]["adminPassword"] = $wsa.adminPassword
            $var["Wsa"]["nodes"] = $wsaNodes


            $vrops = New-Object -TypeName PSCustomObject
            $vrops | Add-Member -Type NoteProperty -Name status -Value (Get-VCFvROPS).status
            $vrops | Add-Member -Type NoteProperty -Name fqdn -Value (Get-VCFvROPS).loadBalancerFqdn
            $vrops | Add-Member -Type NoteProperty -Name adminUser -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $vrops.fqdn -and $_.credentialType -eq "API"})).username
            $vrops | Add-Member -Type NoteProperty -Name adminPassword -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $vrops.fqdn -and $_.credentialType -eq "API"})).password
            $vrops | Add-Member -Type NoteProperty -Name master -Value  ((Get-VCFvROPs).nodes | Where-Object {$_.type -eq "MASTER"}).fqdn
            $vropsNodes = @()
            foreach ($node in (Get-VCFvROPS).nodes.fqdn | Sort-Object) {
                [Array]$vropsNodes += $node.Split(".")[0]
            }


            $var["Vrops"] = @{}
            if ($vrops.fqdn) {
                $var["Vrops"]["name"] = $vrops.fqdn.Split(".")[0]
            } else {
                $var["Vrops"]["name"] = $null
            }
            $var["Vrops"]["fqdn"] = $vrops.fqdn
            $var["Vrops"]["status"] = $vrops.status
            $var["Vrops"]["adminUser"] = $vrops.adminUser
            $var["Vrops"]["adminPassword"] = $vrops.adminPassword
            $var["Vrops"]["master"] = $vrops.master
            $var["Vrops"]["nodes"] = $vropsNodes

            $vra = New-Object -TypeName PSCustomObject
            $vra | Add-Member -Type NoteProperty -Name status -Value (Get-VCFvRA).status
            $vra | Add-Member -Type NoteProperty -Name fqdn -Value (Get-VCFvRA).loadBalancerFqdn
            $vraNodes = @()
            foreach ($node in (Get-VCFvRA).nodes.fqdn | Sort-Object) {
                [Array]$vraNodes += $node.Split(".")[0]
            }


            $var["Vra"] = @{}
            if ($vra.fqdn) {
                $var["Vra"]["name"] = $vra.fqdn.Split(".")[0]
            } else {
                $var["Vra"]["name"] = $null
            }
            $var["Vra"]["fqdn"] = $vra.fqdn
            $var["Vra"]["status"] = $vra.status
            $var["Vra"]["nodes"] = $vraNodes


            $vrli = New-Object -TypeName PSCustomObject
            $vrli | Add-Member -Type NoteProperty -Name status -Value (Get-VCFvRLI).status
            $vrli | Add-Member -Type NoteProperty -Name fqdn -Value (Get-VCFvRLI).loadBalancerFqdn
            $vrli | Add-Member -Type NoteProperty -Name adminUser -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $vrli.fqdn -and $_.credentialType -eq "API"})).username
            $vrli | Add-Member -Type NoteProperty -Name adminPassword -Value (Get-VCFCredential | Where-Object ({$_.resource.resourceName -eq $vrli.fqdn -and $_.credentialType -eq "API"})).password
            $vrliNodes = @()
            foreach ($node in (Get-VCFvRLI).nodes.fqdn | Sort-Object) {
                [Array]$vrliNodes += $node.Split(".")[0]
            }

            $var["Vrli"] = @{}
            if ($vrli.fqdn) {
                $var["Vrli"]["name"] = $vrli.fqdn.Split(".")[0]
            } else {
                $var["Vrli"]["name"] = $null
            }
            $var["Vrli"]["fqdn"] = $vrli.fqdn
            $var["Vrli"]["status"] = $vrli.status
            $var["Vrli"]["adminUser"] = $vrli.adminUser
            $var["Vrli"]["adminPassword"] = $vrli.adminPassword
            $var["Vrli"]["nodes"] = $vrliNodes


            $var["RegionalWSA"] =@{}
            $var["RegionalWSA"]["name"] = $regionalWSA

            #$MgmtInput = Get-Content -Path "./ManagementStartupInput.json" | ConvertFrom-JSON
            #$regionalWSA =  $MgmtInput.Wsa.name

            #get SDDC VM name from Vcenter server
            $Global:sddcmVMName
            $Global:vcHost
            $vcHostUser = ""
            $vcHostPass = ""
            if ($vcServer.fqdn) {
                Write-LogMessage -Type INFO -Message "Getting SDDC Manager Manager VM Name "
                Connect-VIServer -server $vcServer.fqdn -user $vcUser -password $vcPass | Out-Null
                $sddcmVMName = ((Get-VM * | Where-Object {$_.Guest.Hostname -eq $server}).Name)
                $vcHost = (get-vm | where Name -eq $vcServer.fqdn.Split(".")[0] | select VMHost).VMHost.Name
                $vcHostUser = (Get-VCFCredential -resourceType ESXI -resourceName $vcHost | Where-Object {$_.accountType -eq "USER"}).username
                $vcHostPass = (Get-VCFCredential -resourceType ESXI -resourceName $vcHost | Where-Object {$_.accountType -eq "USER"}).password

            }
            $var["Server"]["host"] = $vcHost
            $var["Server"]["vchostuser"] = $vcHostUser
            $var["Server"]["vchostpassword"] = $vcHostPass

            $var["SDDC"] = @{}
            $var["SDDC"]["name"] = $sddcmVMName
            $var["SDDC"]["fqdn"] = $server
            $var["SDDC"]["user"] = $user
            $var["SDDC"]["password"] = $pass

            $var | ConvertTo-Json > ManagementStartupInput.json
        }
        else {
            Write-LogMessage -Type ERROR -Message "Unable to obtain access token from SDDC Manager ($server), check credentials" -Colour Red
            Exit
        }

        # Shutdown vRealize Suite
        if ($($WorkloadDomain.type) -eq "MANAGEMENT") {
            if ($($vra.status -eq "ACTIVE")) {
                Request-PowerStateViaVRSLCM -server $vrslcm.fqdn -user $vrslcm.adminUser -pass $vrslcm.adminPassword -product VRA -mode power-off -timeout 1800
            }
            if ($($vrops.status -eq "ACTIVE")) {
                $vropsCollectorNodes = @()
                Set-vROPSClusterState -server $vrops.master -user $vrops.adminUser -pass $vrops.adminPassword -mode OFFLINE
                foreach ($node in (Get-vROPSClusterDetail -server $vrops.master -user $vrops.adminUser -pass $vrops.adminPassword | Where-Object {$_.role -eq "REMOTE_COLLECTOR"} | Select-Object name)) {
                    [Array]$vropsCollectorNodes += $node.name
                }
                Stop-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $vropsCollectorNodes -timeout 600
                Stop-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $vropsNodes -timeout 600
            }
            if ($($wsa.status -eq "ACTIVE")) {
                Request-PowerStateViaVRSLCM -server $vrslcm.fqdn -user $vrslcm.adminUser -pass $vrslcm.adminPassword -product VIDM -mode power-off -timeout 1800
            }
            if ($($vrslcm.status -eq "ACTIVE")) {
                Stop-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $vrslcm.fqdn.Split(".")[0] -timeout 600
            }
            if ($($vrli.status -eq "ACTIVE") -and $vrliNodes) {
                Stop-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $vrliNodes -timeout 600
            }
        }

        # Shutdown the NSX Edge Nodes
        $checkServer = Test-Connection -ComputerName $vcServer.fqdn -Quiet -Count 1
        if ($checkServer -eq "True") {
            #shutdown regionalWSA node
            if ($regionalWSA) {
                Stop-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $regionalWSA -timeout 600
            } else {
                Write-LogMessage -Type WARNING -Message "No Standalone Workspace ONE Access instance present, skipping shutdown" -Colour Cyan
            }
            if ($nsxtEdgeNodes) {
                Stop-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $nsxtEdgeNodes -timeout 600
            }
            else {
                Write-LogMessage -Type WARNING -Message "No NSX-T Data Center Edge Nodes present, skipping shutdown" -Colour Cyan
            }
        }
        else {
            Write-LogMessage -Type WARNING -Message "Looks like that $($vcServer.fqdn) may already be shutdown, skipping shutdown of $nsxtEdgeNodes" -Colour Cyan
        }
        # Shutdown the NSX Manager Nodes
        Stop-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $nsxtNodes -timeout 600

        $checkServer = Test-Connection -ComputerName $vcServer.fqdn -Quiet -Count 1
        if ($checkServer -eq "True") {
            Test-VsanHealth -cluster $cluster.name -server $vcServer.fqdn -user $vcUser -pass $vcPass
            Test-VsanObjectResync -cluster $cluster.name -server $vcServer.fqdn -user $vcUser -pass $vcPass
        }
        else {
            Write-LogMessage -Type WARNING -Message "Looks like that $($vcServer.fqdn) may already be shutdown, skipping checking VSAN health for cluster $($cluster.name)" -Colour Cyan
        }

        #Shut Down the SDDC Manager Virtual Machine in the Management Domain
        Stop-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $sddcmVMName -timeout 600

        #Shut Down the vSphere Cluster Services Virtual Machines
        Set-Retreatmode -server $vcServer.fqdn -user $vcUser -pass $vcPass -cluster $cluster.name -mode enable

        $counter = 0
        $retries = 30

        foreach ($esxiNode in $esxiWorkloadDomain) {
            while ($counter -ne $retries) {
                $count = Get-PoweredOnVMsCount -server $esxiNode.fqdn -user $esxiNode.username -pass $esxiNode.password -pattern "vcls"
                if ( $count ) {
                    start-sleep 10
                    $count += 1
                } else {
                    break
                }
            }
        }
        if ($counter -eq 30) {
            Write-LogMessage -Type WARNING -Message "The vCLS vms didn't get shutdown within stipulated timeout value" -Colour Cyan
        }

        #set DRS automationlevel to manual in the Management Domain
        Set-DrsAutomationLevel -server $vcServer.fqdn -user $vcUser -pass $vcPass -cluster $cluster.name -level Manual

         # Shutdown vCenter Server
        Stop-CloudComponent -server $vcHost -user $vcHostUser -pass $vcHostPass -pattern $vcServer.fqdn.Split(".")[0] -timeout 600

        # Prepare the vSAN cluster for shutdown - Performed on a single host only
        Invoke-EsxCommand -server $esxiWorkloadDomain.fqdn[0] -user $esxiWorkloadDomain.username[0] -pass $esxiWorkloadDomain.password[0] -expected "Cluster preparation is done" -cmd "python /usr/lib/vmware/vsan/bin/reboot_helper.py prepare"

        # Disable vSAN cluster member updates and place host in maintenance mode
        $count = 0
        $flag = 0
        foreach ($esxiNode in $esxiWorkloadDomain) {
            $count = Get-PoweredOnVMsCount -server $esxiNode.fqdn -user $esxiNode.username -pass $esxiNode.password
            if ( $count) {
                if ($force) {
                    Write-LogMessage -Type WARNING -Message "Looks like there are some VM's still in powered On state. Force option is set to true" -Colour Cyan
                    Write-LogMessage -Type WARNING -Message "Hence shutting down Non VCF management vm's to put host in  maintenence mode" -Colour Cyan
                    Stop-CloudComponent -server $esxiNode.fqdn -user $esxiNode.username -pass $esxiNode.password -pattern .* -timeout 100
                } else {
                    $flag = 1
                    Write-LogMessage -Type WARNING -Message "Looks like there are some VM's still in powered On state. Force option is set to false" -Colour Cyan
                    Write-LogMessage -Type WARNING -Message "So not shutting down Non VCF management vm's. Hence unable to proceed with putting host in  maintenence mode" -Colour Cyan
                    Write-LogMessage -Type WARNING -Message "use cmdlet:  Stop-CloudComponent -server $($esxiNode.fqdn) -user $($esxiNode.username) -pass $($esxiNode.password) -pattern .* -timeout 100" -Colour Cyan
                    Write-LogMessage -Type WARNING -Message "use cmdlet:  Set-MaintenanceMode -server $($esxiNode.fqdn) -user $($esxiNode.username) -pass $($esxiNode.password) -state ENABLE" -Colour Cyan
                }
            }
        }
        if (-Not $flag) {
            foreach ($esxiNode in $esxiWorkloadDomain) {
                Set-MaintenanceMode -server $esxiNode.fqdn -user $esxiNode.username -pass $esxiNode.password -state ENABLE
            }
        }
    }
}
Catch {
    Debug-CatchWriter -object $_
}

# Execute the Startup procedures
Try {
    if ($powerState -eq "Startup") {
        $MgmtInput = Get-Content -Path $inputFile | ConvertFrom-JSON

        Start-SetupLogFile -Path $PSScriptRoot -ScriptName $MyInvocation.MyCommand.Name
        Write-LogMessage -Type INFO -Message "Setting up the log file to path $logfile"

        Write-LogMessage -Type INFO -Message "Gathering System Details from json file"
        # Gather Details from SDDC Manager
        #$managementDomain = Get-VCFWorkloadDomain | Where-Object { $_.type -eq "MANAGEMENT" }
        #$mgmtCluster = Get-VCFCluster | Where-Object { $_.id -eq ($managementDomain.clusters.id) }
        $workloadDomain = $MgmtInput.Domain.name
        $workloadDomainType = $MgmtInput.Domain.type
        $cluster = New-Object -TypeName PSCustomObject
        $cluster | Add-Member -Type NoteProperty -Name Name -Value $MgmtInput.Cluster.name

        #Getting SDDC manager VM name
        $sddcmVMName =  $MgmtInput.SDDC.name
        $regionalWSA =  $MgmtInput.RegionalWSA.name

        # Gather vCenter Server Details and Credentials
        $vcServer = New-Object -TypeName PSCustomObject
        $vcServer | Add-Member -Type NoteProperty -Name Name -Value $MgmtInput.Server.name
        $vcServer | Add-Member -Type NoteProperty -Name fqdn -Value $MgmtInput.Server.fqdn
        $vcUser = $MgmtInput.Server.user
        $vcPass = $MgmtInput.Server.password
        $vcHost = $MgmtInput.Server.host
        $vcHostUser = $MgmtInput.Server.vchostuser
        $vcHostPass = $MgmtInput.Server.vchostpassword

        # Gather vRealize Suite Details
        $vrslcm = New-Object -TypeName PSCustomObject
        $vrslcm | Add-Member -Type NoteProperty -Name status -Value $MgmtInput.Vrslcm.status
        $vrslcm | Add-Member -Type NoteProperty -Name fqdn -Value $MgmtInput.Vrslcm.fqdn
        $vrslcm | Add-Member -Type NoteProperty -Name adminUser -Value $MgmtInput.Vrslcm.adminUser
        $vrslcm | Add-Member -Type NoteProperty -Name adminPassword -Value $MgmtInput.Vrslcm.adminPassword
        $vrslcm | Add-Member -Type NoteProperty -Name rootUser -Value $MgmtInput.Vrslcm.rootUser
        $vrslcm | Add-Member -Type NoteProperty -Name rootPassword -Value  $MgmtInput.Vrslcm.rootPassword

        $wsa = New-Object -TypeName PSCustomObject
        $wsa | Add-Member -Type NoteProperty -Name status -Value $MgmtInput.Wsa.status
        $wsa | Add-Member -Type NoteProperty -Name fqdn -Value $MgmtInput.Wsa.fqdn
        $wsa | Add-Member -Type NoteProperty -Name adminUser -Value $MgmtInput.Wsa.username
        $wsa | Add-Member -Type NoteProperty -Name adminPassword -Value $MgmtInput.Wsa.password
        $wsaNodes = $MgmtInput.Wsa.nodes


        $vrops = New-Object -TypeName PSCustomObject
        $vrops | Add-Member -Type NoteProperty -Name status -Value $MgmtInput.Vrops.status
        $vrops | Add-Member -Type NoteProperty -Name fqdn -Value $MgmtInput.Vrops.fqdn
        $vrops | Add-Member -Type NoteProperty -Name adminUser -Value $MgmtInput.Vrops.adminUser
        $vrops | Add-Member -Type NoteProperty -Name adminPassword -Value $MgmtInput.Vrops.adminPassword
        $vrops | Add-Member -Type NoteProperty -Name master -Value  $MgmtInput.Vrops.master
        $vropsNodes = $MgmtInput.Vrops.nodes


        $vra = New-Object -TypeName PSCustomObject
        $vra | Add-Member -Type NoteProperty -Name status -Value $MgmtInput.Vra.status
        $vra | Add-Member -Type NoteProperty -Name fqdn -Value $MgmtInput.Vra.fqdn
        $vraNodes = $MgmtInput.Vra.nodes


        $vrli = New-Object -TypeName PSCustomObject
        $vrli | Add-Member -Type NoteProperty -Name status -Value $MgmtInput.Vrli.status
        $vrli | Add-Member -Type NoteProperty -Name fqdn -Value $MgmtInput.Vrli.fqdn
        $vrli | Add-Member -Type NoteProperty -Name adminUser -Value  $MgmtInput.Vrli.adminUser
        $vrli | Add-Member -Type NoteProperty -Name adminPassword -Value $MgmtInput.Vrli.adminPassword
        $vrliNodes =$MgmtInput.Vrli.nodes



        # Gather ESXi Host Details for the Management Workload Domain
        $esxiWorkloadDomain = @()
        $workloadDomainArray = $MgmtInput.Hosts


        foreach ($esxiHost in $workloadDomainArray)
        {
            $esxDetails = New-Object -TypeName PSCustomObject
            $esxDetails | Add-Member -Type NoteProperty -Name fqdn -Value $esxiHost.fqdn
            $esxDetails | Add-Member -Type NoteProperty -Name username -Value $esxiHost.username
            $esxDetails | Add-Member -Type NoteProperty -Name password -Value $esxiHost.password
            $esxiWorkloadDomain += $esxDetails
        }


        # Gather NSX Manager Cluster Details
        $nsxtCluster = $MgmtInput.NsxtManager
        $nsxtMgrfqdn = $MgmtInput.NsxtManager.vipfqdn
        $nsxMgrVIP = New-Object -TypeName PSCustomObject
        $nsxMgrVIP | Add-Member -Type NoteProperty -Name adminUser -Value $MgmtInput.NsxtManager.user
        $nsxMgrVIP | Add-Member -Type NoteProperty -Name adminPassword -Value $MgmtInput.NsxtManager.password
        $nsxtNodesfqdn = $MgmtInput.NsxtManager.nodes
        $nsxtNodes = @()
        foreach ($node in $nsxtNodesfqdn) {
            [Array]$nsxtNodes += $node.Split(".")[0]
        }



        # Gather NSX Edge Node Details
        $nsxtEdgeCluster =  $MgmtInput.NsxEdge
        $nsxtEdgeNodesfqdn = $nsxtEdgeCluster.edgenodes.hostname
        $nsxtEdgeNodes = @()
        foreach ($node in $nsxtEdgeNodesfqdn) {
            [Array]$nsxtEdgeNodes += $node.Split(".")[0]
        }
        $nsxt_local_url = "https://$nsxtMgrfqdn/login.jsp?local=true"



        # Take hosts out of maintenance mode
        foreach ($esxiNode in $esxiWorkloadDomain) {
            Set-MaintenanceMode -server $esxiNode.fqdn -user $esxiNode.username -pass $esxiNode.password -state DISABLE
        }

        # Prepare the vSAN cluster for startup - Performed on a single host only
        Invoke-EsxCommand -server $esxiWorkloadDomain.fqdn[0] -user $esxiWorkloadDomain.username[0] -pass $esxiWorkloadDomain.password[0] -expected "Cluster reboot/poweron is completed successfully!" -cmd "python /usr/lib/vmware/vsan/bin/reboot_helper.py recover"

        foreach ($esxiNode in $esxiWorkloadDomain) {
            Invoke-EsxCommand -server $esxiNode.fqdn -user $esxiNode.username -pass $esxiNode.password -expected "Value of IgnoreClusterMemberListUpdates is 0" -cmd "esxcfg-advcfg -s 0 /VSAN/IgnoreClusterMemberListUpdates"
        }

        # Startup the Management Domain vCenter Server
        Start-CloudComponent -server $vcHost -user $vcHostUser -pass $vcHostPass -pattern $vcServer.Name -timeout 600
        Write-LogMessage -Type INFO -Message "Waiting for vCenter services to start on $($vcServer.fqdn) (may take some time)"
        Do {} Until (Connect-VIServer -server $vcServer.fqdn -user $vcUser -pass $vcPass -ErrorAction SilentlyContinue)

        # Startup the vSphere Cluster Services Virtual Machines in the Management Workload Domain
        $checkServer = Test-Connection -ComputerName $vcServer.fqdn -Quiet -Count 1
        if ($checkServer -eq "True") {
            Set-Retreatmode -server $vcServer.fqdn -user $vcUser -pass $vcPass -cluster $cluster.name -mode disable
            Test-VsanHealth -cluster $cluster.name -server $vcServer.fqdn -user $vcUser -pass $vcPass
            Test-VsanObjectResync -cluster $cluster.name -server $vcServer.fqdn -user $vcUser -pass $vcPass

        }
        else {
            Write-LogMessage -Type WARNING -Message "Looks like that $($vcServer.fqdn) is not power on, skipping startup of vcls vms" -Colour Cyan
            Exit
        }

        #Startup the SDDC Manager Virtual Machine in the Management Workload Domain
        Start-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $sddcmVMName -timeout 600

        # Startup the NSX Manager Nodes in the Management Workload Domain
        Start-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $nsxtNodes -timeout 600
        Get-NsxtClusterStatus -server $nsxtMgrfqdn -user $nsxMgrVIP.adminUser -pass $nsxMgrVIP.adminPassword

         # Startup the NSX Edge Nodes in the Management Workload Domain
        if ($nsxtEdgeNodes) {
            Start-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $nsxtEdgeNodes -timeout 600
        }
        else {
            Write-LogMessage -Type WARNING -Message "No NSX-T Data Center Edge Nodes present, skipping startup" -Colour Cyan
        }

        # Startup the single region WSA in the Management Domain
        if($regionalWSA) {
            Start-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $regionalWSA -timeout 600
        } else {
            Write-LogMessage -Type WARNING -Message "No Standalone Workspace ONE Access instance is present, skipping startup" -Colour Cyan
        }


        # Startup vRealize Suite
        if ($($WorkloadDomainType) -eq "MANAGEMENT") {
          if ($($vrslcm.status -eq "ACTIVE")) {
                Start-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $vrslcm.fqdn.Split(".")[0] -timeout 600
            }
            if ($($vrli.status -eq "ACTIVE") -and $vrliNodes) {
                Start-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $vrliNodes -timeout 600
            }
            if ($($vrops.status -eq "ACTIVE") -and $vropsNodes) {
                Start-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $vropsNodes -timeout 600
                $vropsCollectorNodes = @()
                foreach ($node in (Get-vROPSClusterDetail -server $vrops.master -user $vrops.adminUser -pass $vrops.adminPassword | Where-Object {$_.role -eq "REMOTE_COLLECTOR"} | Select-Object name)) {
                    [Array]$vropsCollectorNodes += $node.name
                }
                Start-CloudComponent -server $vcServer.fqdn -user $vcUser -pass $vcPass -nodes $vropsCollectorNodes -timeout 600
            }
            if ($($wsa.status -eq "ACTIVE")) {
                Request-PowerStateViaVRSLCM -server $vrslcm.fqdn -user $vrslcm.adminUser -pass $vrslcm.adminPassword -product VIDM -mode power-on -timeout 1800
            }
            if ($($vra.status -eq "ACTIVE")) {
                Request-PowerStateViaVRSLCM -server $vrslcm.fqdn -user $vrslcm.adminUser -pass $vrslcm.adminPassword -product VRA -mode power-on -timeout 1800
            }
            if ($($vrops.status -eq "ACTIVE")) {
                Set-vROPSClusterState -server $vrops.master -user $vrops.adminUser -pass $vrops.adminPassword -mode ONLINE
            }
        }

        # Change the DRS Automation Level to Fully Automated for both the Management Domain Clusters
        $checkServer = Test-Connection -ComputerName $vcServer.fqdn -Quiet -Count 1
        if ($checkServer -eq "True") {
            Set-DrsAutomationLevel -server $vcServer.fqdn -user $vcUser -pass $vcPass -cluster $cluster.name -level FullyAutomated
        }

    }
}
Catch {
    Debug-CatchWriter -object $_
}
