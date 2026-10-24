# Roadmap

## v1.0 (in progress)
- Entra SSO without FAS on-premises: NetScaler Gateway (OIDC, optional mTLS) -> StoreFront -> hybrid joined VDAs.
- Scripts: export/check, StoreFront store setup, Entra Client application, dedicated Conditional Access policy
  (phishing-resistant MFA).
- Documented limitation: one Entra SSO store origin (Gateway URL + store + tenant) per Citrix site.

## v1.1 (planned): more than one Entra SSO store per site - NetScaler response rewrite (unsupported workaround)
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
