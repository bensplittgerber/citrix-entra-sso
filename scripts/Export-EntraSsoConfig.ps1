#Requires -Version 7.2
<#
.SYNOPSIS
    Read-only export of a Citrix Entra SSO (no FAS) configuration: Entra apps, Broker site, delivery groups,
    StoreFront store. Writes JSON per section plus a check summary.

.DESCRIPTION
    Nothing is changed anywhere. Entra is read with Microsoft Graph (Microsoft.Graph.Authentication only, delegated
    read scopes). Broker and StoreFront are read over PowerShell remoting (Windows PowerShell endpoint on the
    Delivery Controller / StoreFront server) with read-only Get-* cmdlets.
    Client secrets are never read: of password credentials only count and expiry are exported (no 'hint').
    The export contains real names and IDs of your environment - keep it out of Git (exports/ is ignored).

.PARAMETER ConfigFile
    JSON like config/example.json (real values in config/<name>.local.json).

.PARAMETER OutDir
    Target folder. Default: exports/<yyyyMMdd-HHmmss> in the repo root.

.PARAMETER Skip
    Sections to leave out: Entra, Broker, StoreFront.

.EXAMPLE
    ./scripts/Export-EntraSsoConfig.ps1 -ConfigFile ./config/lab.local.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ConfigFile,
    [string] $OutDir,
    [ValidateSet('Entra', 'Broker', 'StoreFront')] [string[]] $Skip = @()
)

$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -LiteralPath $ConfigFile | ConvertFrom-Json
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot "..\exports\$(Get-Date -Format yyyyMMdd-HHmmss)" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

# Enums deserialized from a remote session carry 'value' (int) and 'Value' (name); keep the name only, otherwise the
# JSON has keys that differ only in case and strict readers reject it.
function ConvertTo-PlainData($o, [int] $Depth = 0) {
    if ($null -eq $o -or $Depth -gt 12) { return $o }
    # deserialized enum: an int wrapped in a PSObject with a 'Value' note property holding the name
    if ($o.PSObject.BaseObject -is [ValueType] -and $o.PSObject.Properties.Match('Value').Count) { return "$($o.PSObject.Properties['Value'].Value)" }
    if ($o -is [string] -or $o -is [ValueType]) { return $o }
    if ($o -is [Enum]) { return "$o" }
    if ($o -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}; foreach ($k in $o.Keys) { $h["$k"] = ConvertTo-PlainData $o[$k] ($Depth + 1) }; return $h
    }
    if ($o -is [System.Collections.IEnumerable]) { return , @($o | ForEach-Object { ConvertTo-PlainData $_ ($Depth + 1) }) }
    $names = @($o.PSObject.Properties.Name)
    if ($names.Count -eq 2 -and ($names -ccontains 'value') -and ($names -ccontains 'Value')) { return "$($o.PSObject.Properties | Where-Object { $_.Name -ceq 'Value' } | ForEach-Object Value)" }
    $h = [ordered]@{}
    foreach ($p in $o.PSObject.Properties) { if ($p.Name -notin 'PSComputerName', 'RunspaceId', 'PSShowComputerName') { $h[$p.Name] = ConvertTo-PlainData $p.Value ($Depth + 1) } }
    return [pscustomobject]$h
}

function Save-Section([string] $Name, $Data) {
    $path = Join-Path $OutDir "$Name.json"
    ConvertTo-PlainData $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Write-Host "  [OK] $Name -> $path"
}

# GET that returns the response or an error record instead of throwing (one missing object must not end the export)
function Get-Graph([string] $Uri) {
    try { Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject }
    catch { [pscustomobject]@{ _error = $_.Exception.Message; _uri = $Uri } }
}

$export = [ordered]@{}

