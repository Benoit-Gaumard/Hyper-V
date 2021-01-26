##############################################
# Variables
##############################################
$Primary_Site = @{"SiteName"="Moscow";"ClusterName"="MyClusterinMoscow";"LocalBorkerName"="MybrkinMoscow"}
$DR_Site = @{"SiteName"="Saint-Petersburg";"ClusterName"="MyClusterinSpt";"LocalBorkerName"="MybrkinSpt"}

#$Primary_Site = @{"SiteName"="Saint-Petersburg";"ClusterName"="MyClusterinSpt";"LocalBorkerName"="MybrkinSpt"}
#$DR_Site = @{"SiteName"="Moscow";"ClusterName"="MyClusterinMoscow";"LocalBorkerName"="MybrkinMoscow"}

$Mode = "PlannedFailover" # TestFailover, PlannedFailover or UnPlannedFailover

Write-Host "Setting primary site as : [$(($Primary_Site.SiteName).ToUpper())] and disaster recovery site as : [$(($DR_Site.SiteName).ToUpper())]" -ForegroundColor Green
Write-Host "The current mode is : $Mode `r`n" -ForegroundColor Green

# Don't fill any table if you want to select all VMs
$ExludeVMs = @() # Exclude these VMs
$IncludeVMs = @("BENOIT-TEMP") # Select only these VMs

# Clustered VMS's
If($ExludeVMs.Count -ge 1) 
{
    $VMs = @()
    $VMs += Get-ClusterResource -Cluster $Primary_Site.ClusterName | Where-Object{$_.ResourceType -like "Virtual Machine" -and $_.OwnerGroup -notin $ExludeVMs}
}

If($IncludeVMs.Count -ge 1) 
{
    $VMs = @()
    $VMs += Get-ClusterResource -Cluster $Primary_Site.ClusterName | Where-Object{$_.ResourceType -like "Virtual Machine" -and $_.OwnerGroup -in $IncludeVMs}
}

If($IncludeVMs.Count -eq 0 -and $ExludeVMs.Count -eq 0) 
{
    $VMs = @()
    $VMs += Get-ClusterResource -Cluster $Primary_Site.ClusterName | Where-Object{$_.ResourceType -like "Virtual Machine"} 

}

If ($VMs.count -eq 0) {Write-Host "No VM available with the selected filter" -ForegroundColor Yellow} 

