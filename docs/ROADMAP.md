# Roadmap

## v1.0 (released 2026-10-24, docs update v1.0.1)
- Entra SSO without FAS on-premises: NetScaler Gateway (OIDC, optional mTLS) -> StoreFront -> hybrid joined VDAs.
- Scripts: export/check, StoreFront store setup, Entra Client application, dedicated Conditional Access policy
  (phishing-resistant MFA).
- Documented limitations: one Entra SSO store origin (Gateway URL + store + tenant) per Citrix site; hybrid launches
  need the store on port 443.

## Open for v1.0.x
- ~~Run `New-EntraSsoConditionalAccess.ps1` against a tenant~~ done 2026-10-25 (lab): All users, target
  Citrix-Workspace-Resource, phishing-resistant MFA, sign-in frequency 1 h, `-Enforce`; verified with a hybrid launch
  (re-authentication prompt at launch after the sign-in frequency).
- mTLS Gateway: compare the certificate UPN with the Entra `upn` (certificate and Entra user are decoupled).

## v1.1 (released 2026-10-25): end-to-end deployment with the companion repositories
Status: [deployment.md](deployment.md), `netscaler/`, `Set-BrokerSiteEntraSso.ps1`; validated in the lab without the
optional mTLS files (see the note in deployment.md). netscaler-nitro gaps: none blocking with v1.2.0 (all resources are
generic NITRO resources; the two `PUT` steps of the mTLS file are reverted by hand).

Goal: the whole setup from an empty hypervisor to a working Entra SSO launch, scripted, with dry runs and rollback.
This repository adds the Entra SSO specific parts; generic NetScaler tooling stays in its own repositories.

| Step | Repository | What |
|---|---|---|
| 1 VPX | [netscaler-vpx-deploy](https://github.com/bensplittgerber/netscaler-vpx-deploy) | VPX on ESXi, management network, nsroot password, hardening |
| 2 Base config, certificates | [netscaler-nitro](https://github.com/bensplittgerber/netscaler-nitro), an ACME client for the Gateway certificate | network, StoreFront load balancing, callback; Let's Encrypt Gateway certificate with the full chain (Root YR cross-signed by ISRG Root X1) |
| 3 Entra | this repo | `New-EntraSsoClientApp.ps1`, `New-EntraSsoConditionalAccess.ps1` |
| 4 NetScaler Entra SSO | this repo (JSON) + netscaler-nitro | Gateway profile, see below |
| 5 StoreFront | this repo | `Set-StoreFrontEntraSso.ps1` |
| 6 Broker site | this repo | new `Set-BrokerSiteEntraSso.ps1` |
| 7 Check | this repo | `Export-EntraSsoConfig.ps1` |

Planned content:
- `netscaler/` - JSON object files for netscaler-nitro (placeholders, tested objects from the lab):
  - `10-entra-sso-aaa.json`: OAuth action to Entra (endpoints without `metadataUrl` / `userInfoURL`, user name
    field `oid`, PKCE), authentication policy and policy label, authentication profile.
  - `11-entra-sso-gateway.json`: Gateway vServer on 443, session action / policy (StoreFront, STA), rewrite
    `X-Citrix-OIDC-Access-Token`, bindings.
  - `12-entra-sso-mtls.json` (optional): certificate check without user name (`NO_AUTHN`) as factor 1, SSL profile
    with `clientCert Mandatory`, client CA certificates (the CA itself is not part of v1.1).
- `scripts/Set-BrokerSiteEntraSso.ps1`: `AzureSSOnClientId`, `AzureSSOnAuthorizeUrl`, `AzureSSOnRedirectUrl` from
  the same config file, `-WhatIf`, prints the current values as the way back.
- `docs/deployment.md`: the end-to-end runbook with the minimum version of every repository.
- netscaler-nitro: any missing generic resource found on the way (e.g. SSL profile client authentication, rewrite
  bindings on Gateway vServers, certificate links) goes into netscaler-nitro itself (v1.3.0).

Validation: a fresh VPX built only from these steps; HTML5 and hybrid launches with and without mTLS; undo of the
NetScaler part through the netscaler-nitro journal. The release ships with a compatibility table of the repository
versions it was tested with.

## v1.2 (unreleased): client certificate authority for mTLS
- Done: [docs/client-ca.md](client-ca.md) - step-ca client CA, enrollment onto YubiKey PIV
  (`scripts/Enroll-YubiKeyPiv.ps1`), CRL on the Gateway (`netscaler/13-client-crl.cli`) with a public CRL
  distribution point, revocation, renewal by re-enrollment.
- Decided: CRL only - step-ca has no OCSP responder. Renewal stays disabled on the CA.
- Later: self-service enrollment (OIDC provisioner bound to the signed-in Entra user), re-enrollment inside an HDX
  session, enforced PIN change after the enrollment.

## v1.3 (idea): more than one Entra SSO store per site - NetScaler response rewrite (unsupported workaround)
Idea: the site-wide `AzureSSOn*` values travel Broker -> StoreFront (direct) and then StoreFront -> client **inside
the ICA file**, through the Gateway (`.../Resources/LaunchIca/...`; the HTML5 page builds its msal request from the
same content). A response rewrite per Gateway vServer could replace `AzureSSOnClientId`, `AzureSSOnRedirectUrl` and,
for another tenant, `AzureSSOnAuthorizeUrl` with that Gateway's values, so every Gateway/store gets its own Client
application and redirect URL although the site holds only one set.

Prerequisites / risks to verify in the lab:
- ICA response uncompressed at the NetScaler (strip `Accept-Encoding` on the LaunchIca request).
- ICA file signing disabled (default); a signed ICA file breaks with the rewrite.
- VDA / Entra do not check against the site's Client application: CloudAP validates nonce, device and resource;
  Entra checks the approved client app per Resource app -> register every Client application there.
- Another tenant (service provider): that tenant's VDAs hybrid joined to it, Citrix Resource app consented there,
  RDS protocol enabled, approved client app set. The rewrite only changes what the client sees.
- Not supported by Citrix; ICA format or launch flow changes can break it.

Lab test plan: site stays on Gateway A; on Gateway B a response rewrite on LaunchIca to B's Client application and
store URL. Pass = HTML5 (and hybrid) launch with Entra SSO through B **while** A keeps working on the same site.
