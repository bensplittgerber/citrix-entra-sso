# Changelog

## Unreleased (v1.2.0)

Client certificate authority for the optional mTLS Gateway (ROADMAP v1.2). Lab-verified: step-ca client CA,
enrollment onto YubiKey PIV (5 NFC fw 5.1.2, 5C Nano fw 5.7.4), CRL check on the Gateway, revocation, public CRL.

### Added
- `docs/client-ca.md`: dedicated step-ca client CA (clientAuth only, own root, key offline, name policy, renewal
  disabled), setup without auto-init, public CRL distribution point over HTTP, enrollment on behalf with a one-time
  token, NetScaler CRL, revocation, renewal by re-enrollment, limits.
- `pki/step-ca-client/`: `ca.json.example` (CRL every 24 h and on revoke, valid 72 h), `client-auth.tpl` (CN = SAN
  email = UPN otherName, EKU clientAuth, CDP), `compose.override.example.yml`, `nginx-client-crl.conf` (GET/HEAD only).
- `scripts/Enroll-YubiKeyPiv.ps1`: enrollment on behalf - key generated on the YubiKey (minidriver, `certreq`), token
  from `step ca token` in memory only, checks SAN / EKU / CDP / public key, finds the slot by fingerprint, prints the
  revoke and CRL refresh commands for superseded certs, PIN handover; `-CheckOnly` (card inventory with days left),
  `-RenewWithinDays`, `-CleanupStore` (stale revoked/expired copies in CurrentUser\My).
- `netscaler/13-client-crl.cli`: CRL `crl_client_issuing` (file first, then daily HTTP refresh) and `crlCheck
  Mandatory` on the issuing CA (unbind + bind: a second bind fails with "Resource already exists").
- `config/example.json`: `clientCa` section.

### Changed
- `New-EntraSsoConditionalAccess.ps1`: `includeAllUsers: true` as an explicit opt-in for All users (instead of
  `includeGroups`; both together are refused); the user scope is part of the NoChange comparison. First run against a
  tenant (lab, 2026-10-25): policy created and enforced - All users, Citrix-Workspace-Resource, phishing-resistant
  MFA, sign-in frequency 1 h. Verified with a W11 hybrid launch through the mTLS Gateway: after the sign-in frequency
  the launch pop-up asks to sign in again ("Your organizational policy requires you to sign in again after a certain
  time period"). Entra offers the account's default method first (password, which alone does not satisfy the
  strength) and then Windows Hello; "Sign in another way" goes straight to a phishing-resistant method. A second
  launch within the hour needed no prompt. Also verified on macOS with the enforced policy: smart card (YubiKey PIV)
  for the mTLS Gateway, FIDO2 security key for the Entra sign-in.
- README: the note that the Conditional Access script was never run against a tenant is removed.

Not included: OCSP (step-ca has no responder), self-service enrollment, enrollment on macOS.

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
  way back per step. Screenshot of the Gateway deploy (`docs/img/nitro-deploy-gateway.webp`).

### Changed
- `.gitignore`: `netscaler/*.local.json` and `certs/`.
- `11-entra-sso-gateway.json`: note that NetScaler 14.1 binds the built-in cache policies itself on a new Gateway
  vserver (the six bindings report `[EXISTS]`), seen in the validation on a lab VPX.

### Fixed
- `Set-StoreFrontEntraSso.ps1`: a new Gateway with an empty `storeFront.gatewaySnip` failed with "Invalid IPV4
  Subnet Address" (`Add-STFRoamingGateway -SubnetIPAddress ''`). The SNIP is now passed only when set (found in the
  v1.1 validation).

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
