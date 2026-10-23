#Requires -Version 7.2
<#
.SYNOPSIS
    Idempotent Entra setup of the Client application for Citrix Entra SSO without FAS: one single-tenant app used as
    NetScaler OIDC client AND as Citrix Client app, admin consent, approved client of Citrix-Workspace-Resource.

.DESCRIPTION
    Microsoft Graph only (Microsoft.Graph.Authentication, Invoke-MgGraphRequest). Each item is read, compared with the
    desired state and changed only on difference. -WhatIf connects with read scopes and prints the plan.
    Desired state (derived from the config, see config/example.json "entraApp"):
      - app registration <displayName>, single tenant (AzureADMyOrg)
      - redirect URIs: Web <gatewayUrl>/oauth/login, SPA <gatewayUrl><storeWebVirtualPath>/ (WITH trailing slash),
        public client ctxaadsso://citrix.aad.redirect (exact sets; extra URIs are removed)
      - API permissions (delegated): Microsoft Graph openid profile email offline_access User.Read,
        Citrix-Workspace-Resource user_impersonation
      - service principal, admin consent (AllPrincipals) for both resources
      - approved client app on Citrix-Workspace-Resource, Remote Desktop protocol enabled there
    Prerequisite (once per tenant, admin consent URL from Citrix): the Citrix-Workspace-Resource service principal
    exists (appId 3a510bb1-e334-4298-831e-3eac97f8b26c). The script does not create it.
    -NewSecret adds a client secret and stores it ONLY in $env:<entraApp.secretEnvVar> of the calling session
    (run the script in the session that later deploys the NetScaler OAuth action). The value is never printed.

.EXAMPLE
    ./scripts/New-EntraSsoClientApp.ps1 -ConfigFile ./config/dev.local.json -WhatIf
.EXAMPLE
    ./scripts/New-EntraSsoClientApp.ps1 -ConfigFile ./config/dev.local.json -NewSecret
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ConfigFile,
    [switch] $NewSecret
)

$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -LiteralPath $ConfigFile | ConvertFrom-Json
$ea = $cfg.entraApp
if (-not $ea.displayName) { throw "entraApp.displayName missing in $ConfigFile" }
$gw = $cfg.gatewayUrl.TrimEnd('/')
$want = @{
    Web    = @(if ($ea.webRedirectUris) { $ea.webRedirectUris } else { "$gw/oauth/login" })
    Spa    = @(if ($ea.spaRedirectUris) { $ea.spaRedirectUris } else { '{0}{1}/' -f $gw, $cfg.storeWebVirtualPath.TrimEnd('/') })
    Public = @(if ($ea.publicRedirectUris) { $ea.publicRedirectUris } else { 'ctxaadsso://citrix.aad.redirect' })
}
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphScopes = @('openid', 'profile', 'email', 'offline_access', 'User.Read')
$resScopes = @('user_impersonation')

$dryRun = -not $PSCmdlet.ShouldProcess("tenant $($cfg.tenantId)", "configure Entra app '$($ea.displayName)'")
$scopes = if ($dryRun) { 'Application.Read.All', 'Directory.Read.All' }
          else { 'Application.ReadWrite.All', 'DelegatedPermissionGrant.ReadWrite.All', 'Application-RemoteDesktopConfig.ReadWrite.All' }
Import-Module Microsoft.Graph.Authentication
Connect-MgGraph -TenantId $cfg.tenantId -Scopes $scopes -NoWelcome

$log = [System.Collections.Generic.List[object]]::new()
function G([string] $Method, [string] $Uri, $Body) {
    $p = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
    Invoke-MgGraphRequest @p
}
function Step([string] $Item, $Current, $Desired, [scriptblock] $Apply, [switch] $Create) {
    $same = ("$Current" -ceq "$Desired")
    $action = if ($same) { 'NoChange' } elseif ($dryRun) { if ($Create) { 'WouldCreate' } else { 'WouldUpdate' } } else { if ($Create) { 'Create' } else { 'Update' } }
    if (-not $same -and -not $dryRun) { & $Apply | Out-Null }
    $log.Add([pscustomobject]@{ Action = $action; Item = $Item; Current = "$Current"; Desired = "$Desired" })
}
function Sorted($a) { (@($a) | Where-Object { $_ } | Sort-Object) -join ' ' }

