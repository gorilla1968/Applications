# Determine where to do the logging
$logPS = "C:\Windows\Temp\configure_storefront.log"
 
Write-Verbose "Setting Arguments" -Verbose
$StartDTM = (Get-Date)
 
Start-Transcript $LogPS

$MyConfigFileloc = ("$env:Settings\Applications\Settings.xml")
[xml]$MyConfigFile = (Get-Content $MyConfigFileLoc)

$DomainFQDN = $env:USERDNSDOMAIN
$XDC01 = $MyConfigFile.Settings.Citrix.XDC01
$XDC02 = $MyConfigFile.Settings.Citrix.XDC02
$SF01 = $MyConfigFile.Settings.Citrix.SF01
$SF02 = $MyConfigFile.Settings.Citrix.SF02

# Import the StoreFront SDK
import-module "C:\Program Files\Citrix\Receiver StoreFront\Scripts\ImportModules.ps1"
 
# Use New UI
$UseNewUI = "no"
 
# Set up Store Variables
$baseurl = "https://workspace." + "$DomainFQDN"
$Farmname = "Controllers"
$Port = "443"
$TransportType = "HTTPS"
$sslRelayPort = "443"
$Servers = "$XDC01","$XDC02"
$LoadBalance = $true
$FarmType = "XenDesktop"
$FriendlyName = "Store"
$SFPath = "/Citrix/Store"
$SFPathWeb = "/Citrix/StoreWeb"
$SiteID = 1
 
# Define Gateway
$GatewayAddress = "https://workspace." + "$DomainFQDN"
 
# Define Beacons
$ExternalBeacon = "https://www.citrix.com"
 
# Define NetScaler Variables
$GatewayName = "Netscaler Gateway"
$staservers = "https://$XDC01/scripts/ctxsta.dll","https://$XDC02/scripts/ctxsta.dll"
$CallBackURL = "https://workspace." + "$DomainFQDN"
 
# Define Trusted Domains
$AuthPath = "/Citrix/Authentication"

# Check if New or Existing Cluster

