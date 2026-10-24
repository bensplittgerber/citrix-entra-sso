# Client certificate authority for the mTLS Gateway (step-ca, YubiKey PIV)

Optional part of the setup: the user certificates for `clientCert Mandatory` on the Gateway
(`netscaler/12-entra-sso-mtls*.json`). The Gateway only lets a TLS connection through when the client presents a
certificate of this CA from a smart card; Entra SSO itself does not need the CA (no FAS, no certificate logon on the
VDA).

| Piece | Choice |
|---|---|
| CA | dedicated [step-ca](https://smallstep.com/docs/step-ca/) instance `step-ca-client`, own root, issues **clientAuth only** |
| Root | EC P-256, 10 years, key **offline** after setup |
| Issuing CA | EC P-256, 5 years, pathLen 0, signs user certificates and the CRL |
| Approval | one JWK provisioner (`client-admin`): the admin creates a one-time token per user = the approval |
| Key | generated **on the YubiKey** (PIV, Windows minidriver), never leaves it; slot 9a when free |
| Leaf | CN = UPN, SAN email = UPN, SAN UPN otherName, KU digitalSignature, EKU clientAuth, CDP `http://pki.example.org/client/crl`, 90 days |
| Revocation | CRL: regenerated every 24 h and on revoke, valid 72 h, published over HTTP; Gateway `crlCheck Mandatory`. No OCSP (step-ca has no responder) |
| Renewal | disabled on the CA; renewal = re-enrollment with a new token and a new key |

Lab-tested with YubiKey 5 NFC (fw 5.1.2) and 5C Nano (fw 5.7.4), step-ca 0.30.2, step CLI 0.31, NetScaler 14.1.

## Why a dedicated CA

- A CA that also issues **server** certificates (serverAuth + clientAuth, often over ACME) cannot be the Gateway's
  client CA: every server certificate it ever issued would pass the client certificate check.
- The same applies to a later cloud trust anchor (Entra certificate-based authentication, Okta Smart Card IdP): issuer
  or policy binding rules set protection levels, they do not exclude certificates of a trusted CA. Separation has to
  be the trust anchor itself.
- No ACME, no remote administration (`enableAdmin: false`): `ca.json` is the only source of truth.
- Renewal disabled: a stolen soft certificate could otherwise extend itself with `step ca renew`.

An existing AD CS enterprise CA works too (dedicated issuing CA, smart card logon template, Enrollment Agent on
behalf). This page covers step-ca.

## 1. CA setup (Docker host, run by the administrator)

Files: [`pki/step-ca-client/`](../pki/step-ca-client/) - `ca.json.example`, `client-auth.tpl`,
`compose.override.example.yml`, `nginx-client-crl.conf`. Replace `example.org`, the name policy (`@example.org`)
and the CRL URL first; the CDP in the template and `crl.idpURL` must be the same URL.

Do **not** use the image's `DOCKER_STEPCA_INIT_*` auto-init: it prints the generated provisioner password into
`docker logs`. Without `ca.json` and without init variables the container refuses to start (safe failure).

1. Folders (uid 1000 = `step` in the image):
   ```bash
   cd /srv/pki
   sudo install -d -o 1000 -g 1000 -m 750 step-client
   sudo install -d -o 1000 -g 1000 -m 700 step-client/secrets step-client/db
   sudo install -d -o 1000 -g 1000 -m 755 step-client/certs step-client/config step-client/templates
   sudo install -o 1000 -g 1000 -m 644 ca.json.example step-client/config/ca.json
   sudo install -o 1000 -g 1000 -m 644 client-auth.tpl step-client/templates/client-auth.tpl
   ```
2. Three passwords, masked, one per file (never leave a prompt empty - step would generate and print one). Use three
   different random passwords of 20+ characters from the password manager: the provisioner key is stored encrypted
   in `ca.json`, a short password can be cracked offline and allows certificates for any user of the name policy.
   ```bash
   for f in root_password password provisioner_password; do read -rsp "$f: " p; echo; printf '%s\n' "$p" | sudo tee step-client/secrets/$f >/dev/null; done; unset p
   sudo chown 1000:1000 step-client/secrets/*; sudo chmod 600 step-client/secrets/*
   ```
   `password` (issuing key) stays on the host: the entrypoint starts step-ca with `--password-file`.
3. Root and issuing CA (hand-written instead of `step ca init`: own names, root key can leave the host):
   ```bash
   STEP='docker run --rm --user 1000:1000 -v /srv/pki/step-client:/home/step --entrypoint step smallstep/step-ca:0.30.2'
   $STEP certificate create "Example Client Root CA" /home/step/certs/root_ca.crt /home/step/secrets/root_ca_key --profile root-ca --kty EC --crv P-256 --not-after 87600h --password-file /home/step/secrets/root_password
   $STEP certificate create "Example Client Issuing CA" /home/step/certs/intermediate_ca.crt /home/step/secrets/intermediate_ca_key --profile intermediate-ca --kty EC --crv P-256 --not-after 43800h --ca /home/step/certs/root_ca.crt --ca-key /home/step/secrets/root_ca_key --ca-password-file /home/step/secrets/root_password --password-file /home/step/secrets/password
   ```
   No EKU constraint on the issuing CA: step-ca's own TLS certificate (serverAuth) is signed by it and Go enforces
   EKU nesting. The leaf template is the enforcement point.
4. Provisioner `client-admin` into `ca.json` (`step ca provisioner add --ca-config` refuses on a `ca.json` without
   provisioners in 0.30.2). Every step runs only if the previous one worked (`&&`):
   ```bash
   J='docker run --rm -i --user 1000:1000 -v /srv/pki/step-client:/home/step --entrypoint step smallstep/step-ca:0.30.2'
   $J crypto jwk create /home/step/secrets/client-admin.pub.json /home/step/secrets/client-admin.key.json --kty EC --crv P-256 --password-file /home/step/secrets/provisioner_password \
   && $J crypto jose format < step-client/secrets/client-admin.key.json > step-client/secrets/client-admin.key.jwe \
   && cp -a step-client/config/ca.json step-client/config/ca.json.bak-noprov \
   && jq --slurpfile pub step-client/secrets/client-admin.pub.json --rawfile enc step-client/secrets/client-admin.key.jwe \
        '.authority.provisioners = [{"type":"JWK","name":"client-admin","key":$pub[0],"encryptedKey":($enc|rtrimstr("\n")),
          "claims":{"defaultTLSCertDuration":"2160h0m0s","maxTLSCertDuration":"8760h0m0s","disableRenewal":true},
          "options":{"x509":{"templateFile":"/home/step/templates/client-auth.tpl"}}}]' \
        step-client/config/ca.json.bak-noprov > step-client/config/ca.json \
   && jq '.crl, .authority.policy, (.authority.provisioners[] | {name, type, kid: .key.kid, claims, options, enc: (.encryptedKey | split(".") | length)})' step-client/config/ca.json
   ```
   Expected: `client-admin`, JWK, kid set, the claims and template, `enc: 5`. After the first certificate worked:
   `shred -u step-client/secrets/provisioner_password step-client/secrets/client-admin.key.json step-client/secrets/client-admin.key.jwe`.
5. CLI defaults for `docker exec step-ca-client step ...` (the fingerprint is public):
   ```bash
   FP=$($STEP certificate fingerprint /home/step/certs/root_ca.crt)
   printf '{"ca-url":"https://localhost:9000","fingerprint":"%s","root":"/home/step/certs/root_ca.crt","ca-config":"/home/step/config/ca.json"}\n' "$FP" | sudo tee step-client/config/defaults.json
   sudo chown 1000:1000 step-client/config/defaults.json
   ```
6. Root key offline: copy `secrets/root_ca_key` + `root_password` to offline storage, then
   `sudo shred -u step-client/secrets/root_ca_key step-client/secrets/root_password`. Needed again only to re-issue
   the issuing CA.
7. Start (compose block from `compose.override.example.yml`; enrollment port on the LAN IP only, no internet
   forward):
   ```bash
   docker compose up -d step-ca-client && docker compose ps step-ca-client      # (healthy) after ~1 min
   docker exec step-ca-client step ca health
   ```
8. Negative test of the name policy: `docker exec -it step-ca-client step ca certificate someone@other.example /tmp/x.crt /tmp/x.key`
   must be refused (`email name ... not allowed`).

## 2. CRL distribution point (public)

The CDP in every user certificate is fetched by the NetScaler (internal is enough) and, for cloud IdPs that check the
certificate themselves (Entra CBA, Okta Smart Card IdP) or Windows clients outside the LAN, from the **internet**.
Publish it over plain HTTP on port 80 (CRLs are signed; HTTPS for a CDP causes chicken-and-egg problems).

- nginx in front of the CA: [`nginx-client-crl.conf`](../pki/step-ca-client/nginx-client-crl.conf) -
  `location = /client/crl` -> `https://step-ca-client:9000/1.0/crl`, GET/HEAD only, everything else 404. The CA
  itself is never exposed.
- DNS: `pki.example.org` public A -> the WAN address, internal A -> the nginx host. Port forward TCP 80 -> nginx.
- A CRL server outage does not break logons at once: the CRL is valid 72 h and the NetScaler keeps the last copy.
  `crlCheck Mandatory` rejects logons only after the cached CRL's Next Update has passed.

Test from outside the LAN (mobile hotspot, no lab DNS):
```bash
curl -s -m 10 -o c.crl -w '%{http_code} %{content_type}\n' http://pki.example.org/client/crl
openssl crl -inform DER -in c.crl -noout -issuer -lastupdate -nextupdate     # issuer = Example Client Issuing CA
curl -s -o /dev/null -w '%{http_code}\n' http://pki.example.org/              # 404
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://pki.example.org/client/crl   # 403
```

## 3. Enrollment workstation (once)

Windows with the YubiKey Minidriver, `ykman`, `step` (`winget install Smallstep.step`) and PowerShell 7. A
jumphost with RDP smart card redirection works (pick the YubiKey, not the redirected Windows Hello card). Run in
Windows Terminal.

```powershell
step ca bootstrap --context example-client --ca-url https://ca-client.example.org:9444 --fingerprint <sha256 of the client root>
step ca health --context example-client
```

Config file section (next to the other sections of `config/example.json`):
```json
"clientCa": {
  "stepContext": "example-client",
  "rootFingerprint": "<sha256 of the client root>",
  "issuerName": "Example Client Issuing CA",
  "crlUrl": "http://pki.example.org/client/crl",
  "provisioner": "client-admin",
  "netscalerCrlName": "crl_client_issuing",
  "renewWithinDays": 21
}
```
End-user PCs need the client root (Trusted Root) and the issuing CA (Intermediate) - by GPO or the script imports
them for the current user.

## 4. Enrollment on behalf (per user)

```powershell
./scripts/Enroll-YubiKeyPiv.ps1 -ConfigFile ./config/my.local.json -CheckOnly            # card, store, expiry
./scripts/Enroll-YubiKeyPiv.ps1 -ConfigFile ./config/my.local.json -Upn user1@example.org
```
1. `certreq -new` with the minidriver: key pair generated on the card, CSR with CN and SAN email = UPN (initial PIN).
2. `step ca token` (masked prompt for the provisioner password) - single use, ~5 minutes, only for this UPN. The
   token never touches the disk; `-TokenFile` if another admin creates it elsewhere.
3. `step ca sign`: the template adds the UPN otherName, EKU clientAuth and the CDP. The script checks SAN, EKU, CDP
   and that the public key equals the CSR's.
4. `certreq -accept`: certificate into the same card container. The slot is found by fingerprint afterwards.

PIN handover **after** the enrollment: the user replaces the initial PIN (`ykman piv access change-pin`, or
Ctrl+Alt+Del -> Change a password). A "change PIN on first use" requirement set before the enrollment can block
`certreq`. A card with a blocked PUK (the minidriver does this on a reset card) is lost after three wrong PINs ->
PIV reset and re-enrollment.

Whoever knows the provisioner password can issue for **any** user of the name policy - handle it like an
Enrollment Agent certificate (password manager, few admins). Self-service enrollment (OIDC provisioner bound to the
signed-in Entra user) is a possible later step.

## 5. NetScaler

1. `netscaler/12-entra-sso-mtls-certs.json` (netscaler-nitro `Deploy-NsCertificates.ps1`): `client_ca_root`,
   `client_ca_issuing` (linked) - copy the public certificates `step-client/certs/root_ca.crt` and
   `intermediate_ca.crt` to `certs/client-ca-root.crt` and `certs/client-ca-issuing.crt` (git-ignored) first.
2. `netscaler/12-entra-sso-mtls.json`: SSL profile `clientCert Mandatory`, both CA certs bound, certificate factor.
3. [`netscaler/13-client-crl.cli`](../netscaler/13-client-crl.cli) (CLI): CRL file first, then HTTP refresh daily,
   then the issuing CA binding with `crlCheck Mandatory`. Check: `show ssl crl crl_client_issuing` -> Valid, Last
   Update Successful, revoked serials listed.

## 6. Revocation

```powershell
step ca revoke <serial in decimal> --context example-client --reason "keyCompromise"    # or superseded, cessationOfOperation
```
step-ca writes a new CRL at once (`generateOnRevoke`). The NetScaler fetches it daily at 03:00 - for a lost card do
it now: `set ssl crl crl_client_issuing -interval NOW` and check that the serial is listed. A logon with the revoked
certificate then fails in the TLS handshake (connection reset, no logon page). The enrollment script prints the
exact `revoke` commands (decimal serial) for superseded certificates.

## 7. Renewal

Renewal is disabled on the CA, so every certificate is renewed by **re-enrollment**: before the 90 days end, run the
script again with the user's card (new key, new token); then, in this order:
1. test the new certificate on the Gateway (the browser picker shows "valid from" to tell old and new apart),
2. revoke the old one (`--reason superseded`), refresh the CRL on the NetScaler, negative test with the old one,
3. delete the old certificate from the card (`ykman piv certificates delete <slot>`),
4. `-CleanupStore` on every PC the card was used on (certificate propagation never removes old copies).

`-CheckOnly` lists the certificates on the card with the days left and marks those within `renewWithinDays`.
step-ca's open-source edition keeps no searchable inventory, so keep your own list (UPN, serial, expiry) from the
enrollment output, or plan renewals by cohort.

## Limits

- **No OCSP**: step-ca has no OCSP responder; revocation reaches the Gateway with the next CRL fetch.
- **Identity gap**: the Gateway takes the user name from the certificate (UPN otherName), Entra signs in whoever logs
  on at Entra. The two are not compared (see [ROADMAP](ROADMAP.md), v1.0.x).
- **Enrollment on Windows only** (minidriver + certreq). macOS users enroll on a Windows jumphost or VDI.
- Re-enrollment inside an HDX session (card through Citrix smart card redirection) is not verified.
- Native Workspace app cannot add an account on a Gateway that requires a client certificate (see
  `12-entra-sso-mtls.json`).