#Look for each VM in that list 
foreach ($VM in $VMs) 
{
    $RunningState = $false
    $VMName = $VM.OwnerGroup.Name
    Write-host "Processing $VMName" -ForegroundColor Green  

    $SourceHost = $VM.OwnerGroup.OwnerNode.Name
 
    # Current VM State
    if ($VM.State -eq 'Running' -or $VM.State -eq 'Online') 
    {
        Write-Host "Virtual machine is running" -ForegroundColor Green 	
        $RunningState = $true
    }
    Else
    {
        Write-Host "Virtual machine is turned off" -ForegroundColor Green 
    }

	# Get VM replication details
	try
	{
		$GetVMReplicaDetails = Get-VMReplication -VMName $VMName -ComputerName $SourceHost -ErrorAction Stop 
	}
	catch
	{
		Write-Host "Replication is not enabled for the virtual machine $VMName. Skipping it" -ForegroundColor Yellow 
		Continue
	}

    If ($GetVMReplicaDetails.State -eq "InitialReplicationInProgress")
    {
		Write-Host "Replication is in progress for the virtual machine $VMName. Skipping it" -ForegroundColor Yellow 
		Continue
    }
        
	# Failover
	try
	{
		# Check Destination Hyper-V Host
		$DestinationHost = (Get-ClusterResource -Cluster $DR_Site.ClusterName| Where-Object{$_.ResourceType -like "Virtual Machine" -and $_.OwnerGroup -eq $VMName}).OwnerNode.Name

		# Check Primary Host
		$CheckPrimaryHost = $GetVMReplicaDetails.PrimaryServer + '.'
		$CheckPrimaryHost = $CheckPrimaryHost.SubString(0, $CheckPrimaryHost.IndexOf('.'))

		# Check Replica Host
		$CheckReplicaHost = $GetVMReplicaDetails.ReplicaServer + '.'
		$CheckReplicaHost = $CheckReplicaHost.SubString(0, $CheckReplicaHost.IndexOf('.'))

		$DR_SiteLocalBorkerName = $DR_Site.LocalBorkerName.ToUpper()		
		
		switch ($Mode)
		{
			"TestFailover" 
			{

				if ($CheckReplicaHost -eq $DR_SiteLocalBorkerName)
				{
					$CheckTestVM = Get-VM –VMName "$VMName - Test" -ComputerName $DestinationHost -ErrorAction SilentlyContinue
					If (!$CheckTestVM)
					{
						try
						{
							Write-Host "$Mode on : [$(($DR_Site.SiteName).ToUpper())]" -ForegroundColor Green 

							Start-VMFailover -AsTest –VMName $VMName -ComputerName $DestinationHost -Confirm:$false   
							Start-VM –VMName "$VMName - Test" -ComputerName $DestinationHost -ErrorAction Stop
							#Stop-VMFailover –VMName $VMName -ComputerName $DestinationHost -Confirm:$false
                            Write-Host "Starting $VMName - Test, execute this command if you want to delete the VM : Stop-VMFailover –VMName $VMName -ComputerName $DestinationHost -Confirm:$false" -ForegroundColor Green
						}
						catch
						{
							Write-Error "$VMName failed to failover to $DestinationHost"
							Continue
						}
					}
					Else
					{
						Write-Host "$VMName - Test already exist, execute this command if you want to delete the VM : Stop-VMFailover –VMName $VMName -ComputerName $DestinationHost -Confirm:$false" -ForegroundColor Yellow
						Continue 
					}
				}
				Else
				{
					Write-Host "The specified virtual machine $VMName cannot be failed over because the specified Hyper-V source host $SourceHost is not hosting the replicated VM" -ForegroundColor Yellow
				}
			}

			"PlannedFailover"
			{

				If ($RunningState)
				{
					# Stopping virtual machine
					try
					{
						Write-Host "Stopping virtual machine" -ForegroundColor Green 
		
						Stop-VM -ComputerName $SourceHost -Name $VMName -Force -ErrorAction Stop 
		
						$State = (Get-VM $VMName -ComputerName $SourceHost).State 
		
						#Looping to wait for VM to be in a shut down state.
						do 
						{
							$State = (Get-VM $VMName -ComputerName $SourceHost).State
							Start-Sleep -Seconds 5
						}
						while ($State -eq 'Running' -or $State -eq 'Online')
					}
					catch
					{
						Write-Error -Message "Failed to shut down $VMName, skipping it"
						Continue
					}
				}

				Write-Host "$Mode from : [$(($Primary_Site.SiteName).ToUpper())] to [$(($DR_Site.SiteName).ToUpper())]" -ForegroundColor Green 
				if ($CheckPrimaryHost -eq $SourceHost)
				{
					try
					{
						Start-VMFailover –Prepare –VMName $VMName -ComputerName $SourceHost -Confirm:$false -ErrorAction Stop
						Start-VMFailover –VMName $VMName -ComputerName $DestinationHost -Confirm:$false -ErrorAction Stop
						Set-VMReplication –Reverse –VMName $VMName -ComputerName $DestinationHost -Confirm:$false -ErrorAction Stop
				
						If ($RunningState)
						{
							Start-VM –VMName $VMName -ComputerName $DestinationHost -ErrorAction Stop
						}

						Write-Host "$VMName has been failed over from $SourceHost to $DestinationHost" -ForegroundColor Green
					}
					catch
					{
						Write-Error "$VMName failed to failover to $DestinationHost"
						Continue
					}
				}
				else 
				{
					Write-Host "The specified virtual machine $VMName cannot be failed over because the specified Hyper-V source host $SourceHost is hosting the replicated VM and not the primary VM" -ForegroundColor Yellow
				}

			}

			"UnPlannedFailover"
			{


				if ($CheckReplicaHost -eq $DR_SiteLocalBorkerName)
				{
					Write-Host "Get virtual machine snapshots" -ForegroundColor Green 
					$Snapshots = Get-VMSnapshot -VMName $VMName -ComputerName $DestinationHost -SnapshotType Replica -ErrorAction SilentlyContinue  
				
					If ($Snapshots)
					{
						try
						{
							Start-VMFailover –VMName $VMName -ComputerName $DestinationHost -VMRecoverySnapshot $Snapshots[0] -Confirm:$false  -ErrorAction Stop
							Complete-VMFailover –VMName $VMName -ComputerName $DestinationHost -Confirm:$false -ErrorAction Stop
							Start-VM –VMName $VMName -ComputerName $DestinationHost -Confirm:$false -ErrorAction Stop
						}
						catch
						{
							Write-Error "$VMName failed to failover to $DestinationHost"
							Continue
						}
					}
					Else
					{
						try
						{
							Write-Host "No snapshots" -ForegroundColor Green 
							Start-VMFailover –VMName $VMName -ComputerName $DestinationHost -Confirm:$false -ErrorAction Stop
							Complete-VMFailover –VMName $VMName -ComputerName $DestinationHost -Confirm:$false -ErrorAction Stop
							Start-VM –VMName $VMName -ComputerName $DestinationHost -Confirm:$false -ErrorAction Stop
						}
						catch
						{
							Write-Error "$VMName failed to failover to $DestinationHost"
							Continue
						}
					}
				}
				Else
				{
					Write-Host "The specified virtual machine $VMName cannot be failed over because the specified Hyper-V source host $SourceHost is not hosting the replicated VM" -ForegroundColor Yellow
				}
			}

			Default
			{
				write-Host "Invalid mode, please enter : TestFailover, PlannedFailover or UnPlannedFailover" -ForegroundColor Red
				break
			}
		}
	}
	catch
	{
		Write-Error "Failed to get the DestinationHost for $VMName"
		Continue
	}
}
