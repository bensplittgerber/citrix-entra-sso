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
