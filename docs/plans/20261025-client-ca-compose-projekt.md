# Client-CA als eigenständiges Compose-Projekt (Issue #4)

## Überblick

- Die Client-CA für das mTLS-Gateway (`docs/client-ca.md`, `pki/step-ca-client/`) setzt bisher ein fremdes
  Docker-Compose-Projekt („server step-ca + nginx“) voraus, das nirgends veröffentlicht ist. Wer es nicht hat, kann die
  CA nach der Doku nicht aufbauen.
- Ziel (Weg A, entschieden von Dima am 2026-10-25): ein eigenständiges Compose-Projekt
  `pki/step-ca-client/compose.example.yml` mit den Diensten `step-ca-client` und `nginx` in einem eigenen Netz,
  Port 80 nur für `/client/crl`, dazu eine vollständige nginx-Konfiguration. Die Doku beschreibt den Aufbau ab einem
  leeren Docker-Host.
- Die bisherigen Ergänzungsdateien bleiben als **Variante** für alle, die schon ein eigenes Compose-Projekt mit nginx
  auf Port 80 betreiben (Entscheidung Dima, 2026-10-25). Ihre Kommentare werden so umformuliert, dass sie diese
  Voraussetzung offen nennen statt sie stillschweigend anzunehmen.
- Sprache der Repo-Dateien bleibt Englisch (Regel in `CLAUDE.md`); nur dieser Plan ist auf Deutsch.

## Kontext (aus der Erkundung)

Betroffene Dateien (Stand `origin/main`, 23035da):

| Datei | Heute | Künftig |
|---|---|---|
| `pki/step-ca-client/compose.override.example.yml` | Kommentar setzt ein vorhandenes fremdes Compose-Projekt voraus, nur Dienst `step-ca-client` | Variante, Kommentar nennt die Voraussetzungen (nginx im selben Netz, Port 80, Snippet) |
| `pki/step-ca-client/nginx-client-crl.conf` | Kommentar setzt einen vorhandenen Port-80-`server`-Block voraus | bleibt der eine `location`-Block, den beide Wege nutzen; Kommentar neu |
| `pki/step-ca-client/compose.example.yml` | fehlt | neu: `step-ca-client` + `nginx`, eigenes Netz |
| `pki/step-ca-client/nginx-client-crl-server.conf` | fehlt | neu: vollständiger `server`-Block für Port 80, bindet das Snippet ein |
| `docs/client-ca.md` Abschnitt 1 und 2 (Zeilen 34–121) | `/srv/pki` ohne Herkunft, `docker compose up -d step-ca-client` neben fremder `compose.yml`, nginx ohne Herkunft | Docker-Host-Voraussetzungen, Aufbau ab leerem Ordner, Start beider Dienste, Variante in einem Absatz |
| `README.md:122` | „CA config, leaf template, compose, nginx CRL“ | nennt das eigenständige Compose-Projekt |

Nicht betroffen (laut Issue): `ca.json.example`, `client-auth.tpl`, `scripts/Enroll-YubiKeyPiv.ps1`,
`netscaler/13-client-crl.cli`. Der CDP bleibt `http://pki.example.org/client/crl`, bereits ausgestellte Zertifikate
bleiben gültig.

Belegte Fakten, auf die der Plan baut (geprüft 2026-10-25):

- **step-ca 0.30.2, Image `smallstep/step-ca:0.30.2`**: Das Image hat einen eingebauten `HEALTHCHECK`
  (`step ca health`) und läuft als Benutzer `step` (Quelle: `docker/Dockerfile` im Tag v0.30.2 von
  smallstep/certificates). Die bisherige Doku-Erwartung „(healthy) after ~1 min“ stimmt also auch ohne eigenen
  Healthcheck in der Compose-Datei.
