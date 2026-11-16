# Demo proposal: Entra SSO versus native physical smartcard logon without FAS

Status: proposed experiment (2026-11-16), not a new supported feature or release. The v1.2 Entra SSO baseline is unchanged.

## Question

Can a federated NetScaler Gateway (OIDC/SAML) broker a fresh Citrix desktop without FAS, using a physical YubiKey PIV Windows logon credential over native HDX smartcard redirection? Can PIN authorization established for mandatory mTLS be reused at Windows logon? Native smartcard Gateway authentication is the control; the arbitrary federated combination is experimental.

## Architectures

- A — existing Entra SSO: mandatory mTLS → Entra OIDC/FIDO2 or WHfB → StoreFront/Broker → native hybrid launch with Entra token → CloudAP. Existing HTML5 and hybrid baseline remains validated. Direct native Workspace store enrollment through mandatory mTLS remains a limitation.
- B0 — native smartcard Gateway control: certificate authentication → FAS-free StoreFront → native Workspace HDX smartcard redirection → Windows AD smartcard logon / Kerberos PKINIT.
- B1 — experimental federation: mandatory mTLS → independent Keycloak FIDO2 OIDC (or Okta) → FAS-free StoreFront → native HDX → physical PIV Windows logon. Verify resource enumeration and brokered launch first; a successful Gateway login does not establish Windows authentication. No Entra token or FAS alternate path in B.

Use an existing AD CS Windows smartcard logon credential with correct chain, NTAuth, strong AD certificate mapping and reachable revocation information. Do not publish the dedicated mTLS client CA to NTAuth merely for this experiment. Use isolated test store/Gateway and VDA, preserving the working Entra store and site-wide AzureSSOn* settings. A separate site may be needed if isolation cannot be maintained.

## PIN prompt matrix

Distinguish browser mTLS PIV PIN, IdP FIDO2 PIN/touch or WHfB, Workspace HDX TLS PIV PIN and Windows PIV credential provider. PIV and FIDO2 PINs are separate. Existing v1.2 screenshots show a Workspace HDX PIN prompt; retain that evidence.

| Test | Record |
|---|---|
| Cold endpoint, fresh browser/Workspace, new VDA logon | Each prompt and actual Windows logon mechanism |
| Warm browser, fresh Workspace process | Whether authorization crosses process boundaries |
| Warm Workspace, fresh VDA logon | Whether HDX TLS PIN is reused for Windows logon |
| Same approved PIV certificate vs separate PIV certificates/slots | Whether caching is tied to a specific key/container |
| Remove/reinsert key, cache timeout, endpoint lock | Whether cached authorization is invalidated |
| Fresh logon vs disconnected/locked session reconnect | Distinguish logon from session resume |
| Windows and macOS separately | Client/middleware/version dependence |

Record client, middleware, Workspace, VDA, NetScaler versions and effective PIN/SSO policy. Repeat each supported case at least three times. Do not automate PIN injection or weaken security policy. Claim only observed behavior: no extra prompt does not by itself prove PIN caching; distinguish TLS reuse, Windows cached logon, existing session, credential provider or Workspace PIN pass-through. If the mechanism cannot be established, label it unknown. Manual PIN remains passwordless, not seamless SSO.

## Session lifecycle and security tests

- A: reproduce owner-reported physical PIV unlock of an Entra SSO session by selecting the smartcard credential provider and entering PIN. This is not proof of fresh native smartcard logon. Optionally test default credential provider on an isolated VDA without disabling CloudAP/password providers.
- A: optional DeviceTrust real-time smartcard presence/removal detection and approved disconnect action; validate actual client/version support and unavailable posture behavior. HTML5 does not provide equivalent endpoint posture. ATR/vendor alone does not identify a unique key. Native removal policy may not trigger for CloudAP logon.
- B: validate native smartcard logon and removal behavior, reinsertion and reconnect. Demonstrate no FAS issuance and correct broker/Windows identity. Test Gateway user A with Windows smartcard user B: no unauthorized identity switch; any mismatch blocks release.
- Both: missing/untrusted/revoked mTLS certificate denied on new connection after Gateway CRL refresh; Windows logon revocation checked independently. Existing sessions and tokens require separate termination controls. Do not equate login_hint with hard identity binding.
- B: FIDO2-only user without eligible PIV Windows credential cannot use this proposed Windows logon mechanism. A may still serve such users if they satisfy any independently required mTLS credential.
- Optional Keycloak continuity scenario: simulate primary cloud IdP unavailable in isolated lab, verify designated access; local dependencies still required. No broad cloud outage immunity claim.

## Video storyboard (3–5 minutes)

1. Show one YubiKey and two distinct authentication paths, with mandatory mTLS and independent CRL enforcement.
2. A: mTLS, Entra sign-in, hybrid launch without Windows password. Show actual HDX PIN prompt if present. Lock, select smartcard tile, PIN unlock.
3. B: fresh session after federated Gateway sign-in, native HDX launch, show actual PIV prompt count and Windows Kerberos evidence. If no extra PIN, report exact tested conditions; otherwise show manual PIN without claiming SSO.
4. Show verified removal and reconnect behavior, and optional revoked disposable certificate denial.
5. Summarize tradeoffs: A token-based SSO without FAS; B physical smartcard Windows logon without FAS if validated, possible extra PIN, native removal policy, no cloud IdP dependency for Windows logon. Distinguish supported native smartcard control from experimental federation.

Publish only synthetic/redacted evidence, test versions and precise PASS/FAIL/BLOCKED results after review. No tokens, PINs, private hostnames or customer data. Keep existing release unchanged until validation, and re-run A baseline after the isolated experiment.

Related: [client CA](client-ca.md), [troubleshooting](troubleshooting.md), [roadmap](ROADMAP.md), [architecture](architecture.md).
