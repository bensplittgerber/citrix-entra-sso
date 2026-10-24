# End-to-end deployment

From an empty hypervisor to an Entra SSO launch without FAS: a NetScaler VPX, Gateway with OIDC to Entra (optional
mTLS), StoreFront store, Broker site. Every step has a dry run (`-WhatIf`) and a way back.

This repository adds the Entra SSO parts. The NetScaler itself is built and configured with the companion
repositories; clone them side by side:

```
src/
├── citrix-entra-sso/        this repository
├── netscaler-nitro/         JSON -> NITRO deployment with journal / undo
└── netscaler-vpx-deploy/    VPX on ESXi (optional - any NetScaler 14.1 works)
```

## Versions

| Component | Minimum | Notes |
|---|---|---|
| citrix-entra-sso | v1.1.0 | `netscaler/` object files, `Set-BrokerSiteEntraSso.ps1` |
| [netscaler-nitro](https://github.com/bensplittgerber/netscaler-nitro) | v1.2.0 | look-up before add, journal and undo; all resources used here are generic NITRO resources |
| [netscaler-vpx-deploy](https://github.com/bensplittgerber/netscaler-vpx-deploy) | v1.0.0 | only for a new VPX on standalone ESXi |
| NetScaler | 14.1 (tested build 73.46) | nFactor, OAuth action with PKCE |
| CVAD (Delivery Controller, StoreFront, VDA) | 2607 LTSR | see [README](../README.md#scope) |
| PowerShell | 7.2 on the admin machine | Windows PowerShell remoting endpoint on the Delivery Controller and StoreFront server |
| Microsoft Graph PowerShell | `Microsoft.Graph.Authentication` | Entra scripts |

The release notes of every citrix-entra-sso version name the repository versions it was validated with.

## Before you start

- DNS: `gatewayUrl` (e.g. `gateway.example.org`) -> Gateway VIP; the NetScaler resolves `login.microsoftonline.com`,
  the StoreFront server and the Delivery Controllers.
- Port **443** for the Gateway. Hybrid launches (browser -> Workspace app) fail on any other port: the Citrix Web
  Extension store URL pattern has no port.
- A config file `config/<name>.local.json` from [config/example.json](../config/example.json) (git-ignored). All
  scripts read it.
- Gateway certificate from a public CA. Let's Encrypt: the NetScaler must send the full chain up to **Root YR
  cross-signed by ISRG Root X1**; managed clients need `ISRG Root X1` in the machine root store (Workspace app checks
  the chain with CryptoAPI, browsers do not) - see [troubleshooting](troubleshooting.md).
- Secrets: the nsroot (or NITRO user) credential comes from `Get-Credential`; the Entra client secret only lives in
  `$env:OIDC_ENTRASSO_CLIENT_SECRET` of one PowerShell session. Nothing goes on a command line or into a file.

## 1. VPX (netscaler-vpx-deploy)

Skip this step for an existing NetScaler 14.1.

```powershell
cd ..\netscaler-vpx-deploy
./vmware/Deploy-NsVpx.ps1 -EsxHost esx01.example.org -OvfPath '[datastore1] iso/NSVPX-ESX-14.1-xx.xx_nc_64.ovf' `
    -VmName ns01 -Datastore datastore1 -Nsip 192.0.2.10 -Gateway 192.0.2.1 -Snip 192.0.2.11 `
    -DnsServer 192.0.2.53 -NtpServer 192.0.2.123 -ExtraConfig .\features.cli -NoProxy -WhatIf
```

`features.cli` (first-boot lines, no secrets):

```
enable ns feature SSL SSLVPN AAA REWRITE LB
enable ns mode USNIP L3 FR Edge
```

The script pins the management key on first contact and prints it - keep it for `-PinnedPublicKey` below.
Details: netscaler-vpx-deploy `docs/vmware.md`.

## 2. Base configuration and Gateway certificate (netscaler-nitro, ACME client)

From netscaler-nitro (copy the examples to `configs/` and replace the placeholders):

| File | When |
|---|---|
| `examples/00-prereq.json` | always: host name, DNS, NTP, `set ssl parameter -defaultProfile ENABLED` (the SSL profiles below need it) |
| `examples/02-lb-storefront.json` | optional: StoreFront load balancing (then `wihome` in step 4 points at the LB) |
| `examples/06-callback.json` | with mTLS: separate callback vserver, StoreFront cannot present a client certificate |

Features `SSL SSLVPN AAA REWRITE` must be on (first-boot `-ExtraConfig` above, or an `nsfeature` step from
netscaler-nitro `templates/objects-template.json`).

Gateway certificate, certkey name `gateway_example_org` (or change it in `11-entra-sso-gateway.json`):
- an ACME client that installs and renews the certkey on the NetScaler (the bindings in step 4 then report
  `[EXISTS]` when the client already bound it), or
- [netscaler/09-entra-sso-gateway-cert.json](../netscaler/09-entra-sso-gateway-cert.json) with
  `Deploy-NsCertificates.ps1` (files in `certs/`, git-ignored).

## 3. Entra (this repository)

```powershell
./scripts/New-EntraSsoClientApp.ps1 -ConfigFile ./config/prod.local.json -WhatIf
./scripts/New-EntraSsoClientApp.ps1 -ConfigFile ./config/prod.local.json -NewSecret   # secret -> $env:OIDC_ENTRASSO_CLIENT_SECRET
./scripts/New-EntraSsoConditionalAccess.ps1 -ConfigFile ./config/prod.local.json -WhatIf  # report-only until -Enforce
```

Write the new app id into `clientAppId` of the config. **Keep this PowerShell session open** for step 4: the secret
exists only in its environment.

## 4. NetScaler Entra SSO objects (this repository + netscaler-nitro)

Copy the object files and replace the placeholders (`netscaler/*.local.json` is git-ignored):

| Placeholder in `netscaler/*.json` | Value |
|---|---|
| `"nsip": "https://192.0.2.10"` | NSIP or management SNIP |
| `<tenant-id>`, `<client-app-id>` | `tenantId`, `clientAppId` of the config |
| `192.0.2.17` (vpnvserver `ipv46`) | Gateway VIP (DNS of `gatewayUrl`), port stays 443 |
| `https://sf01.example.org/Citrix/StoreWeb`, `https://sf01.example.org` | StoreFront (or its LB) + `storeWebVirtualPath` |
| `https://ddc01.example.org` (STA) | the Delivery Controllers of `storeFront.staUrls` (one binding each) |
| `gateway_example_org` | Gateway certkey |
| `client_ca_root`, `client_ca_issuing` + files | mTLS only: your client CA |

| File | Script | Content |
|---|---|---|
| [10-entra-sso-aaa.json](../netscaler/10-entra-sso-aaa.json) | `Deploy-NsObjects.ps1` | OAuth action (explicit endpoints, no metadata / userinfo URL, user name `oid`, PKCE, RS256), policy label, factor 1 `NO_AUTHN`, AAA vserver, authentication profile |
| [11-entra-sso-gateway.json](../netscaler/11-entra-sso-gateway.json) | `Deploy-NsObjects.ps1` | SSL + HTTP profile, session policy (StoreFront, SSO), rewrite `X-Citrix-OIDC-Access-Token`, Gateway vserver on 443 (ICA only), STA, certificate |
| [12-entra-sso-mtls-certs.json](../netscaler/12-entra-sso-mtls-certs.json) | `Deploy-NsCertificates.ps1` | optional: client CA certkeys |
| [12-entra-sso-mtls.json](../netscaler/12-entra-sso-mtls.json) | `Deploy-NsObjects.ps1` | optional: CA bindings, SSL profile `clientCert Mandatory`, factor 1 rule `CLIENT.SSL.CLIENT_CERT.EXISTS` |
| [13-client-crl.cli](../netscaler/13-client-crl.cli) | NetScaler CLI | optional: CRL of the client issuing CA, `crlCheck Mandatory` ([client CA](client-ca.md)) |

In the session of step 3:

```powershell
$nitro = '..\netscaler-nitro\scripts'
$pin   = 'sha256//<management key pin>'
$cred  = Get-Credential nsroot
& "$nitro\Invoke-NsDeployment.ps1" -ConfigFile .\netscaler\10-entra-sso-aaa.local.json, .\netscaler\11-entra-sso-gateway.local.json `
    -Secret OIDC_ENTRASSO_CLIENT_SECRET -Credential $cred -PinnedPublicKey $pin -NoProxy -WhatIf
# then the same line without -WhatIf; journals land in netscaler-nitro\scripts\journals
```

`-Secret` only prompts (masked) if the variable is not set, so a secret from step 3 is reused as it is.

Optional mTLS:

```powershell
& "$nitro\Deploy-NsCertificates.ps1" -ConfigFile .\netscaler\12-entra-sso-mtls-certs.local.json -Credential $cred -PinnedPublicKey $pin -NoProxy
& "$nitro\Deploy-NsObjects.ps1" -ConfigFile .\netscaler\12-entra-sso-mtls.local.json -Credential $cred -PinnedPublicKey $pin -NoProxy
Remove-Item Env:OIDC_ENTRASSO_CLIENT_SECRET
```

Check on the NetScaler: `show vpn vserver gw_example_entrasso` (UP, STA UP after ~1 minute),
`show authentication vserver aaa_entrasso`.

## 5. StoreFront (this repository)

```powershell
./scripts/Set-StoreFrontEntraSso.ps1 -ConfigFile ./config/prod.local.json -WhatIf
./scripts/Set-StoreFrontEntraSso.ps1 -ConfigFile ./config/prod.local.json
```

Store, Web Receiver (modern UI), authentication protocols, Entra ID settings, Entra SSO launch option, Gateway
registration with the callback URL.

## 6. Broker site (this repository)

```powershell
./scripts/Set-BrokerSiteEntraSso.ps1 -ConfigFile ./config/prod.local.json -WhatIf
./scripts/Set-BrokerSiteEntraSso.ps1 -ConfigFile ./config/prod.local.json
```

Sets `AzureSSOnClientId`, `AzureSSOnAuthorizeUrl` (`https://login.microsoftonline.com/<tenant-id>/`) and
`AzureSSOnRedirectUrl` (Store Web URL with trailing slash). The values are **site-wide**: one Entra SSO store origin
per site. The first output line is the `Set-BrokerSite` command with the previous values.

## 7. Check and test

```powershell
./scripts/Export-EntraSsoConfig.ps1 -ConfigFile ./config/prod.local.json
```

All checks `OK`, then from a test client (user in the Conditional Access group, device with `ISRG Root X1` for
Let's Encrypt):

| Test | Without mTLS | With mTLS |
|---|---|---|
| HTML5 launch (`https://gateway.example.org`) | desktop, no second sign-in | certificate prompt, then the same |
| Hybrid launch (Web Extension -> Workspace app) | desktop, no second sign-in | same |
| No client certificate | - | TLS connection reset, no login page |

On failure: [troubleshooting](troubleshooting.md) (VDA signature `0xC0048422`, user name not an oid, Web Extension
site access, port, chain).

## Way back

Reverse order; each step only removes what it created.

| Step | Undo |
|---|---|
| 6 Broker | `Set-BrokerSite ...` line printed by `Set-BrokerSiteEntraSso.ps1` |
| 5 StoreFront | not automated: remove the store / Gateway registration in the console or with `Remove-STF*` |
| 4 mTLS | `set authentication policy auth_pol_entrasso_factor1 -rule true` and `set ssl vserver gw_example_entrasso -sslProfile ssl_prof_entrasso_fe` (the two `PUT` steps are `[MANUAL]` for undo), then `Undo-NsObjects.ps1 -Journal <12 journal>` |
| 4 Gateway, AAA | `Undo-NsObjects.ps1 -Journal <11 journal>`, then `<10 journal>` (the authentication profile cannot be removed while the Gateway uses it) |
| 3 Entra | delete the Client application / Conditional Access policy in Entra (not automated) |
| 1-2 | netscaler-nitro journals of the base files; a lab VPX is simply deleted |
