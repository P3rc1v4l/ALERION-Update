# Code-Signing für Update Center

## Warum und was genau signiert wird

Update Center ist ein Satz aus PowerShell-Skripten, XAML, JSON, C#-Quelltext und Bildern. Nur `.ps1`/`.psm1` und `.exe` können eine eigene Authenticode-Signatur tragen. Deshalb gibt es zusätzlich einen **signierten Dateikatalog**:

1. `tools/sign.ps1` signiert alle `.ps1`/`.psm1` (hilft Nutzern mit AppLocker/WDAC).
2. `New-FileCatalog -CatalogVersion 2` erzeugt `UpdateCenter.cat` mit den SHA-256-Hashes **aller** Dateien des Pakets.
3. Der Katalog wird per `Set-AuthenticodeSignature` (SHA-256, RFC-3161-Zeitstempel) signiert.
4. `Setup.exe` wird separat signiert.

Wird danach auch nur ein Byte im Paket geändert (auch in `Gui.xaml` oder `i18n.json`), passt der Katalog nicht mehr und das Update wird abgelehnt.

## Trust on first use – so werden bestehende Installationen geschützt

`Test-UpdatePackageTrust` (in `src/Signing.psm1`) entscheidet vor jedem Self-Update:

| Installierte Version | Neues Paket | Ergebnis |
|---|---|---|
| unsigniert | unsigniert | erlaubt (`sig.unsignedLegacy`, nur SHA-256) |
| unsigniert | signiert + gültig | erlaubt (`sig.ok`, Upgrade-Pfad) |
| signiert + gültig | unsigniert | **abgelehnt** (`sig.missing`) |
| signiert + gültig | andere Signatur | **abgelehnt** (`sig.invalid`) |
| signiert + gültig | anderes Zertifikat | **abgelehnt** (`sig.thumbprintMismatch`) |
| signiert + gültig | Dateien weichen vom Katalog ab | **abgelehnt** (`sig.catalogMismatch`) |
| signiert + gültig | gleiches Zertifikat, Katalog stimmt | erlaubt (`sig.ok`) |

Sobald eine signierte Version installiert ist, kann ein Angreifer, der z. B. das GitHub-Konto oder die Release-Assets kompromittiert, kein unsigniertes oder fremd signiertes Paket mehr einschleusen – er bräuchte den privaten Schlüssel. Beim Zertifikatswechsel (Rollover) wird der Fingerabdruck des neuen Zertifikats über `-PinnedThumbprints` in einer **vorher** ausgelieferten Version hinterlegt.

Hinweis: „Gültig“ (`Valid`) setzt eine Kette zu einem vertrauenswürdigen Stammzertifikat voraus. Ein selbstsigniertes Testzertifikat liefert `UnknownError`/`NotTrusted`; die Tests prüfen dann Fingerabdruck und Katalogintegrität (`-AllowUntrustedRoot`, nur für Tests).

## Optionen, ehrlich eingeordnet (Stand meines Wissens – Preise und Verfügbarkeit bitte vor Entscheidung prüfen)

| Option | Kosten | Voraussetzungen | Bemerkung |
|---|---|---|---|
| **Azure Trusted Signing** | ca. 9,99 USD/Monat (Basic) | Azure-Konto, Identitätsprüfung (Organisation; Einzelpersonen nur in bestimmten Ländern/Regionen, Verfügbarkeit ändert sich) | Kurzlebige Zertifikate, Schlüssel liegen bei Microsoft, einfache GitHub-Action. Empfohlen, wenn die Identitätsprüfung für dich möglich ist. |
| **SignPath Foundation** | kostenlos für Open-Source | Bewerbung, öffentliches OSS-Repo mit passender Lizenz, Build in CI nachvollziehbar | Signatur lautet auf „SignPath Foundation“ als Herausgeber. Anbindung läuft über deren GitHub-Integration, nicht über `sign.ps1`. |
| **OV-Zertifikat (klassisch)** | ca. 200–400 €/Jahr | Firmen-/Identitätsprüfung; seit 2023 Schlüssel auf Hardware-Token/HSM oder Cloud-HSM | Für CI meist Cloud-Signing-Dienst der CA nötig. |
| **EV-Zertifikat** | ca. 300–600 €/Jahr | strengere Prüfung, Hardware-Token/Cloud-HSM | Gibt **keine** sofortige SmartScreen-Reputation mehr. |
| **Selbstsigniert** | 0 € | nur eigene PCs (Zertifikat dort als vertrauenswürdig importieren) | Für andere Nutzer wertlos, SmartScreen warnt weiter. Nur für lokale Tests (`-SelfSignedForTesting`). |