- **step-ca könnte die CRL auch selbst über HTTP ausliefern** (`insecureAddress`, Routen nur `/crl` und `/1.0/crl`;
  Quelle: `ca/ca.go:247–249`, `:392–398` in v0.30.2 und step-ca-Doku „Production considerations“, CRL-Beispiel mit
  `"insecureAddress": ":9001"`). Bewusst **nicht** genutzt (Dima, 2026-10-25): Der Pfad wäre nicht mehr
  `/client/crl`, `ca.json.example` und `client-auth.tpl` müssten sich ändern, ausgestellte Zertifikate zeigten ins
  Leere, und der CA-Prozess hinge direkt im Internet. In der Doku steht das als ein Satz „Alternative“.
- **Docker, eingebetteter DNS**: Container in einem selbst angelegten Netz (user-defined network) erreichen sich über
  den Containernamen; der eingebettete DNS-Server hat die Adresse `127.0.0.11` (Docker-Doku „Networking overview“,
  Abschnitte „User-defined networks“ und „DNS services“). Das trägt den `resolver 127.0.0.11` im Snippet.
- **nginx, `proxy_pass` mit Variable**: „Parameter value can contain variables. In this case, if an address is
  specified as a domain name, the name is searched among the described server groups, and, if not found, is
  determined using a resolver.“ (nginx-Doku `ngx_http_proxy_module`, `proxy_pass`). Darum startet nginx auch, wenn
  `step-ca-client` nicht läuft; nur `/client/crl` antwortet dann mit 502.
- **nginx-Image**: Die `nginx.conf` des Pakets bindet im `http`-Block `include /etc/nginx/conf.d/*.conf;` ein, die
  mitgelieferte `conf.d/default.conf` lauscht auf Port 80 (nginx/pkg-oss, `alpine/alpine/nginx.conf` und
  `nginx.default.conf`). Eine eigene Datei, die schreibgeschützt über `/etc/nginx/conf.d/default.conf` gelegt wird,
  ersetzt diesen Standard-Server. Das Entrypoint-Skript `10-listen-on-ipv6-by-default.sh` fasst eine
  schreibgeschützte `default.conf` nicht an (nginx/docker-nginx, Zeile 27: „can not modify … exit 0“).
  Dateien in `conf.d/` landen auf `http`-Ebene; ein `location`-Block darf dort nicht stehen. Das Snippet wird deshalb
  nach `/etc/nginx/snippets/` gelegt und aus dem `server`-Block per `include` geladen.
- **nginx-Version**: aktuelle stabile Linie 1.30, Stand 2026-10-25 `1.30.6` (nginx.org, Download-Seite), Tag
  `nginx:1.30.6-alpine` auf Docker Hub vorhanden. Bei der Umsetzung den dann aktuellen `1.30.x-alpine`-Tag nehmen
  und in Doku und CHANGELOG nennen.
- **Docker Compose**: Das Feld `version` ist veraltet und erzeugt nur eine Warnung (Compose-Spezifikation „Version and
  name top-level elements“); es wird nicht gesetzt. Das Feld `name` legt den Projektnamen fest, unabhängig vom
  Ordnernamen.
- **Testbefehl vorab geprüft**: `docker compose -f <datei> config -q` läuft mit Compose v2.40 fehlerfrei, auch wenn die
  eingebundenen Ordner und Dateien (`./step-client`, nginx-Konfiguration) nicht existieren. Der Test im Repo braucht
  also keinen Docker-Daemon und keine angelegten Ordner.

## Vorgehen bei der Umsetzung

- **Testansatz**: normal (erst Datei, dann Prüfung). Das Repo hat keine Testsuite; geprüft wird mit `docker compose
  config`, `nginx -t` im Container, einem lokalen Rauchtest und dem `git grep` aus dem Issue.
- Jede Aufgabe ganz abschließen, bevor die nächste beginnt; jede Aufgabe endet mit ihrer Prüfung.
- Kleine, gezielte Änderungen. Nur Platzhalter (`example.org`, `192.0.2.x`).
- Zeilenenden laut `.gitattributes`: `*.md` LF; `*.yml` und `*.conf` fallen unter `text=auto`, also LF schreiben.
- Inhalte der Repo-Dateien auf Englisch, Stil wie die vorhandenen Kommentare (kurz, ohne Fettdruck).
- Ändert sich der Umfang während der Umsetzung, diesen Plan nachziehen.

