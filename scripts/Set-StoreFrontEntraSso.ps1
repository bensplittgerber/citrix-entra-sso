#Requires -Version 7.2
<#
.SYNOPSIS
    Idempotent StoreFront setup for Entra SSO without FAS: authentication service, store + farm, Web Receiver,
    Entra ID settings, launch options, Gateway (roaming gateway + store registration), web settings.

.DESCRIPTION
    Runs over PowerShell remoting on the StoreFront server (Windows PowerShell endpoint). Every item is read first and
    compared with the desired state; only differences are changed. With -WhatIf nothing is changed and the plan is
    printed (Action = WouldCreate / WouldUpdate). Existing settings outside this list are left alone.
    Not handled (report only): switching an existing Web Receiver from classic to modern UI.

.PARAMETER ConfigFile
    JSON like config/example.json, including the "storeFront" section.

.EXAMPLE
    ./scripts/Set-StoreFrontEntraSso.ps1 -ConfigFile ./config/lab.local.json -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)] [string] $ConfigFile)

$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -LiteralPath $ConfigFile | ConvertFrom-Json
$sfc = $cfg.storeFront
$desired = @{
    StorePath = $cfg.storeVirtualPath.TrimEnd('/'); WebPath = $cfg.storeWebVirtualPath.TrimEnd('/')
    AuthPath = "$($cfg.storeVirtualPath.TrimEnd('/'))Auth"; FriendlyName = $sfc.storeFriendlyName
    TenantId = $cfg.tenantId; GatewayUrl = "$($cfg.gatewayUrl.TrimEnd('/'))/"
    FarmName = $sfc.farmName; FarmServers = @($sfc.farmServers); FarmPort = [int]$sfc.farmPort; FarmTransport = $sfc.farmTransport
    GatewayName = $sfc.gatewayName; GatewayVersion = $sfc.gatewayVersion; GatewaySnip = $sfc.gatewaySnip
    CallbackUrl = $sfc.callbackUrl; StaUrls = @($sfc.staUrls)
    # exact sets: listed protocols/methods are enabled, the others disabled (a new auth service enables ExplicitForms)
    AuthProtocols = @($sfc.authProtocols ?? @('CitrixAGBasic', 'CitrixFederation'))
    WebAuthMethods = @($sfc.webAuthMethods ?? @('CitrixAGBasic'))
}
$dryRun = -not $PSCmdlet.ShouldProcess($cfg.storeFrontServer, "configure StoreFront store $($desired.StorePath) for Entra SSO")