**SmartScreen:** Auch mit gültigem Zertifikat warnt Windows bei einer neuen, wenig verbreiteten Datei zunächst weiter. Reputation baut sich über Zeit und Downloads auf (an Zertifikat und Dateihash gekoppelt). EV-Zertifikate bringen seit 2024 keinen Sofort-Bonus mehr. Signieren verbessert Herausgeber-Anzeige, Integrität und Update-Schutz – es ist keine Garantie für „keine Warnung ab Tag 1“.

## Was du tun musst

### Weg A: Azure Trusted Signing
1. Azure-Konto anlegen, Ressource „Trusted Signing Account“ erstellen, Identitätsprüfung abschließen, Certificate Profile (Public Trust) anlegen.
2. App-Registrierung (Service Principal) mit Rolle „Trusted Signing Certificate Profile Signer“ auf dem Konto.
3. In GitHub unter *Settings → Secrets and variables → Actions*:
   - **Secrets:** `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`
   - **Variables:** `TS_ENDPOINT` (z. B. `https://weu.codesigning.azure.net`), `TS_ACCOUNT` (Kontoname), `TS_PROFILE` (Profilname)
4. Release-Workflow starten. Der Workflow erkennt die Werte automatisch.

### Weg B: PFX-Zertifikat
1. Zertifikat als `.pfx` exportieren (nur wenn die CA das erlaubt).
2. Base64 erzeugen: `[Convert]::ToBase64String([IO.File]::ReadAllBytes('cert.pfx')) | Set-Clipboard`
3. GitHub-Secrets: `SIGN_PFX_BASE64` (Base64-Inhalt) und `SIGN_PFX_PASSWORD`.

Ohne diese Werte baut der Workflow weiter **unsigniert** und gibt eine Notiz aus. Secrets werden nie ausgegeben; die PFX-Datei liegt nur kurz in `$RUNNER_TEMP` und wird danach gelöscht.

### Lokal signieren
```powershell
.\tools\sign.ps1 -Root C:\stage\pkg -PfxPath cert.pfx            # Passwort aus $env:SIGN_PFX_PASSWORD
.\tools\sign.ps1 -Root C:\stage\pkg -CertThumbprint <Fingerabdruck>
.\tools\sign.ps1 -Root C:\stage\pkg -TrustedSigning              # braucht signtool, Dlib, TS_*/AZURE_* Variablen
.\tools\sign.ps1 -Root C:\stage\pkg -SelfSignedForTesting        # nur Tests, nie in CI
```
Das Paket-Verzeichnis muss der **endgültige** Inhalt sein; nach dem Signieren darf nichts mehr geändert werden.

## Grenzen
- Der erste signierte Release schützt nur Installationen, die ihn bereits installiert haben; ältere unsignierte Installationen akzeptieren weiter unsignierte Pakete (Upgrade-Pfad).
- Wer den Signaturschlüssel verliert/verlängert, muss den Rollover (`-PinnedThumbprints`) rechtzeitig vorbereiten.
- `get.ps1` prüft den Katalog mit den eingebauten Cmdlets (nicht mit Code aus dem Paket) und lässt unsignierte Pakete mit Hinweis zu.