# resource service principals and the scope ids (resolved by name, no hard-coded permission GUIDs)
$graphSp = (G GET "v1.0/servicePrincipals?`$filter=appId eq '$graphAppId'&`$select=id,appId,oauth2PermissionScopes").value | Select-Object -First 1
$resSp = (G GET "v1.0/servicePrincipals?`$filter=appId eq '$($cfg.resourceAppId)'&`$select=id,appId,displayName,oauth2PermissionScopes").value | Select-Object -First 1
if (-not $resSp) { throw "Service principal of the Citrix resource app $($cfg.resourceAppId) not found - grant the Citrix admin consent first." }
function ScopeAccess($sp, [string[]] $names) {
    @($names | ForEach-Object {
            $n = $_; $s = $sp.oauth2PermissionScopes | Where-Object value -eq $n
            if (-not $s) { throw "Scope '$n' not found on $($sp.appId)" }
            @{ id = $s.id; type = 'Scope' } })
}
$rra = @(
    @{ resourceAppId = $graphAppId; resourceAccess = (ScopeAccess $graphSp $graphScopes) }
    @{ resourceAppId = $cfg.resourceAppId; resourceAccess = (ScopeAccess $resSp $resScopes) }
)
$rraText = { param($r) (@($r) | ForEach-Object { '{0}:{1}' -f $_.resourceAppId, ((@($_.resourceAccess) | ForEach-Object { $_.id } | Sort-Object) -join ',') } | Sort-Object) -join ' ' }

# 1 app registration
$apps = @((G GET "v1.0/applications?`$filter=displayName eq '$($ea.displayName)'&`$select=id,appId,displayName,signInAudience,web,spa,publicClient,requiredResourceAccess").value)
if ($apps.Count -gt 1) { throw "More than one app named '$($ea.displayName)' - resolve manually." }
$app = $apps | Select-Object -First 1
$body = @{
    displayName = $ea.displayName; signInAudience = 'AzureADMyOrg'
    web = @{ redirectUris = $want.Web }; spa = @{ redirectUris = $want.Spa }; publicClient = @{ redirectUris = $want.Public }
    requiredResourceAccess = $rra
}
Step 'App registration' ($(if ($app) { $app.displayName } else { '' })) $ea.displayName -Create { $script:app = G POST 'v1.0/applications' $body }
if ($app) {
    Step 'Sign-in audience' $app.signInAudience 'AzureADMyOrg' { G PATCH "v1.0/applications/$($app.id)" @{ signInAudience = 'AzureADMyOrg' } }
    Step 'Redirect URIs Web' (Sorted $app.web.redirectUris) (Sorted $want.Web) { G PATCH "v1.0/applications/$($app.id)" @{ web = @{ redirectUris = $want.Web } } }
    Step 'Redirect URIs SPA' (Sorted $app.spa.redirectUris) (Sorted $want.Spa) { G PATCH "v1.0/applications/$($app.id)" @{ spa = @{ redirectUris = $want.Spa } } }
    Step 'Redirect URIs public client' (Sorted $app.publicClient.redirectUris) (Sorted $want.Public) { G PATCH "v1.0/applications/$($app.id)" @{ publicClient = @{ redirectUris = $want.Public } } }
    Step 'API permissions' (& $rraText $app.requiredResourceAccess) (& $rraText $rra) { G PATCH "v1.0/applications/$($app.id)" @{ requiredResourceAccess = $rra } }
}

# 2 service principal of the app
$appId = $app.appId
$sp = if ($appId) { (G GET "v1.0/servicePrincipals?`$filter=appId eq '$appId'&`$select=id,appId,displayName").value | Select-Object -First 1 }
Step 'Service principal' ($(if ($sp) { $sp.appId } else { '' })) ($(if ($appId) { $appId } else { '(new app)' })) -Create { $script:sp = G POST 'v1.0/servicePrincipals' @{ appId = $script:app.appId } }
if (-not $sp -and -not $dryRun -and $script:app) { $sp = (G GET "v1.0/servicePrincipals?`$filter=appId eq '$($script:app.appId)'").value | Select-Object -First 1 }

