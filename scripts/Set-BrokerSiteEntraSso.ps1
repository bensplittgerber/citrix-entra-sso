#Requires -Version 7.2
<#
.SYNOPSIS
    Idempotent Broker site setup for Entra SSO without FAS: AzureSSOnClientId, AzureSSOnAuthorizeUrl and
    AzureSSOnRedirectUrl from the same config file as the other scripts.

.DESCRIPTION
    Runs over PowerShell remoting on the Delivery Controller (Windows PowerShell endpoint, Citrix Broker snap-in) as a
    CVAD admin. Each value is read first and compared with the desired state; only differences are changed. With
    -WhatIf nothing is changed and the plan is printed (Action = WouldUpdate).
    Desired state (derived from the config, see config/example.json):
      - AzureSSOnClientId     = clientAppId (the Entra Client application, same app as the NetScaler OIDC client)
      - AzureSSOnAuthorizeUrl = https://login.microsoftonline.com/<tenantId>/ (WITH trailing slash)
      - AzureSSOnRedirectUrl  = <gatewayUrl><storeWebVirtualPath>/ (Store Web URL WITH trailing slash; must be an SPA
        redirect URI of the Client application, see New-EntraSsoClientApp.ps1)
    AzureSSOnResourceAppId is only reported (expected citrix.cloud.com/<resourceAppId>), never changed.
    The AzureSSOn* values are SITE-wide: one Entra SSO store origin per site. The script warns when the site already
    points at another store. The current values are printed first as a Set-BrokerSite command (the way back).

.PARAMETER ConfigFile
    JSON like config/example.json (tenantId, clientAppId, gatewayUrl, storeWebVirtualPath, deliveryController).

.EXAMPLE
    ./scripts/Set-BrokerSiteEntraSso.ps1 -ConfigFile ./config/lab.local.json -WhatIf
.EXAMPLE
    ./scripts/Set-BrokerSiteEntraSso.ps1 -ConfigFile ./config/lab.local.json
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)] [string] $ConfigFile)

$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -LiteralPath $ConfigFile | ConvertFrom-Json
foreach ($k in 'tenantId', 'clientAppId', 'gatewayUrl', 'storeWebVirtualPath', 'deliveryController') {
    if (-not $cfg.$k -or "$($cfg.$k)" -match '[<>]') { throw "$k missing or still a placeholder in $ConfigFile" }
}
if ($cfg.clientAppId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw "clientAppId '$($cfg.clientAppId)' is not a GUID" }
$gw = [uri]$cfg.gatewayUrl
if (-not $gw.IsAbsoluteUri -or $gw.Scheme -ne 'https') { throw "gatewayUrl must be an absolute https URL: '$($cfg.gatewayUrl)'" }
if (-not $gw.IsDefaultPort) { Write-Warning "gatewayUrl has port $($gw.Port): hybrid launches need the store on 443 (Citrix Web Extension store URL pattern has no port)." }

$desired = [ordered]@{
    AzureSSOnClientId     = $cfg.clientAppId
    AzureSSOnAuthorizeUrl = "https://login.microsoftonline.com/$($cfg.tenantId)/"
    AzureSSOnRedirectUrl  = '{0}{1}/' -f $cfg.gatewayUrl.TrimEnd('/'), $cfg.storeWebVirtualPath.TrimEnd('/')
}
$resourceApp = "citrix.cloud.com/$($cfg.resourceAppId ?? '3a510bb1-e334-4298-831e-3eac97f8b26c')"
$dryRun = -not $PSCmdlet.ShouldProcess($cfg.deliveryController, 'set Broker site AzureSSOn* for Entra SSO')

$result = Invoke-Command -ComputerName $cfg.deliveryController -ArgumentList $desired, $dryRun -ScriptBlock {
    param($d, $dryRun)
    $ErrorActionPreference = 'Stop'
    Add-PSSnapin Citrix.Broker.Admin.V2 -ErrorAction Stop
    $site = Get-BrokerSite
    $before = [ordered]@{}; foreach ($k in $d.Keys) { $before[$k] = "$($site.$k)" }
    $set = @{}; foreach ($k in $d.Keys) { if ($before[$k] -cne $d[$k]) { $set[$k] = $d[$k] } }
    if ($set.Count -and -not $dryRun) { Set-BrokerSite @set }
    $after = Get-BrokerSite
    [pscustomobject]@{
        Before        = $before
        Set           = @($set.Keys)
        ResourceAppId = "$($after.AzureSSOnResourceAppId)"
        After         = [ordered]@{ AzureSSOnClientId = "$($after.AzureSSOnClientId)"; AzureSSOnAuthorizeUrl = "$($after.AzureSSOnAuthorizeUrl)"; AzureSSOnRedirectUrl = "$($after.AzureSSOnRedirectUrl)" }
    }
}

# way back first, so it is on screen even if something below fails
$back = ($desired.Keys | ForEach-Object { "-$_ '$($result.Before[$_])'" }) -join ' '
Write-Host "Current values (way back): Set-BrokerSite $back"
$old = $result.Before.AzureSSOnRedirectUrl
if ($old -like 'https://*' -and $old -cne $desired.AzureSSOnRedirectUrl) {
    Write-Warning "Site points at another store ($old). AzureSSOn* are site-wide - Entra SSO launches from that store stop working."
}

$rows = foreach ($k in $desired.Keys) {
    $changed = $k -in $result.Set
    $action = if (-not $changed) { 'NoChange' } elseif ($dryRun) { 'WouldUpdate' } else { 'Update' }
    [pscustomobject]@{ Action = $action; Item = $k; Change = $(if ($changed) { "'$($result.Before[$k])' -> '$($desired[$k])'" } else { '' }) }
}
$rows += [pscustomobject]@{ Action = $(if ($result.ResourceAppId -eq $resourceApp) { 'Check OK' } else { 'Check FAIL' }); Item = 'AzureSSOnResourceAppId (not changed)'
    Change = "is '$($result.ResourceAppId)', expected '$resourceApp'" }
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 240 | Write-Host

$changes = @($rows | Where-Object Action -in 'Update', 'WouldUpdate')
if (-not $dryRun -and $changes) {
    $bad = @($desired.Keys | Where-Object { $result.After[$_] -cne $desired[$_] })
    if ($bad) { throw "Read back differs for: $($bad -join ', ')" }
}
Write-Host ($dryRun ? "Dry run: $($changes.Count) change(s) planned, nothing changed." : "$($changes.Count) change(s) applied.")
Write-Host "Entra Client application $($desired.AzureSSOnClientId) needs the SPA redirect URI '$($desired.AzureSSOnRedirectUrl)' (New-EntraSsoClientApp.ps1)."