## Prüfstrategie

- **Statisch, ohne Docker-Daemon**: `docker compose -f pki/step-ca-client/compose.example.yml config -q` und
  dasselbe für `compose.override.example.yml`; `git grep` aus dem Issue liefert keine Treffer.
- **nginx-Syntax, mit Docker-Daemon**: `nginx -t` im Image `nginx:1.30.x-alpine` mit beiden Konfigurationsdateien
  an ihren Zielpfaden.
- **Rauchtest lokal, mit Docker-Daemon, ohne CA-Schlüssel**: nur den Dienst `nginx` aus `compose.example.yml`
  starten (Projekt in einem Ordner unter `/tmp` oder im Scratch-Bereich, nie im Repo). Erwartet: `/` → 404,
  `POST /client/crl` → 403, `GET /client/crl` → 502 (CA läuft nicht). Damit ist belegt, dass nginx ohne CA startet und
  nur den einen Pfad weiterreicht.
- Läuft auf dem Umsetzungsrechner kein Docker-Daemon, die Schritte mit Daemon als ⚠️ im Plan vermerken und in
  „Nach Abschluss“ übernehmen, nicht überspringen ohne Vermerk.

## Fortschritt festhalten

- Erledigtes sofort mit `[x]` abhaken.
- Neu gefundene Aufgaben mit ➕ ergänzen.
- Blocker mit ⚠️ vermerken.
- Weicht die Umsetzung vom Plan ab, den Plan anpassen.

## Was wohin gehört

- **Umsetzungsschritte** (`[ ]`): alles, was in diesem Repo machbar ist: Dateien, Doku, Prüfungen.
- **Nach Abschluss** (ohne Kästchen): alles, was ein echtes System braucht: Lab-Docker-Host, öffentliche CRL-Abfrage,
  NetScaler.

## Umsetzungsschritte

### Aufgabe 1: Vollständige nginx-Konfiguration und Snippet-Kommentar

- [x] neue Datei `pki/step-ca-client/nginx-client-crl-server.conf`: ein `server`-Block mit
      `listen 80 default_server;`, `server_name _;`, `server_tokens off;` und
      `include /etc/nginx/snippets/client-crl.conf;`. Kopfkommentar: wird in `compose.example.yml` als
      `/etc/nginx/conf.d/default.conf` eingebunden und ersetzt damit den Standard-Server des Images
- [x] `pki/step-ca-client/nginx-client-crl.conf`: nur Zeile 1 neu formulieren. Inhalt: dieser Block wird von
      `nginx-client-crl-server.conf` eingebunden (eigenständiges Projekt) oder in den Port-80-`server`-Block des eigenen
      Webservers übernommen (Variante); nginx muss im selben Docker-Netz wie `step-ca-client` laufen. Die Zeilen 2–11
      (Resolver, `location`-Blöcke) bleiben unverändert
- [x] prüfen: beide Dateien enthalten kein „existing“ mehr in der Bedeutung „vorhandenes Projekt / vorhandener Block“
- [x] prüfen (mit Docker-Daemon): `docker run --rm` mit `nginx-client-crl-server.conf` → `/etc/nginx/conf.d/default.conf:ro`
      und `nginx-client-crl.conf` → `/etc/nginx/snippets/client-crl.conf:ro`, Befehl `nginx -t` → „syntax is ok“,
      „test is successful“

### Aufgabe 2: Eigenständiges Compose-Projekt `compose.example.yml`

- [x] neue Datei `pki/step-ca-client/compose.example.yml`, Kopfkommentar wie im Override: keine
      `DOCKER_STEPCA_INIT_*`-Variablen (Auto-Init schreibt das Provisioner-Passwort in `docker logs`); Hinweis, dass die
      Datei im Projektordner als `compose.yml` abgelegt wird