# --- Entra ---------------------------------------------------------------------------------------------------------
if ('Entra' -notin $Skip) {
    Write-Host 'Entra (Microsoft Graph, read-only scopes)'
    Import-Module Microsoft.Graph.Authentication
    Connect-MgGraph -TenantId $cfg.tenantId -Scopes 'Application.Read.All', 'Directory.Read.All' -NoWelcome

    $appSelect = 'id,appId,displayName,signInAudience,identifierUris,web,spa,publicClient,requiredResourceAccess,passwordCredentials,keyCredentials'
    $app = (Get-Graph "v1.0/applications?`$filter=appId eq '$($cfg.clientAppId)'&`$select=$appSelect").value | Select-Object -First 1
    if ($app) {
        # never export secret hints, only how many credentials exist and when they expire
        $app | Add-Member -NotePropertyName passwordCredentialSummary -NotePropertyValue @($app.passwordCredentials | ForEach-Object { [pscustomobject]@{ displayName = $_.displayName; endDateTime = $_.endDateTime } })
        $app.PSObject.Properties.Remove('passwordCredentials')
        $app | Add-Member -NotePropertyName keyCredentialCount -NotePropertyValue @($app.keyCredentials).Count
        $app.PSObject.Properties.Remove('keyCredentials')
        if ($app.web) { $app.web.PSObject.Properties.Remove('implicitGrantSettings') | Out-Null }
    }

    $spSelect = 'id,appId,displayName,accountEnabled,appRoleAssignmentRequired,servicePrincipalNames,servicePrincipalType'
    $clientSp = (Get-Graph "v1.0/servicePrincipals?`$filter=appId eq '$($cfg.clientAppId)'&`$select=$spSelect").value | Select-Object -First 1
    $resSp = (Get-Graph "v1.0/servicePrincipals?`$filter=appId eq '$($cfg.resourceAppId)'&`$select=$spSelect").value | Select-Object -First 1

    $grants = if ($clientSp) { (Get-Graph "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($clientSp.id)'").value | Select-Object consentType, resourceId, scope } else { @() }

    $rds = $null; $approved = @(); $deviceGroups = @()
    if ($resSp) {
        $base = "v1.0/servicePrincipals/$($resSp.id)/remoteDesktopSecurityConfiguration"
        $rds = Get-Graph $base | Select-Object isRemoteDesktopProtocolEnabled, _error
        $approved = @((Get-Graph "$base/approvedClientApps").value | ForEach-Object {
                $sp = Get-Graph "v1.0/servicePrincipals/$($_.id)?`$select=id,appId,displayName"
                [pscustomobject]@{ id = $_.id; appId = $sp.appId; displayName = $sp.displayName } })
        $deviceGroups = @((Get-Graph "$base/targetDeviceGroups").value | ForEach-Object {
                $g = Get-Graph "v1.0/groups/$($_.id)?`$select=id,displayName,groupTypes,membershipRule"
                [pscustomobject]@{ id = $_.id; displayName = $g.displayName; dynamic = ($g.groupTypes -contains 'DynamicMembership'); membershipRule = $g.membershipRule } })
    }

    $export.Entra = [ordered]@{
        clientApplication = $app; clientServicePrincipal = $clientSp; resourceServicePrincipal = $resSp
        permissionGrants = @($grants); remoteDesktopSecurity = $rds; approvedClientApps = $approved; targetDeviceGroups = $deviceGroups
    }
    Save-Section 'entra' $export.Entra
    Disconnect-MgGraph | Out-Null
}

# --- Broker --------------------------------------------------------------------------------------------------------
if ('Broker' -notin $Skip) {
    Write-Host "Broker ($($cfg.deliveryController), remoting)"
    $export.Broker = Invoke-Command -ComputerName $cfg.deliveryController -ArgumentList (, $cfg.deliveryGroups) -ScriptBlock {
        param($groups)
        Add-PSSnapin Citrix.Broker.Admin.V2 -ErrorAction Stop
        $site = Get-BrokerSite | Select-Object Name, TrustRequestsSentToTheXmlServicePort, AzureGlobalCloudId, AzureSSOnAuthorizeUrl, AzureSSOnClientId, AzureSSOnRedirectUrl, AzureSSOnResourceAppId
        $dg = foreach ($n in $groups) {
            $g = Get-BrokerDesktopGroup -Name $n -ErrorAction SilentlyContinue
            if (-not $g) { [pscustomobject]@{ Name = $n; _error = 'not found' }; continue }
            [pscustomobject]@{
                Name = $g.Name; Enabled = $g.Enabled; SessionSupport = "$($g.SessionSupport)"; MachineLogOnType = "$($g.MachineLogOnType)"
                Machines = @(Get-BrokerMachine -DesktopGroupUid $g.Uid | Select-Object MachineName, @{ n = 'RegistrationState'; e = { "$($_.RegistrationState)" } }, InMaintenanceMode, AgentVersion, OSType)
            }
        }
        [pscustomobject]@{ Site = $site; DesktopGroups = @($dg) }
    } | Select-Object Site, DesktopGroups
    Save-Section 'broker' $export.Broker
}