# 3 admin consent (AllPrincipals) per resource
foreach ($g in @(@{ Sp = $graphSp; Scopes = $graphScopes; Name = 'Microsoft Graph' }, @{ Sp = $resSp; Scopes = $resScopes; Name = $resSp.displayName })) {
    $grant = if ($sp) { (G GET "v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($sp.id)' and resourceId eq '$($g.Sp.id)' and consentType eq 'AllPrincipals'").value | Select-Object -First 1 }
    $curScopes = if ($grant) { Sorted ($grant.scope -split ' ') } else { '' }
    $newScopes = Sorted (@($grant.scope -split ' ') + $g.Scopes | Select-Object -Unique)
    $resId = $g.Sp.id; $sc = $newScopes
    if ($grant) { Step "Admin consent $($g.Name)" $curScopes $newScopes { G PATCH "v1.0/oauth2PermissionGrants/$($grant.id)" @{ scope = $sc } } }
    else { Step "Admin consent $($g.Name)" '' $newScopes -Create { G POST 'v1.0/oauth2PermissionGrants' @{ clientId = $sp.id; consentType = 'AllPrincipals'; resourceId = $resId; scope = $sc } } }
}

# 4 Citrix-Workspace-Resource: Remote Desktop protocol on, this app approved
$rdBase = "v1.0/servicePrincipals/$($resSp.id)/remoteDesktopSecurityConfiguration"
$rd = G GET $rdBase
Step 'RDS protocol on resource app' $rd.isRemoteDesktopProtocolEnabled $true { G PATCH $rdBase @{ isRemoteDesktopProtocolEnabled = $true } }
$approved = @((G GET "$rdBase/approvedClientApps").value | ForEach-Object id)
$isApproved = [bool]($sp -and $approved -contains $sp.id)
Step 'Approved client app' $isApproved $true { G POST "$rdBase/approvedClientApps" @{ id = $sp.id; displayName = $ea.displayName } }

# 5 client secret (only with -NewSecret); value goes to the env var of this session, never to output
if ($NewSecret) {
    $var = $ea.secretEnvVar; if (-not $var) { throw 'entraApp.secretEnvVar missing in config' }
    $months = if ($ea.secretMonths) { [int]$ea.secretMonths } else { 6 }
    if ($dryRun) { $log.Add([pscustomobject]@{ Action = 'WouldCreate'; Item = 'Client secret'; Current = ''; Desired = "-> `$env:$var, $months months" }) }
    else {
        $pw = G POST "v1.0/applications/$($script:app.id ?? $app.id)/addPassword" @{ passwordCredential = @{ displayName = "$($ea.displayName) $(Get-Date -Format yyyy-MM-dd)"; endDateTime = (Get-Date).AddMonths($months).ToUniversalTime().ToString('o') } }
        Set-Item -Path "env:$var" -Value $pw.secretText
        $log.Add([pscustomobject]@{ Action = 'Create'; Item = 'Client secret'; Current = ''; Desired = "keyId $($pw.keyId), until $($pw.endDateTime) -> `$env:$var" })
        $pw = $null
    }
}

Disconnect-MgGraph | Out-Null
$log | ForEach-Object { [pscustomobject]@{ Action = $_.Action; Item = $_.Item; Change = $(if ($_.Action -eq 'NoChange') { '' } else { "'$($_.Current)' -> '$($_.Desired)'" }) } } |
    Format-Table -AutoSize -Wrap | Out-String -Width 240 | Write-Host
$n = @($log | Where-Object Action -ne 'NoChange').Count
Write-Host ($dryRun ? "Dry run: $n change(s) planned, nothing changed." : "$n change(s) applied.")
if ($script:app -or $app) { Write-Host "Client app id (for the NetScaler OAuth action and AzureSSOnClientId): $(($script:app ?? $app).appId)" }