- [x] oberste Ebene `name: pki-client` (Projektname unabhängig vom Ordner), kein `version`
- [x] Dienst `step-ca-client` unverändert aus `compose.override.example.yml` übernehmen (Image
      `smallstep/step-ca:0.30.2`, `container_name: step-ca-client`, `restart: unless-stopped`,
      `./step-client:/home/step`, Port `192.0.2.186:9444:9000` mit dem Kommentar „enrollment workstations only: LAN IP,
      no internet port forward“), zusätzlich `networks: [pki-client]`
- [x] Dienst `nginx`: Image `nginx:1.30.x-alpine` (aktueller Tag, Stand Plan `1.30.6`), `restart: unless-stopped`,
      Port `"80:80"` (Ziel des Port-Forwards für die öffentliche CRL), Bind-Mounts
      `./nginx-client-crl-server.conf:/etc/nginx/conf.d/default.conf:ro` und
      `./nginx-client-crl.conf:/etc/nginx/snippets/client-crl.conf:ro`, `networks: [pki-client]`
- [x] bewusst **kein** `depends_on` vom nginx auf die CA; Kommentar am Dienst: nginx soll auch ohne laufende CA starten
      (Variable + Resolver im Snippet), `/client/crl` antwortet dann 502
- [x] Netz `pki-client` auf oberster Ebene (Bridge, Standardtreiber)
- [x] prüfen: `docker compose -f pki/step-ca-client/compose.example.yml config -q` → Exit 0, keine Warnung
- [x] prüfen (mit Docker-Daemon): Rauchtest aus der Prüfstrategie (nur `nginx`, Projekt außerhalb des Repos):
      `/` → 404, `POST /client/crl` → 403, `GET /client/crl` → 502; danach `docker compose down`
      (Ergebnis 2026-10-25, Engine 28.5.1, Compose v2.40.3: wie erwartet, zusätzlich `HEAD /client/crl` → 502 und
      Server-Kopf `nginx` ohne Version)

### Aufgabe 3: Override als Variante kennzeichnen

- [x] `pki/step-ca-client/compose.override.example.yml`, Zeile 1–2: neu formulieren als Variante. Inhalt: für ein
      eigenes Compose-Projekt, das bereits nginx auf Port 80 betreibt; neben dessen `compose.yml` legen; nginx und
      `step-ca-client` müssen im selben Netz liegen; im Port-80-`server`-Block `nginx-client-crl.conf` einbinden;
      ohne solches Projekt `compose.example.yml` nehmen. Hinweis zu `DOCKER_STEPCA_INIT_*` bleibt
- [x] Dienstdefinition bleibt unverändert
- [x] prüfen: `docker compose -f pki/step-ca-client/compose.override.example.yml config -q` → Exit 0

### Aufgabe 4: `docs/client-ca.md` Abschnitt 1 (CA-Aufbau)

- [x] Zeile 34–38: Dateiliste um `compose.example.yml` und `nginx-client-crl-server.conf` ergänzen; ein Satz, dass
      `compose.example.yml` CA und CRL-nginx als eigenes Projekt bringt und die Override-Datei nur die Variante ist
- [x] neuer kurzer Absatz „Docker host“ vor Schritt 1: Linux-Host mit Docker Engine und Compose v2 (`docker compose`),
      `jq` (Schritt 4), Port 80 frei (CRL), LAN-IP für Port 9444 (Enrollment), Projektordner `/srv/pki`
- [x] neuer Schritt 0 bzw. Erweiterung von Schritt 1: `/srv/pki` anlegen, die Dateien aus `pki/step-ca-client/`
      hineinkopieren, `compose.example.yml` als `compose.yml` speichern, LAN-IP im Port `9444` ersetzen. Die
      bisherigen Befehle (`install … ca.json.example …`) setzen voraus, dass die Dateien in `/srv/pki` liegen; das wird
      damit wahr
- [x] Schritt 7 (Zeile 93–98): Start beider Dienste (`docker compose up -d`, `docker compose ps`), Erwartung
      `step-ca-client` „healthy“ nach etwa einer Minute, nginx „running“; `docker exec step-ca-client step ca health`
      bleibt
