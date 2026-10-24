# Troubleshooting Entra SSO without FAS

## Failure signature on the VDA (wrong Broker redirect URL)
Per launch, in the VDA event logs (times relative to the ICA connect):

| T | Log | Event |
|---|---|---|
| 0 s | System, TdIca 1004 | connect request from the Gateway SNIP |
| +30 s | System, wdica 3005 | "Auto Client Reconnect (ACR) is disabled when using Azure AD authentication" -> the VDA is in Entra mode |
| +30 s | AAD/Analytic 1143 | CloudAP `GenericCallPkg` call type 9 -> `0x0` (challenge created) |
| +61 s | AAD/Analytic 1143, AAD/Operational 1104 | call type 10 -> **`0xC0048422`** within 1 ms (no client answer to check) |
| +61 s | - | no Winlogon "Authentication started", Windows logon screen |

Entra sign-in logs show **no** request for `Citrix-Workspace-Resource` (interactive or non-interactive).
The AAD Analytic log is off by default and can only be read after disabling it again:
`wevtutil sl Microsoft-Windows-AAD/Analytic /e:true /q:true` ... launch ... `wevtutil sl Microsoft-Windows-AAD/Analytic /e:false`.

Working launch for comparison: ICA-CGP within ~2 s, Winlogon "Authentication stopped. Result 0", no 1104, desktop
in ~10 s.

## Client side
- Pop-up stays `about:blank`; in a hybrid launch the StoreFront page navigates it to
  `ctxaadsso://citrix.aad.redirect?citrixURI=...&ctxStoreTicket=...&msalURI=<Entra authorize URL>`.
- HTML5 client log (Download log in the "Session failure" dialog), repeating every ~30 ms:
  `MSALWrapper.detectInteractionTypeForH5 ... Azure Redirect URL does not match with the store origin` -> `REDIRECT_TO_CTX_HTTPS`.
- Fix: `Set-BrokerSite -AzureSSOnRedirectUrl 'https://<gateway-fqdn>/Citrix/<Store>Web/'`.

## Ruled out along the way (all correct in the failing setup)
Entra Resource app enabled and `isRemoteDesktopProtocolEnabled`, Client app approved, admin consent,
VDA in the target device group, `AzureSSOnResourceAppId = citrix.cloud.com/3a510bb1-...` (matches the SPN
`ms-device-service://citrix.cloud.com/3a510bb1-...`), token rewrite on the Gateway, Citrix Web Extension and native
messaging host, VDA prerequisites. RDP with Entra SSO to the same VDA worked (host side fine).

## Client matrix (lab, 2026-10)
| Client | HTML5 | Hybrid (browser -> Workspace app) | Native Workspace app |
|---|---|---|---|
| Windows 11, Edge / Chrome | OK | OK | OK |
| macOS, Chrome | OK | OK | OK |
| macOS, Safari | OK | **not supported** (Citrix: hybrid only Edge/Chrome + Web Extension) | - |
| iPadOS, embedded web view | not supported (WebKit; also no FIDO2) | - | not tested |

Requirements seen in tests: pop-ups allowed for the store; on macOS browsers the silent Entra request (`prompt=none`)
needs the Entra session cookie (worked with "Stay signed in" (KMSI) enabled; KMSI-off matrix pending).

## NetScaler OIDC action: user name must be the Entra object id
StoreFront (Entra SSO enabled on the store) shows "Cannot complete your request." and logs:
`Entra ID single sign-on failed because the username '<upn>' passed by Citrix Gateway is not an Entra OID (GUID format).
Resolution: In the NetScaler OIDC policy action, set the username field to 'oid'.`
Fix: `set authentication OAuthAction <name> -userNameField oid` (the working reference Gateway used `oid` from the start;
`preferred_username` or `upn` fail).

## Store web site must use the modern UI ("Workspace" experience)
With `userInterfaceExperience experience="ReceiverForWeb"` in the Web Receiver web.config, the store page launches with a
plain ICA download (`Resources/LaunchIca`) and never starts the Entra token flow (no `Tickets/RequestStoreTicket`, no
`ctxaadsso://` handoff, no Entra request). The VDA then shows the failure signature above (Entra mode, 31 s wait,
CloudAP `0xC0048422`). `Add-STFWebReceiverService -ClassicReceiverExperience $false` does not set the modern UI; use
`-WebUIExperence Workspace` (Add, sic) or `Set-STFWebReceiverService -WebUIExperience Workspace`. Found with an Edge
`edge://net-export` log of a hybrid launch (2026-10-23).

## NetScaler OIDC action: no userinfo endpoint
With `-metadataUrl` the OAuth action also takes the Graph `userinfo` endpoint, and the user name field is then read from
the userinfo answer, which has no `oid` -> the user name falls back to the UPN and StoreFront refuses Entra SSO. Configure
the endpoints explicitly (authorization, token, keys, issuer, audience) without `metadataUrl` / `userInfoURL`
(lab 2026-10-23; the working reference Gateway had neither).

## mTLS Gateway in front of the store
nFactor keeps the user name of the first factor. A client certificate factor that sets the user name (UPN from the SAN)
therefore hides the Entra `oid`; use a certificate check without a user name (`-action NO_AUTHN`, rule
`CLIENT.SSL.CLIENT_CERT.EXISTS`) as factor 1. The certificate is still enforced by the SSL profile. Note: certificate
and Entra user are then no longer coupled (add a UPN comparison). Native Workspace app cannot add an account on a
Gateway that requires a client certificate; only browser / hybrid launches.

## Browser launches on the LAN: Local Network Access (Chromium)
On the LAN the Gateway FQDN resolves to a private address. The silent Entra request of the HTML5 client
(`prompt=none`, hidden iframe) returns from `login.microsoftonline.com` to the store URL; Edge/Chrome block that with
`ERR_BLOCKED_BY_LOCAL_NETWORK_ACCESS_CHECKS` (Local Network Access: a public page may not load a private address in
an iframe). msal then falls back to an interactive pop-up, which works -> SSO succeeds, but slower and only with
pop-ups allowed. From outside (Gateway FQDN = public address) the log shows no such block (external test 2026-10-24).

## Clients behind a TLS-inspecting proxy (e.g. Zscaler SSL inspection)
External test through Zscaler (2026-10-24): the store and the Entra part work - HTML5 log `Received AAD token
successfully from MSAL` - but the HDX connection fails: HTML5 log `WebSocket connection failed with error code 1006`,
Edge net-export `WEBSOCKET_UPGRADE_FAILURE` / `ERR_INVALID_RESPONSE` towards the Gateway. This is the proxy, not Entra
SSO. Fix on the proxy side: exclude the Gateway FQDN from SSL inspection (and allow WebSockets). A Gateway that
requires a client certificate (mTLS) cannot work through SSL inspection at all.