# --- StoreFront ----------------------------------------------------------------------------------------------------
if ('StoreFront' -notin $Skip) {
    Write-Host "StoreFront ($($cfg.storeFrontServer), remoting)"
    $export.StoreFront = Invoke-Command -ComputerName $cfg.storeFrontServer -ArgumentList $cfg.storeVirtualPath, $cfg.storeWebVirtualPath -ScriptBlock {
        param($storePath, $webPath)
        $ErrorActionPreference = 'Stop'
        Get-Module -ListAvailable Citrix.StoreFront* | Import-Module
        # run a Get-* cmdlet if this StoreFront version has it; record the error instead of failing
        function Try-Get([scriptblock] $Sb) { try { & $Sb } catch { [pscustomobject]@{ _error = $_.Exception.Message } } }

        $store = Get-STFStoreService -VirtualPath $storePath
        $web = Get-STFWebReceiverService -VirtualPath $webPath
        $auth = Get-STFAuthenticationService -StoreService $store
        $out = [ordered]@{
            Version         = Try-Get { "$(Get-STFVersion)" }
            Store           = [pscustomobject]@{ VirtualPath = $store.VirtualPath; FriendlyName = $store.FriendlyName }
            Farms           = Try-Get { @(Get-STFStoreFarm -StoreService $store | Select-Object FarmName, FarmType, Servers, Port, TransportType) }
            LaunchOptions   = Try-Get { Get-STFStoreLaunchOptions -StoreService $store }
            RoamingGateways = Try-Get { @(Get-STFRoamingGateway | Select-Object Name, Location, CallbackUrl, Logon, IpAddress, SessionReliability, @{ n = 'Version'; e = { "$($_.Version)" } }, @{ n = 'StaUrls'; e = { @($_.SecureTicketAuthorityUrls | ForEach-Object { "$($_.StaUrl)" }) } }) }
            RemoteAccess    = Try-Get { Get-STFStoreRegisteredGateway -StoreService $store | Select-Object Name, GatewayUrl }
            AuthProtocols   = Try-Get { @(Get-STFAuthenticationServiceProtocol -AuthenticationService $auth | Where-Object Enabled) }
            PluginAssistant = Try-Get { Get-STFWebReceiverPluginAssistant -WebReceiverService $web }
            UserInterface   = Try-Get { Get-STFWebReceiverUserInterface -WebReceiverService $web }
        }
        # Entra settings cmdlets differ between StoreFront versions: read every Get-* variant that exists
        $out.EntraCmdlets = @(Get-Command -Module Citrix.StoreFront* -Name 'Get-*Entra*' -ErrorAction SilentlyContinue | ForEach-Object {
                $c = $_; $r = Try-Get { & $c.Name -AuthenticationService $auth }
                if ($r._error) { $r = Try-Get { & $c.Name -StoreService $store } }
                [pscustomobject]@{ Cmdlet = $c.Name; Result = $r } })
        [pscustomobject]$out
    } | Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName
    Save-Section 'storefront' $export.StoreFront
}

# --- Checks (from the troubleshooting of this repo; read-only, informational) --------------------------------------
$checks = [System.Collections.Generic.List[object]]::new()
function Add-Check([string] $Name, [bool] $Ok, [string] $Detail) { $checks.Add([pscustomobject]@{ Result = ($Ok ? 'OK' : 'FAIL'); Check = $Name; Detail = $Detail }) }