- [x] Variante in einem kurzen Absatz am Ende von Abschnitt 1: eigenes Projekt mit nginx auf Port 80 → Override neben
      die eigene `compose.yml`, gemeinsames Netz, Snippet in den eigenen Port-80-Block, Start mit
      `docker compose up -d step-ca-client`
- [x] ➕ Variante: `ca.json.example` und `client-auth.tpl` müssen auch dort in den Projektordner (Schritt 1 setzt sie
      voraus); `compose.override.yml` lädt Compose nur ohne `-f` automatisch (geprüft mit Compose v2.40.3), beides
      steht jetzt im Absatz
- [x] prüfen: Schritte 1–8 lesen sich ab leerem Host ohne fremde Teile; kein Satz, der ein fremdes Compose-Projekt voraussetzt

### Aufgabe 5: `docs/client-ca.md` Abschnitt 2 (CRL-Verteilpunkt) und README

- [x] Zeile 108–110: nginx kommt aus `compose.example.yml` (Dienst `nginx`, Konfiguration
      `nginx-client-crl-server.conf` + `nginx-client-crl.conf`); Aussagen zu GET/HEAD und 404 bleiben; „The CA itself
      is never exposed“ bleibt
- [x] ein Satz „Alternative“: step-ca kann die CRL über `insecureAddress` selbst per HTTP ausliefern, aber nur unter
      `/crl` bzw. `/1.0/crl`; das ändert den CDP und legt den CA-Prozess ins Internet, darum hier nginx
- [x] `README.md:122`: Beschreibung von `pki/` nachziehen, z. B. „step-ca client CA: standalone compose project (CA +
      nginx for the public CRL), CA config, leaf template“
- [x] prüfen: Links in `docs/client-ca.md` auf die neuen Dateien zeigen auf existierende Pfade

### Aufgabe 6: CHANGELOG

- [x] Abschnitt für die nächste Patch-Version ergänzen (Doku/Beispieldateien, kein Bruch im Config-Layout →
      Patch laut `docs/release.md`): „Added“ `compose.example.yml`, `nginx-client-crl-server.conf`; „Changed“
      Override und Snippet als Variante, `docs/client-ca.md` Aufbau ab leerem Docker-Host; getestete nginx-Version
      nennen. Datum und Versionsnummer setzt erst der Release, Format der vorhandenen Abschnitte beibehalten
      (umgesetzt als `## Unreleased`; der Release benennt ihn in `## vX.Y.Z - YYYY-MM-DD` um, weil `docs/release.md`
      die Notizen über diese Überschrift ausschneidet)
- [x] prüfen: kein Tag, kein Release in dieser Umsetzung

### Aufgabe 7: Akzeptanzkriterien prüfen

- [x] Testbefehl aus dem Issue, im Worktree-Wurzelordner:
      `git grep -n -i -E "existing compose|existing .server" -- pki docs ':(exclude)docs/plans'; docker compose -f pki/step-ca-client/compose.example.yml config -q`
      → `git grep` ohne Treffer, `config -q` mit Exit 0 (Abweichung vom Issue: `docs/plans/` ist ausgenommen, weil dieser Plan den Testbefehl wörtlich enthält und sich sonst selbst findet)
- [x] Platzhalter-Check: `git grep -n -E "[a-z0-9-]+\.(de|com|net|local)\b|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" -- pki docs/client-ca.md README.md`
      zeigt nur `example.org`/`example.com`, `192.0.2.x`, `127.0.0.11` und Versionsnummern
- [x] Zeilenenden: `git ls-files --eol pki docs/client-ca.md README.md CHANGELOG.md` → `i/lf` für alle geänderten
      Dateien
- [x] keine Änderung an `ca.json.example`, `client-auth.tpl`, `scripts/Enroll-YubiKeyPiv.ps1`,
      `netscaler/13-client-crl.cli` (`git diff --stat origin/main`)
- [x] Syntaxprüfung der Skripte aus `CLAUDE.md` läuft weiter mit 0 Fehlern (nur zur Sicherheit, Skripte sind nicht
      berührt)

### Aufgabe 8: Plan und Doku abschließen

