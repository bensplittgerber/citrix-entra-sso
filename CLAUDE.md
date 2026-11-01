# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Worum es geht

Entra-ID-SSO für Citrix Virtual Apps and Desktops on-premises **ohne FAS**: NetScaler Gateway (OIDC zu Entra) →
StoreFront → Entra-hybrid-joined VDAs (CVAD 2607 LTSR). Das Repo ist kein Programm, sondern eine Sammlung aus
PowerShell-Skripten, NetScaler-Objektdateien, PKI-Vorlagen und Doku. Es gibt keinen Build, keinen Linter und keine
Tests; geprüft wird mit `-WhatIf` und im Lab gegen echte Systeme.

Öffentliches Repo: alle Inhalte (Skripte, Kommentare, Doku, Commits, CHANGELOG) sind **auf Englisch**. Ausnahme ist
diese `CLAUDE.md`, sie bleibt auf Deutsch (entschieden 2026-10-25).

## Wie die Teile zusammenhängen

Eine Konfigdatei treibt alles: `config/<name>.local.json` (Kopie von `config/example.json`, per `.gitignore`
ausgeschlossen). Jedes Skript in `scripts/` nimmt sie über `-ConfigFile` und liest nur seinen Abschnitt
(`entraApp`, `conditionalAccess`, `storeFront`, `clientCa`) plus die gemeinsamen Felder (`tenantId`, `clientAppId`,
`gatewayUrl`, `storeWebVirtualPath`, …).

Reihenfolge laut `docs/deployment.md` (Schritte 1–7, mit Rückweg):
1. Entra: `New-EntraSsoClientApp.ps1` (`-NewSecret` legt das Secret nur in `$env:OIDC_ENTRASSO_CLIENT_SECRET` der
   laufenden Sitzung ab), `New-EntraSsoConditionalAccess.ps1` (report-only bis `-Enforce`)
2. NetScaler: `netscaler/09-*.json` (Gateway-Zertifikat, entfällt bei ACME), `10-*.json`, `11-*.json` (optional `12-*` mTLS, `13-client-crl.cli` per NetScaler-CLI) werden
   **nicht hier** ausgeführt, sondern vom Nachbar-Repo `../netscaler-nitro` (`Invoke-NsDeployment.ps1`,
   `Deploy-NsObjects.ps1`, `Deploy-NsCertificates.ps1`; ≥ v1.2.0). Format: `{ "nsip", "steps": [ {comment/note} |
   {resource, data} ] }` mit generischen NITRO-Ressourcen. Echte Werte in `netscaler/*.local.json` (ignoriert).
3. StoreFront: `Set-StoreFrontEntraSso.ps1`, Broker-Site: `Set-BrokerSiteEntraSso.ps1`
4. Prüfen: `Export-EntraSsoConfig.ps1` (nur lesend, schreibt nach `exports/`, ignoriert)

Optional mTLS mit eigener Client-CA (step-ca, YubiKey PIV): `pki/step-ca-client/`, `scripts/Enroll-YubiKeyPiv.ps1`,
`docs/client-ca.md`.

Fachlicher Kern, der überall durchschlägt: die `AzureSSOn*`-Werte sind **site-weit** am Broker (eine Gateway-URL +
Store + Tenant pro Citrix-Site); die Redirect-URL ist die Store-Web-URL **mit Schrägstrich am Ende** und muss als
SPA-Redirect-URI an der Client-App stehen; Gateway auf Port 443 (Hybrid-Start); NetScaler-OIDC-Benutzername = `oid`.
Details und Fehlerbilder: `docs/architecture.md`, `docs/troubleshooting.md`.

## Muster in den Skripten

Wer ein Skript ändert oder neu schreibt, hält sich an diese Form:
- `#Requires -Version 7.2`, Comment-Based Help (`.SYNOPSIS`, `.DESCRIPTION` mit Soll-Zustand, `.EXAMPLE`)
- `[CmdletBinding(SupportsShouldProcess)]`; `$dryRun = -not $PSCmdlet.ShouldProcess(...)`. Bei Dry-Run nur
  Lese-Scopes bzw. keine Änderung
- idempotent: jeden Wert lesen, mit Soll vergleichen, nur bei Abweichung ändern; Ausgabe als Tabelle mit
  `Action` = `NoChange` / `WouldCreate` / `WouldUpdate` / `Create` / `Update` (Helfer `Step`)
- Entra nur über `Microsoft.Graph.Authentication` + `Invoke-MgGraphRequest` (Helfer `G`), keine weiteren
  Graph-Module
- Broker und StoreFront über `Invoke-Command` auf den Windows-PowerShell-Endpunkt des Servers, Citrix-Snap-ins dort
- vor einer Änderung den alten Zustand als Rückweg-Befehl ausgeben (z. B. `Set-BrokerSite …`)
- Secrets nie auf der Kommandozeile oder in Dateien: maskierte Eingabe oder `${env:NAME}`

Zeilenenden laut `.gitattributes`: `*.ps1` CRLF, `*.json`/`*.md` LF.

## Ausführen

Nur auf einem Admin-Rechner mit PowerShell 7.2 und Zugang zu Tenant, Delivery Controller und StoreFront. Immer
zuerst mit `-WhatIf`, z. B.:

```powershell
./scripts/Set-BrokerSiteEntraSso.ps1 -ConfigFile ./config/lab.local.json -WhatIf
```

Unter macOS (`pwsh` ist installiert) lässt sich nur die Syntax prüfen, nicht die Wirkung. Erwartet: `0` Fehler je Datei.

```bash
pwsh -NoProfile -Command 'foreach($f in Get-ChildItem scripts/*.ps1){$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$null,[ref]$e);"{0}: {1}" -f $f.Name,$e.Count}'
```

## Regeln fürs Repo

- Nur Platzhalter: `example.org`, `192.0.2.x`, `<tenant-id>`, `<client-app-id>`. Keine echten Hostnamen, Tenant-
  oder App-IDs, auch nicht in Screenshots unter `docs/img/`. Die öffentliche Citrix-App-ID
  `3a510bb1-e334-4298-831e-3eac97f8b26c` (Citrix-Workspace-Resource) ist kein Geheimnis.
- Diagramme sind eigene Zeichnungen, keine Hersteller-Grafiken oder Logos.
- Dies ist der Fork `dimi4ik/citrix-entra-sso` (Upstream: `bensplittgerber/citrix-entra-sso`). Commits laufen hier
  unter der lokalen Git-Identität (`git config user.name` / `user.email`). Die Identität
  `Ben Splittgerber <bensplittgerber@users.noreply.github.com>` aus `docs/release.md` gilt nur im Upstream-Repo.
  Bei `gh`-Aufrufen `-R dimi4ik/citrix-entra-sso` setzen, damit nichts im Upstream landet.
- Release-Ablauf: `docs/release.md` (sauberer Baum, CHANGELOG-Abschnitt `## vX.Y.Z - YYYY-MM-DD`, Secret- und
  Klarnamen-Check, annotierter Tag, `gh release create` mit dem CHANGELOG-Abschnitt). Ein veröffentlichter Tag wird
  nie verschoben. Versionen: Patch = Fix/Doku, Minor = neues Skript/Option, Major = Bruch im Config-Layout.
- Neue Erkenntnisse aus dem Lab gehören mit Datum und getesteter Version in CHANGELOG bzw. `docs/troubleshooting.md`;
  geplante Arbeit in `docs/ROADMAP.md`.
