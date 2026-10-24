# Changelog

## Unreleased (v1.1.0)

End-to-end deployment with the companion repositories (ROADMAP v1.1). Not yet validated on a fresh VPX.

### Added
- `netscaler/` object files for netscaler-nitro (>= v1.2.0), from the tested lab Gateway, placeholders only:
  - `10-entra-sso-aaa.json`: OAuth action to Entra with explicit endpoints (no `metadataurl` / `userinfourl`),
    user name `oid`, PKCE, RS256; policy label; factor 1 `NO_AUTHN`; non-addressable AAA vserver; authentication
    profile.
  - `11-entra-sso-gateway.json`: Gateway vserver on 443 (ICA only), SSL and HTTP (WebSocket) profile, session
    policy to the StoreFront store with SSO, rewrite `X-Citrix-OIDC-Access-Token` = `AAA.USER.ATTRIBUTE("accesstoken")`
    on `gatewayauth/login` / `citrixagbasic/authenticate`, STA, certificate bindings.
  - `12-entra-sso-mtls.json` + `12-entra-sso-mtls-certs.json` (optional): client CA certkeys and bindings, SSL
    profile `clientAuth ENABLED` / `clientCert Mandatory`, factor 1 rule `CLIENT.SSL.CLIENT_CERT.EXISTS`.
  - `09-entra-sso-gateway-cert.json`: Gateway certificate with the Let's Encrypt chain up to Root YR cross-signed
    by ISRG Root X1 (when no ACME client installs it).
- `scripts/Set-BrokerSiteEntraSso.ps1`: idempotent `AzureSSOnClientId`, `AzureSSOnAuthorizeUrl`,
  `AzureSSOnRedirectUrl` from the config file over remoting to the Delivery Controller, `-WhatIf`, prints the
  previous values as a `Set-BrokerSite` command, reports `AzureSSOnResourceAppId`.
- `docs/deployment.md`: runbook from the VPX (netscaler-vpx-deploy) over base config and certificate
  (netscaler-nitro, ACME client), Entra, NetScaler, StoreFront and Broker to the export check; minimum versions;
  way back per step.

### Changed
- `.gitignore`: `netscaler/*.local.json` and `certs/`.

## v1.0.1 - 2026-10-24

Documentation only, no script changes.

### Added
- `docs/img/architecture-overview.svg`: overview diagram with the 8 logon steps (HTTPS, ICA/HDX through the Gateway,
  Entra token flow incl. the Web Extension -> Workspace app handoff), no vendor logos.
- `docs/architecture.md`: detailed diagram and the 8 steps with where each one breaks.
- Client experience screenshots (redacted): hybrid desktop, HTML5 session, smart card PIN for the HDX connection,
  connection reset without client certificate.

### Changed
- README restructured: architecture and client experience first, the one-store-per-site limitation below.
- README: validated scope note - HTML5 and hybrid browser-to-Workspace-app launches with mandatory NetScaler mTLS and
  FAS-free Entra SSO; direct native Workspace app store enrollment through an mTLS-only Gateway is not supported.

## v1.0.0 - 2026-10-24

First release. Entra SSO without FAS on-premises (CVAD 2607 LTSR): NetScaler Gateway (OIDC to Entra, optional
mTLS) -> StoreFront -> Entra hybrid joined VDAs. Verified end to end in a lab.

### Added
- `scripts/Export-EntraSsoConfig.ps1`: read-only export of Entra (Client app, Citrix Resource app, consent, RDS
  protocol, approved client apps, device group), Broker site and StoreFront settings as JSON, with checks (redirect
  URL with trailing slash, authorize URL, client id, XML trust, logon type, Entra SSO on the store, no FAS, Gateway
  callback, SPA / ctxaadsso redirect URIs, single tenant).
- `scripts/Set-StoreFrontEntraSso.ps1`: idempotent store setup (`-WhatIf`): authentication service, store and farm,
  Web Receiver with the modern UI, exact authentication protocols, Entra ID settings, Entra SSO launch option,
  optional Gateway registration, web authentication methods and plug-in assistant.
- `scripts/New-EntraSsoClientApp.ps1`: idempotent Entra Client application (single tenant, exact Web / SPA /
  ctxaadsso redirect URIs, permissions, admin consent, RDS protocol and approved client app on the Citrix Resource
  app); a new client secret only into an environment variable.
- `scripts/New-EntraSsoConditionalAccess.ps1`: dedicated Conditional Access policy (group-scoped, phishing-resistant
  MFA or MFA, optional sign-in frequency), report-only unless `-Enforce`. Not yet run against a tenant.
- `config/example.json` with placeholders; real values in git-ignored `*.local.json`.
- `docs/troubleshooting.md`: VDA failure signature (CloudAP `0xC0048422` after a 31 s wait), client matrix,
  NetScaler OIDC (user name `oid`, no userinfo endpoint), modern UI requirement, mTLS Gateway (verified with
  `clientCert Mandatory`), Local Network Access, TLS-inspecting proxies, Citrix Web Extension site access in Edge,
  Web Extension and custom ports, Let's Encrypt chain for native Workspace app (BYOD).
- `docs/ROADMAP.md`: v1.1 idea - several Entra SSO stores per site via a NetScaler response rewrite.

### Known limitations
- One Entra SSO store origin (Gateway URL + store + tenant) per Citrix site (`AzureSSOn*` are site-wide).
- Hybrid launches need the store on port 443 (Citrix Web Extension 26.1.6 store URL pattern has no port).
- Native Workspace app cannot add an account on a Gateway that requires a client certificate.