- [x] diesen Plan mit dem tatsächlichen Stand abgleichen (abgehakte Punkte, ➕/⚠️)
- [x] `docs/troubleshooting.md` nur ergänzen, falls beim Rauchtest ein neues Fehlerbild auftaucht (z. B. nginx startet
      nicht wegen doppeltem `default_server`) (kein neues Fehlerbild, keine Änderung)
- [x] ➕ PR #12 (Branch `docs/4-client-ca-compose`), Review als PR-Kommentar, zwei Anmerkungen behoben (dbc8609),
      eine begründet abgelehnt

*ralphex verschiebt den fertigen Plan nach `docs/plans/completed/`.*

## Technische Details

Zielbild `compose.example.yml` (Skizze, Kommentare in der echten Datei auf Englisch):

```yaml
name: pki-client
services:
  step-ca-client:
    image: smallstep/step-ca:0.30.2
    container_name: step-ca-client
    restart: unless-stopped
    volumes:
      - ./step-client:/home/step
    ports:
      - "192.0.2.186:9444:9000"
    networks: [pki-client]
  nginx:
    image: nginx:1.30.6-alpine
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./nginx-client-crl-server.conf:/etc/nginx/conf.d/default.conf:ro
      - ./nginx-client-crl.conf:/etc/nginx/snippets/client-crl.conf:ro
    networks: [pki-client]
networks:
  pki-client: {}
```

Zielbild `nginx-client-crl-server.conf`:

```nginx
server {
  listen 80 default_server;
  server_name _;
  server_tokens off;
  include /etc/nginx/snippets/client-crl.conf;
}
```

Ablauf einer CRL-Abfrage: Client → `http://pki.example.org/client/crl` → Port-Forward TCP 80 → nginx (`location =
/client/crl`, nur GET/HEAD) → Docker-DNS `127.0.0.11` löst `step-ca-client` auf → `https://step-ca-client:9000/1.0/crl`
→ DER-CRL zurück. Alle anderen Pfade 404, andere Methoden 403. Port 9000 der CA ist nur im Netz `pki-client` und
über `192.0.2.186:9444` im LAN erreichbar.

Projektordner auf dem Host nach dem Aufbau:

```
/srv/pki/
  compose.yml                     (Kopie von compose.example.yml)
  nginx-client-crl-server.conf
  nginx-client-crl.conf
  ca.json.example, client-auth.tpl
  step-client/{certs,config,db,secrets,templates}
```

Entscheidungen in diesem Plan, die ich (Claude) getroffen habe:
- Snippet bleibt eine Datei und wird per `include` geladen statt in die Server-Datei kopiert: eine Quelle für beide
  Wege.
- Ziel `conf.d/default.conf`: ersetzt den Standard-Server des Images, sonst gäbe es zwei Server auf Port 80.
- Kein `depends_on`: das Snippet ist ausdrücklich darauf gebaut, ohne laufende CA zu starten.
- `name: pki-client`: der Projektname hängt nicht vom Ordner `/srv/pki` ab und kollidiert nicht mit einem späteren
  Server-CA-Projekt.

## Nach Abschluss

*Braucht echte Systeme, ohne Kästchen.*

Prüfung im Lab:
- Lab-Docker-Host: neuen Ordner nach der neuen Doku ab Schritt 0 aufbauen (oder den vorhandenen Aufbau auf
  `compose.yml` umstellen), `docker compose up -d`, `docker compose ps` → CA „healthy“, nginx „running“.
- Test aus `docs/client-ca.md` Abschnitt 2 von außerhalb des LAN (Hotspot): `/client/crl` → 200 und gültige CRL,
  `/` → 404, `POST` → 403.
- NetScaler: `show ssl crl crl_client_issuing` → Last Update Successful nach `set ssl crl crl_client_issuing -interval NOW`.
- Ergebnis mit Datum und getesteten Versionen (step-ca, nginx, Compose) in CHANGELOG nachtragen.

Release:
- Patch-Release nach `docs/release.md`, durch Dima ausgelöst.
