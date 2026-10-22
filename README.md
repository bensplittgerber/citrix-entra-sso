# citrix-entra-sso

Single sign-on with Microsoft Entra ID to Citrix Virtual Apps and Desktops **without FAS**, on-premises:
NetScaler Gateway (OIDC) -> StoreFront -> Entra hybrid joined VDAs (CVAD 2607 LTSR).

Status: work in progress. Verified end to end in a lab; the PowerShell automation is being built.

## What this repo adds to the Citrix documentation
- **`AzureSSOnRedirectUrl` (Broker site, site-wide) must be the Store Web URL exactly as the browser sees it,
  with a trailing slash**, e.g. `https://gateway.example.org/Citrix/StoreWeb/`. The CVAD 2607 page only says it
  must be a redirect URI of the Client application and lists `ctxaadsso://citrix.aad.redirect` among them.
  With `ctxaadsso://...` as the Broker value every client launch fails: empty `about:blank` pop-up, ~60 s delay,
  then the Windows logon screen. See [docs/troubleshooting.md](docs/troubleshooting.md).
- The SPA redirect URI on the Client application must match that value (with the slash); the native Workspace app
  failed (froze) when only the variant without the slash was registered.
- A failure signature on the VDA that identifies the problem in minutes (CloudAP `0xC0048422` after a 31.4 s wait).

## Scope
| Component | Version tested |
|---|---|
| CVAD / Delivery Controller / StoreFront | 2607 LTSR |
| VDA | 2607 LTSR on Windows Server 2025 (build >= 26100.32230), Entra hybrid joined |
| NetScaler | 14.1 (Gateway with nFactor OIDC to Entra, token rewrite to StoreFront) |
| Workspace app | Windows 2607 (64-bit), macOS 2609 |

Not covered: Citrix DaaS / Citrix Cloud (own Citrix documentation), Entra joined (cloud-only) VDAs on CVAD
(not supported by Citrix on-premises), FAS.

## Layout
| Path | Content |
|---|---|
| `scripts/` | PowerShell: export of the current config, idempotent setup per component, validation |
| `config/` | `example.json` with placeholders; real values go into `*.local.json` (git-ignored) |
| `docs/` | troubleshooting signatures, client matrix, limitations |

## Conventions
Placeholders only (`example.org`, `192.0.2.x`, `<tenant-id>`). No secrets in files or on command lines: client
secrets via masked prompts or `${env:NAME}`. The public Citrix multi-tenant app id `3a510bb1-e334-4298-831e-3eac97f8b26c`
(Citrix-Workspace-Resource) is not a secret.