$e = $export.Entra; $b = $export.Broker
$storeWebUrl = '{0}{1}/' -f $cfg.gatewayUrl.TrimEnd('/'), $cfg.storeWebVirtualPath.TrimEnd('/')
if ($b) {
    $s = $b.Site
    Add-Check 'Broker AzureSSOnRedirectUrl = Store Web URL with trailing slash' ($s.AzureSSOnRedirectUrl -ceq $storeWebUrl) "actual '$($s.AzureSSOnRedirectUrl)', expected '$storeWebUrl'"
    Add-Check 'Broker AzureSSOnAuthorizeUrl ends with /' ("$($s.AzureSSOnAuthorizeUrl)".EndsWith('/')) "$($s.AzureSSOnAuthorizeUrl)"
    Add-Check 'Broker AzureSSOnClientId = config clientAppId' ($s.AzureSSOnClientId -eq $cfg.clientAppId) "$($s.AzureSSOnClientId)"
    Add-Check 'Broker XML trust enabled' ([bool]$s.TrustRequestsSentToTheXmlServicePort) "$($s.TrustRequestsSentToTheXmlServicePort)"
    foreach ($g in $b.DesktopGroups) { Add-Check "Delivery group '$($g.Name)' MachineLogOnType HybridAzureAd" ($g.MachineLogOnType -eq 'HybridAzureAd') "$($g.MachineLogOnType)$($g._error)" }
}
$sf = $export.StoreFront
if ($sf) {
    Add-Check 'StoreFront store launch option EntraIdSsoEnabled' ([bool]$sf.LaunchOptions.EntraIdSsoEnabled) "$($sf.LaunchOptions.EntraIdSsoEnabled)"
    Add-Check 'StoreFront store without FAS (VdaLogonDataProviderName empty)' ([string]::IsNullOrEmpty($sf.LaunchOptions.VdaLogonDataProviderName)) "'$($sf.LaunchOptions.VdaLogonDataProviderName)'"
    $ent = ($sf.EntraCmdlets | Where-Object Cmdlet -eq 'Get-STFEntraIdSettings').Result
    Add-Check 'StoreFront Entra ID settings enabled for the tenant' ([bool]$ent.Enabled -and $ent.TenantId -eq $cfg.tenantId) "Enabled=$($ent.Enabled) TenantId=$($ent.TenantId)$($ent._error)"
    $gw = @($sf.RoamingGateways | Where-Object { "$($_.Location)".TrimEnd('/') -eq $cfg.gatewayUrl.TrimEnd('/') })
    Add-Check 'StoreFront Gateway for gatewayUrl with callback URL' ([bool]($gw | Where-Object CallbackUrl)) (@($gw | ForEach-Object { "$($_.Name) -> $($_.CallbackUrl)" }) -join '; ')
}
if ($e) {
    $spa = @($e.clientApplication.spa.redirectUris); $pub = @($e.clientApplication.publicClient.redirectUris)
    Add-Check 'Client app SPA redirect contains Store Web URL (with /)' ($spa -ccontains $storeWebUrl) ($spa -join ', ')
    Add-Check 'Client app public client redirect ctxaadsso://citrix.aad.redirect' ($pub -ccontains 'ctxaadsso://citrix.aad.redirect') ($pub -join ', ')
    Add-Check 'Client app single tenant' ($e.clientApplication.signInAudience -eq 'AzureADMyOrg') "$($e.clientApplication.signInAudience)"
    Add-Check 'Resource service principal enabled' ([bool]$e.resourceServicePrincipal.accountEnabled) "$($e.resourceServicePrincipal.displayName)"
    Add-Check 'Remote Desktop protocol enabled on resource app' ([bool]$e.remoteDesktopSecurity.isRemoteDesktopProtocolEnabled) "$($e.remoteDesktopSecurity.isRemoteDesktopProtocolEnabled)"
    Add-Check 'Client app is an approved client app' (@($e.approvedClientApps.appId) -contains $cfg.clientAppId) (@($e.approvedClientApps.displayName) -join ', ')
    $imp = $e.permissionGrants | Where-Object { $_.resourceId -eq $e.resourceServicePrincipal.id -and $_.scope -match 'user_impersonation' -and $_.consentType -eq 'AllPrincipals' }
    Add-Check 'Admin consent user_impersonation on resource app' ([bool]$imp) "$(@($e.permissionGrants.scope) -join ' | ')"
    Add-Check 'Target device group set (hides the consent prompt)' (@($e.targetDeviceGroups).Count -gt 0) (@($e.targetDeviceGroups.displayName) -join ', ')
}
$checks | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
Save-Section 'checks' $checks
Write-Host "Export written to $OutDir (contains real names - do not commit)."
