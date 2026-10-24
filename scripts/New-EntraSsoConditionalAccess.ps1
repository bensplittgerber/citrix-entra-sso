#Requires -Version 7.2
<#
.SYNOPSIS
    Idempotent dedicated Conditional Access policy for Citrix Entra SSO: phishing-resistant MFA (built-in
    authentication strength), scoped to a user group, created in report-only mode unless -Enforce.

.DESCRIPTION
    Microsoft Graph only. Desired state from the config section "conditionalAccess" (see config/example.json):
      - displayName, includeGroups (names, resolved to ids; required - the script never targets all users),
        excludeUsers (UPNs, e.g. break-glass accounts), applications ("resource", "client" or app ids)
      - grant: built-in authentication strength - 'phishingResistant' (default, id ...0004) or 'mfa' (any MFA, ...0002)
      - optional sign-in frequency: signInFrequencyHours, or signInFrequency = 'everyTime' (re-authenticate every time)
    Targets: Citrix documents (CVAD 2607, Entra SSO) to apply policies to the Citrix Resource application
    (Citrix-Workspace-Resource) only, not to the Client application. The default is therefore "resource". Adding
    "client" also covers the NetScaler OIDC login when the Client app doubles as the Gateway's OIDC app - a lab
    decision to test, not the Citrix recommendation.
    State: report-only (enabledForReportingButNotEnforced) by default; -Enforce switches the policy to enabled.

.EXAMPLE
    ./scripts/New-EntraSsoConditionalAccess.ps1 -ConfigFile ./config/dev.local.json -WhatIf
.EXAMPLE
    ./scripts/New-EntraSsoConditionalAccess.ps1 -ConfigFile ./config/dev.local.json -Enforce
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ConfigFile,
    [switch] $Enforce
)

$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw -LiteralPath $ConfigFile | ConvertFrom-Json
$ca = $cfg.conditionalAccess
if (-not $ca.displayName) { throw "conditionalAccess.displayName missing in $ConfigFile" }
if (-not @($ca.includeGroups).Count) { throw 'conditionalAccess.includeGroups is empty - refusing to target all users.' }
$phishingResistant = '00000000-0000-0000-0000-000000000004'

$dryRun = -not $PSCmdlet.ShouldProcess("tenant $($cfg.tenantId)", "configure Conditional Access policy '$($ca.displayName)'")
$scopes = if ($dryRun) { 'Policy.Read.All', 'Directory.Read.All', 'Application.Read.All' }
          else { 'Policy.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'Directory.Read.All', 'Application.Read.All' }
Import-Module Microsoft.Graph.Authentication
Connect-MgGraph -TenantId $cfg.tenantId -Scopes $scopes -NoWelcome

function G([string] $Method, [string] $Uri, $Body) {
    $p = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
    Invoke-MgGraphRequest @p
}
function Sorted($a) { (@($a) | Where-Object { $_ } | Sort-Object) -join ',' }

# resolve names to ids (fail on anything unresolved - a typo must not widen or empty the scope)
$groupIds = @(foreach ($n in $ca.includeGroups) {
        $g = @((G GET "v1.0/groups?`$filter=displayName eq '$n'&`$select=id,displayName").value)
        if ($g.Count -ne 1) { throw "Group '$n' resolved to $($g.Count) objects" }; $g[0].id })
$excludeIds = @(foreach ($u in $ca.excludeUsers) { (G GET "v1.0/users/$([uri]::EscapeDataString($u))?`$select=id").id })
$appIds = @(foreach ($a in @($ca.applications ?? @('resource'))) {
        switch ($a) { 'resource' { $cfg.resourceAppId } 'client' { $cfg.clientAppId } default { $a } } })
if ($appIds -contains '' -or $appIds -contains $null) { throw 'An application placeholder resolved to an empty app id (clientAppId missing?)' }

$state = if ($Enforce) { 'enabled' } else { 'enabledForReportingButNotEnforced' }
# grant: built-in authentication strengths - 'phishingResistant' (default) or 'mfa' (any MFA, e.g. Authenticator push)
$strengthId = switch ($ca.grant ?? 'phishingResistant') {
    'phishingResistant' { $phishingResistant }
    'mfa' { '00000000-0000-0000-0000-000000000002' }
    default { throw "conditionalAccess.grant must be 'phishingResistant' or 'mfa'" }
}
$sifText = if ($ca.signInFrequency -eq 'everyTime') { 'everyTime' } elseif ($ca.signInFrequencyHours) { "$($ca.signInFrequencyHours)h" } else { '-' }
$body = [ordered]@{
    displayName = $ca.displayName; state = $state
    conditions = @{
        users = @{ includeGroups = $groupIds; excludeUsers = $excludeIds }
        applications = @{ includeApplications = $appIds }
        clientAppTypes = @('all')
    }
    grantControls = @{ operator = 'OR'; authenticationStrength = @{ id = $strengthId } }
}
# sign-in frequency: hours (timeBased) or 'everyTime' (re-authentication on every token request)
if ($ca.signInFrequency -eq 'everyTime') {
    $body.sessionControls = @{ signInFrequency = @{ isEnabled = $true; frequencyInterval = 'everyTime' } }
} elseif ($ca.signInFrequencyHours) {
    $body.sessionControls = @{ signInFrequency = @{ isEnabled = $true; type = 'hours'; value = [int]$ca.signInFrequencyHours; frequencyInterval = 'timeBased' } }
}

$pols = @((G GET "v1.0/identity/conditionalAccess/policies?`$filter=displayName eq '$($ca.displayName)'").value)
if ($pols.Count -gt 1) { throw "More than one policy named '$($ca.displayName)' - resolve manually." }
$pol = $pols | Select-Object -First 1

$desired = 'state={0} groups={1} excludeUsers={2} apps={3} strength={4} sif={5}' -f $state, (Sorted $groupIds), (Sorted $excludeIds), (Sorted $appIds), $strengthId, $sifText
$current = if ($pol) {
    $sif = $pol.sessionControls.signInFrequency
    'state={0} groups={1} excludeUsers={2} apps={3} strength={4} sif={5}' -f $pol.state, (Sorted $pol.conditions.users.includeGroups), (Sorted $pol.conditions.users.excludeUsers),
    (Sorted $pol.conditions.applications.includeApplications), $pol.grantControls.authenticationStrength.id,
    $(if (-not $sif.isEnabled) { '-' } elseif ($sif.frequencyInterval -eq 'everyTime') { 'everyTime' } else { "$($sif.value)h" })
} else { '' }

$action = if ($current -ceq $desired) { 'NoChange' } elseif ($dryRun) { if ($pol) { 'WouldUpdate' } else { 'WouldCreate' } } else { if ($pol) { 'Update' } else { 'Create' } }
if ($action -in 'Update', 'Create') {
    if ($pol) { G PATCH "v1.0/identity/conditionalAccess/policies/$($pol.id)" $body | Out-Null } else { G POST 'v1.0/identity/conditionalAccess/policies' $body | Out-Null }
}
Disconnect-MgGraph | Out-Null

[pscustomobject]@{ Action = $action; Policy = $ca.displayName; Current = $current; Desired = $desired } | Format-List | Out-String -Width 240 | Write-Host
if (-not $Enforce) { Write-Host 'Report-only. Check the sign-in logs (Conditional Access, report-only tab) before running with -Enforce.' }