$result = Invoke-Command -ComputerName $cfg.storeFrontServer -ArgumentList $desired, $dryRun -ScriptBlock {
    param($d, $dryRun)
    $ErrorActionPreference = 'Stop'
    Get-Module -ListAvailable Citrix.StoreFront* | Import-Module
    $log = [System.Collections.Generic.List[object]]::new()

    # compare, then apply only on difference; $Apply runs only when not a dry run
    function Step([string] $Item, $Current, $Desired, [scriptblock] $Apply, [switch] $Create) {
        $same = ("$Current" -ceq "$Desired")
        $action = if ($same) { 'NoChange' } elseif ($dryRun) { if ($Create) { 'WouldCreate' } else { 'WouldUpdate' } } else { if ($Create) { 'Create' } else { 'Update' } }
        if (-not $same -and -not $dryRun) { & $Apply | Out-Null }
        $log.Add([pscustomobject]@{ Action = $action; Item = $Item; Current = "$Current"; Desired = "$Desired" })
    }

    # 0 precheck before any change: the display name must not belong to another store (StoreFront allows duplicates,
    #   Workspace app and the console then show two stores with the same name)
    $dup = @(Get-STFStoreService | Where-Object { $_.FriendlyName -eq $d.FriendlyName -and $_.VirtualPath -ne $d.StorePath })
    if ($dup) { throw "Store display name '$($d.FriendlyName)' is already used by $(@($dup.VirtualPath) -join ', '). Choose another storeFriendlyName." }

    # 1 authentication service
    $auth =Get-STFAuthenticationService -VirtualPath $d.AuthPath -ErrorAction SilentlyContinue
    Step 'Authentication service' ($(if ($auth) { $auth.VirtualPath } else { '' })) $d.AuthPath -Create { $script:auth = Add-STFAuthenticationService -VirtualPath $d.AuthPath -Confirm:$false }
    if (-not $auth -and -not $dryRun) { $auth = Get-STFAuthenticationService -VirtualPath $d.AuthPath }

    # 2 store + farm
    $store = Get-STFStoreService -VirtualPath $d.StorePath -ErrorAction SilentlyContinue
    Step 'Store service' ($(if ($store) { $store.VirtualPath } else { '' })) $d.StorePath -Create {
        Add-STFStoreService -VirtualPath $d.StorePath -AuthenticationService $auth -FriendlyName $d.FriendlyName -FarmName $d.FarmName -FarmType XenDesktop `
            -Servers $d.FarmServers -Port $d.FarmPort -TransportType $d.FarmTransport -LoadBalance $true -Confirm:$false }
    if (-not $store -and -not $dryRun) { $store = Get-STFStoreService -VirtualPath $d.StorePath }
    if ($store -and $store.FriendlyName -ne $d.FriendlyName) {
        $log.Add([pscustomobject]@{ Action = 'Manual'; Item = 'Store display name'; Current = $store.FriendlyName; Desired = $d.FriendlyName })
    }
    if ($store) {
        $farm =Get-STFStoreFarm -StoreService $store -FarmName $d.FarmName -ErrorAction SilentlyContinue
        $cur = if ($farm) { '{0}:{1}/{2}' -f ($farm.Servers -join ','), $farm.Port, $farm.TransportType } else { '' }
        Step "Farm $($d.FarmName)" $cur ('{0}:{1}/{2}' -f ($d.FarmServers -join ','), $d.FarmPort, $d.FarmTransport) {
            Set-STFStoreFarm -StoreService $store -FarmName $d.FarmName -FarmType XenDesktop -Servers $d.FarmServers -Port $d.FarmPort -TransportType $d.FarmTransport -Confirm:$false }
    }

    # 3 Web Receiver (modern UI on create)
    $web = Get-STFWebReceiverService -VirtualPath $d.WebPath -ErrorAction SilentlyContinue
    Step 'Web Receiver service' ($(if ($web) { $web.VirtualPath } else { '' })) $d.WebPath -Create { Add-STFWebReceiverService -VirtualPath $d.WebPath -StoreService $store -ClassicReceiverExperience $false -Confirm:$false }
    if (-not $web -and -not $dryRun) { $web = Get-STFWebReceiverService -VirtualPath $d.WebPath }
    if ($web -and $web.WebReceiver.ClassicReceiverExperience) {
        $log.Add([pscustomobject]@{ Action = 'Manual'; Item = 'Web Receiver UI'; Current = 'classic'; Desired = 'modern (Entra SSO needs the modern UI)' })
    }

    # dry run of a new store: the steps below need the objects above; list them so the plan is complete
    if ($dryRun -and (-not $store -or -not $auth -or -not $web)) {
        foreach ($i in 'Auth protocols (enabled)', 'Entra ID settings', 'Launch option EntraIdSsoEnabled', 'Launch option VdaLogonDataProvider (FAS)',
            "Gateway $($d.GatewayName)".TrimEnd(), 'Gateway registered on store', 'Web auth methods', 'Web settings (plugin assistant)') {
            $log.Add([pscustomobject]@{ Action = 'WouldSet'; Item = $i; Current = '(after create)'; Desired = '(as configured)' })
        }
    }

    if ($store -and $auth) {
        # 4 authentication protocols: exactly the configured set
        $protos = @(Get-STFAuthenticationServiceProtocol -AuthenticationService $auth)
        $curOn = @($protos | Where-Object Enabled | ForEach-Object Name | Sort-Object)
        $wantOn = @($d.AuthProtocols | Sort-Object)
        Step 'Auth protocols (enabled)' ($curOn -join ',') ($wantOn -join ',') {
            $on = @($wantOn | Where-Object { $_ -notin $curOn }); $off = @($curOn | Where-Object { $_ -notin $wantOn })
            if ($on) { Enable-STFAuthenticationServiceProtocol -Name $on -AuthenticationService $auth }
            if ($off) { Disable-STFAuthenticationServiceProtocol -Name $off -AuthenticationService $auth -Confirm:$false } }

        # 5 Entra ID settings
        $ent = Get-STFEntraIdSettings -AuthenticationService $auth -WarningAction SilentlyContinue
        Step 'Entra ID settings' ('{0}/{1}' -f $ent.Enabled, $ent.TenantId) ('True/{0}' -f $d.TenantId) { Set-STFEntraIdSettings -AuthenticationService $auth -Enabled $true -TenantId $d.TenantId -Confirm:$false }

        # 6 launch options: Entra SSO on, FAS off (FAS on an Entra SSO store is not supported)
        $lo = Get-STFStoreLaunchOptions -StoreService $store
        Step 'Launch option EntraIdSsoEnabled' $lo.EntraIdSsoEnabled $true { Set-STFStoreLaunchOptions -StoreService $store -EntraIdSsoEnabled $true -Confirm:$false }
        Step 'Launch option VdaLogonDataProvider (FAS)' $lo.VdaLogonDataProviderName '' { Set-STFStoreLaunchOptions -StoreService $store -VdaLogonDataProvider '' -Confirm:$false }

        # 7 roaming gateway (optional: without storeFront.gatewayName the store is created without remote access,
        #   the Gateway is added in a later run once it exists)
        if (-not $d.GatewayName) {
            $log.Add([pscustomobject]@{ Action = 'Skipped'; Item = 'Gateway + store registration'; Current = ''; Desired = 'no storeFront.gatewayName in config' })
        } else {
        $gw = Get-STFRoamingGateway -Name $d.GatewayName -ErrorAction SilentlyContinue
        $want = '{0}|{1}|Domain|{2}|{3}|True|{4}' -f $d.GatewayUrl, $d.CallbackUrl, $d.GatewayVersion, $d.GatewaySnip, ($d.StaUrls -join ',')
        $cur = if ($gw) { '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $gw.Location, $gw.CallbackUrl, $gw.Logon, $gw.Version, $gw.IpAddress, $gw.SessionReliability, (($gw.SecureTicketAuthorityUrls | ForEach-Object { "$($_.StaUrl)" }) -join ',') } else { '' }
        $gwArgs = @{ LogonType = 'Domain'; Version = $d.GatewayVersion; GatewayUrl = $d.GatewayUrl; CallbackUrl = $d.CallbackUrl; SubnetIPAddress = $d.GatewaySnip; SecureTicketAuthorityUrls = $d.StaUrls }
        if ($gw) { Step "Gateway $($d.GatewayName)" $cur $want { Set-STFRoamingGateway -Name $d.GatewayName @gwArgs -SessionReliability $true -Confirm:$false } }
        else { Step "Gateway $($d.GatewayName)" '' $want -Create { Add-STFRoamingGateway -Name $d.GatewayName @gwArgs -SessionReliability -Confirm:$false } }

        # 8 register the gateway on the store (remote access) as default
        $reg = @(Get-STFStoreRegisteredGateway -StoreService $store -ErrorAction SilentlyContinue).Name -contains $d.GatewayName
        Step 'Gateway registered on store' $reg $true { Register-STFStoreGateway -Gateway (Get-STFRoamingGateway -Name $d.GatewayName) -StoreService $store -DefaultGateway -Confirm:$false }
        }
    }

    if ($web) {
        # 9 web authentication methods: exactly the configured set (Gateway pass-through only by default)
        $methods = @((Get-STFWebReceiverAuthenticationMethods -WebReceiverService $web).Methods | Sort-Object)
        $wantMethods = @($d.WebAuthMethods | Sort-Object)
        Step 'Web auth methods' ($methods -join ',') ($wantMethods -join ',') { Set-STFWebReceiverAuthenticationMethods -WebReceiverService $web -AuthenticationMethods $wantMethods -Confirm:$false }

        # 10 web settings: "Let the user choose", not "locally installed app only", browser extension on (hybrid launch)
        $pa = Get-STFWebReceiverPluginAssistant -WebReceiverService $web
        $cur = 'PA={0} Html5={1} ProtocolHandler={2} AllowSkip={3} RequireNative={4} BrowserExtension={5}' -f $pa.Enabled, $pa.Html5.Enabled, $pa.ProtocolHandler.Enabled, $pa.AllowSkipNativeAppDetection, $pa.RequireNativeAppUse, $pa.BrowserExtension.Enabled
        Step 'Web settings (plugin assistant)' $cur 'PA=False Html5=Fallback ProtocolHandler=True AllowSkip=True RequireNative=False BrowserExtension=True' {
            Set-STFWebReceiverPluginAssistant -WebReceiverService $web -Enabled $false -Html5Enabled Fallback -ProtocolHandlerEnabled $true `
                -AllowSkipNativeAppDetection $true -RequireNativeAppUse $false -BrowserExtensionEnabled $true -Confirm:$false }
    }
    $log
}

$result | ForEach-Object { if ($_.Action -eq 'NoChange') { [pscustomobject]@{ Action = $_.Action; Item = $_.Item; Change = '' } } else { [pscustomobject]@{ Action = $_.Action; Item = $_.Item; Change = "'$($_.Current)' -> '$($_.Desired)'" } } } |
    Format-Table -AutoSize -Wrap | Out-String -Width 240 | Write-Host
$changes = @($result | Where-Object Action -notin 'NoChange', 'Skipped', 'Manual')
$notes = @($result | Where-Object Action -in 'Skipped', 'Manual')
if ($notes) { Write-Host "$($notes.Count) item(s) skipped or manual, see table." }
Write-Host ($dryRun ? "Dry run: $($changes.Count) change(s) planned, nothing changed." : "$($changes.Count) change(s) applied.")