If (Test-Path "\\$SF01\C$\Windows\Temp\Passcode.ps1"){
  Write-Verbose "StoreFront Cluster Exists - Joining" -Verbose
  Invoke-Command -ComputerName "$SF01" -ScriptBlock {Start-ScheduledTask -Taskname 'Create StoreFront Cluster Join Passcode'}
  Start-Sleep -s 60
  $passcode = Get-Content "\\$SF01\C$\Windows\Temp\Passcode.txt"
  import-module "C:\Program Files\Citrix\Receiver StoreFront\Scripts\ImportModules.ps1"
  Start-DSXdServerGroupJoinService
  Start-DSXdServerGroupMemberJoin -authorizerHostName "$SF01" -authorizerPasscode $Passcode
  Write-Verbose "Waiting for join action to complete" -Verbose
  Start-Sleep -s 300
  Invoke-Command -ComputerName "$SF01" -ScriptBlock {
    import-module "C:\Program Files\Citrix\Receiver StoreFront\Scripts\ImportModules.ps1"
    Start-Sleep -s 60
    Write-Verbose "Replicating StoreFront Cluster" -Verbose
    Start-DSConfigurationReplicationClusterUpdate -Confirm:$false
    Start-Sleep -s 180
    Remove-Item "C:\Windows\Temp\Passcode.txt" -Force
    }
  }Else{
    Write-Verbose "StoreFront Cluster Doesn't Exists - Creating" -Verbose
    # Do the initial Config
    Set-DSInitialConfiguration -hostBaseUrl $baseurl -farmName $Farmname -port $Port -transportType $TransportType -sslRelayPort $sslRelayPort -servers $Servers -loadBalance $LoadBalance -farmType $FarmType -StoreFriendlyName $FriendlyName -StoreVirtualPath $SFPath -WebReceiverVirtualPath $SFPathWeb
 
    # Add NetScaler Gateway
    $GatewayID = ([guid]::NewGuid()).ToString()
    Add-DSGlobalV10Gateway -Id $GatewayID -Name $GatewayName -Address $GatewayAddress -CallbackUrl $CallBackURL -RequestTicketTwoSTA $false -Logon Domain -SessionReliability $true -SecureTicketAuthorityUrls $staservers -IsDefault $true
 
    # Add Gateway to Store
    $gateway = Get-DSGlobalGateway -GatewayId $GatewayID
    $AuthService = Get-STFAuthenticationService -SiteID $SiteID -VirtualPath $AuthPath
    Set-DSStoreGateways -SiteId $SiteID -VirtualPath $SFPath -Gateways $gateway
    Set-DSStoreRemoteAccess -SiteId $SiteID -VirtualPath $SFPath -RemoteAccessType "StoresOnly"
    Add-DSAuthenticationProtocolsDeployed -SiteId $SiteID -VirtualPath $AuthPath -Protocols CitrixAGBasic
    Set-DSWebReceiverAuthenticationMethods -SiteId $SiteID -VirtualPath $SFPathWeb -AuthenticationMethods ExplicitForms,CitrixAGBasic
    Enable-STFAuthenticationServiceProtocol -AuthenticationService $AuthService -Name CitrixAGBasic
 
    # Add beacon External
    # Set-STFRoamingBeacon -internal $InternalBeacon -external $ExternalBeacon1,$ExternalBeacon2
 
    # Enable Unified Experience
    $Store = Get-STFStoreService -siteID $SiteID -VirtualPath $SFPath
    $Rfw = Get-STFWebReceiverService -SiteId $SiteID -VirtualPath $SFPathWeb
    Set-STFStoreService -StoreService $Store -UnifiedReceiver $Rfw -Confirm:$False
 
    # Set the Default Site
    Set-STFWebReceiverService -WebReceiverService $Rfw -DefaultIISSite:$True
 
    # Configure Trusted Domains
    Set-STFExplicitCommonOptions -AuthenticationService $AuthService -Domains $DomainFQDN -DefaultDomain $DomainFQDN -HideDomainField $True -AllowUserPasswordChange Always -ShowPasswordExpiryWarning Windows
 
    # Enable the authentication methods
    # Enable-STFAuthenticationServiceProtocol -AuthenticationService $AuthService -Name Forms-Saml,Certificate
    Enable-STFAuthenticationServiceProtocol -AuthenticationService $AuthService -Name ExplicitForms
 
    # Fully Delegate Cred Auth to NetScaler Gateway
    # Set-STFCitrixAGBasicOptions -AuthenticationService $AuthService -CredentialValidationMode Kerberos
 
    # Set Receiver for Web Auth Methods
    Set-STFWebReceiverAuthenticationMethods -WebReceiverService $Rfw -AuthenticationMethods ExplicitForms,CitrixAGBasic
 
    # Set Receiver Deployment Methods
    Set-STFWebReceiverPluginAssistant -WebReceiverService $Rfw -Html5Enabled Fallback -enabled $false
 
    # Set Session Timeout Options
    Set-STFWebReceiverService -WebReceiverService $Rfw -SessionStateTimeout 60
    Set-STFWebReceiverAuthenticationManager -WebReceiverService $Rfw -LoginFormTimeout 30
 
    # Set the Workspace Control Settings
    Set-STFWebReceiverUserInterface -WebReceiverService $Rfw -WorkspaceControlLogoffAction "None"
    Set-STFWebReceiverUserInterface -WebReceiverService $Rfw -WorkspaceControlEnabled $True
    Set-STFWebReceiverUserInterface -WebReceiverService $Rfw -WorkspaceControlAutoReconnectAtLogon $False
    Set-STFWebReceiverUserInterface -WebReceiverService $Rfw -WorkspaceControlShowReconnectButton $True
    Set-STFWebReceiverUserInterface -WebReceiverService $Rfw -WorkspaceControlShowDisconnectButton $True
 
    # Set Client Interface Settings
    Set-STFWebReceiverUserInterface -WebReceiverService $Rfw -AutoLaunchDesktop $False
    Set-STFWebReceiverUserInterface -WebReceiverService $Rfw -ReceiverConfigurationEnabled $True
 
    # Enable Loopback on HTTP
    Set-DSLoopback -SiteId $SiteID -VirtualPath $SFPathWeb -Loopback OnUsingHttp
 
    # Use New UI
    If($UseNewUI -eq "yes"){
        Remove-Item -Path "C:\iNetPub\wwwroot\$SFPathWeb\receiver\css\*" -Recurse -Force
        Copy-Item -Path "$PSScriptRoot\custom\storefront\workspace\receiver\*" -Destination "C:\iNetPub\wwwroot\$SFPathWeb\receiver" -Recurse -Force
        Copy-Item -Path "$PSScriptRoot\custom\storefront\workspace\receiver.html" -Destination "C:\iNetPub\wwwroot\$SFPathWeb" -Recurse -Force
        Copy-Item -Path "$PSScriptRoot\custom\storefront\workspace\receiver.appcache" -Destination "C:\iNetPub\wwwroot\$SFPathWeb" -Recurse -Force
        iisreset
    }
 
    # Copy down branding
    Copy-Item -Path "$PSScriptRoot\custom\storefront\branding\background.png" -Destination "C:\iNetPub\wwwroot\$SFPathWeb\custom" -Recurse -Force
    Copy-Item -Path "$PSScriptRoot\custom\storefront\branding\logo.png" -Destination "C:\iNetPub\wwwroot\$SFPathWeb\custom" -Recurse -Force
    Copy-Item -Path "$PSScriptRoot\custom\storefront\branding\hlogo.png" -Destination "C:\iNetPub\wwwroot\$SFPathWeb\custom" -Recurse -Force
    Copy-Item -Path "$PSScriptRoot\custom\storefront\branding\strings.en.js" -Destination "C:\iNetPub\wwwroot\$SFPathWeb\custom" -Recurse -Force
    Copy-Item -Path "$PSScriptRoot\custom\storefront\branding\style.css" -Destination "C:\iNetPub\wwwroot\$SFPathWeb\custom" -Recurse -Force

    Write-Verbose "Create Scheduled Task for Citrix StoreFront Cluster Join Passcode" -Verbose
    Copy-Item -Path "$PSScriptRoot\Passcode.ps1" -Destination "C:\Windows\Temp\" -Recurse -Force
    $A = New-ScheduledTaskAction -Execute "powershell.exe" -Argument '-ExecutionPolicy Bypass -file C:\Windows\Temp\Passcode.ps1'
    $T = New-ScheduledTaskTrigger -Once -At (get-date).AddSeconds(-10); $t.EndBoundary = (get-date).AddSeconds(3600).ToString('s')
    $S = New-ScheduledTaskSettingsSet -StartWhenAvailable -DeleteExpiredTaskAfter 01:00:00
    Register-ScheduledTask -Force -user SYSTEM -TaskName "Create StoreFront Cluster Join Passcode" -Action $A -Trigger $T -Settings $S

}
 
Write-Verbose "Stop logging" -Verbose
$EndDTM = (Get-Date)
Write-Verbose "Elapsed Time: $(($EndDTM-$StartDTM).TotalSeconds) Seconds" -Verbose
Write-Verbose "Elapsed Time: $(($EndDTM-$StartDTM).TotalMinutes) Minutes" -Verbose
Stop-Transcript
