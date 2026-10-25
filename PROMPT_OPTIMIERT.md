# ALERION Update – optimierter Prompt / Spezifikation

> Das ist die überarbeitete Fassung deiner ursprünglichen Anfrage. Sie diente als
> verbindliche Spezifikation für v1.0.0. Du kannst sie in neuen Chats wiederverwenden.

---

## Ziel

Baue **ALERION Update**, ein sicheres Windows-11-Update-Tool, das mit einem Klick
oder nach Zeitplan **alle aktualisierbaren Programme, Treiber und Windows selbst**
auf den neuesten Stand bringt und am Ende einen nachvollziehbaren Bericht liefert.

## Funktionale Anforderungen

1. **Update-Quellen (jeweils einzeln an-/abschaltbar)**
   - `winget` – alle Programme, die winget erkennt (inkl. „unbekannter“ Versionen,
     z. B. Stream Deck, OBS, Discord-Clients, Launcher). Jedes Paket einzeln, damit
     Ausschlüsse und Einzelergebnisse möglich sind. winget (App Installer) selbst zuerst.
   - Chocolatey (falls installiert).
   - Microsoft Store-Apps (Update-Scan auslösen + Vorher/Nachher-Versionsvergleich).
   - Windows Update inkl. Microsoft Update (Office u. a.), optional Treiber über WU.
   - NVIDIA-Grafiktreiber direkt von NVIDIA (offizielle API, Signaturprüfung,
     stille Installation). Display-Treiber aus Windows Update werden übersprungen,
     damit WU keinen älteren NVIDIA-Treiber drüberinstalliert.
   - Microsoft Defender-Signaturen, Microsoft 365/Office Click-to-Run.
2. **Ausführung**: nacheinander oder – wo gefahrlos möglich – parallel
   (Scan/Download parallel, Installationen nacheinander wegen Windows-Installer-Sperre).
3. **Zeitplan**: Nur manuell · täglich · wöchentlich (Wochentag) · alle 2 Wochen ·
   monatlich (Tag) – jeweils mit Uhrzeit; verpasste Läufe werden nachgeholt.
4. **Modus**: sichtbar (Fortschrittsfenster) oder komplett unsichtbar im Hintergrund.
5. **Abschlussbericht**: was von welcher Version auf welche aktualisiert wurde,
   was fehlschlug/übersprungen wurde, ob ein Neustart nötig ist (Neustart-Optionen:
   nie / fragen / automatisch mit Countdown). Unsichtbar → Windows-Benachrichtigung.
6. **Bedienung**: modernes Desktop-Icon + Startmenü-Eintrag (zum Anheften an die
   Taskleiste), Start ohne UAC-Abfrage, DE/EN umschaltbar, Discord-Feedback-Link.

## Sicherheitsanforderungen

- Läuft erhöht, **aber**: alle Skripte liegen admin-geschützt in `C:\Program Files`,
  Konfiguration/Status in einem ACL-gehärteten Ordner unter `ProgramData`
  (normale Prozesse können nichts manipulieren, was später als Admin läuft).
- Wiederherstellungspunkt vor jedem Lauf (abschaltbar).
- Nur ein Lauf gleichzeitig (Mutex), Akku-/Speicherplatz-/Internet-Vorprüfung.
- Geplante Läufe warten, solange ein Vollbildspiel/Präsentation läuft (Anti-Cheat!).
- Downloads nur über HTTPS von Herstellerdomains + Authenticode-Signaturprüfung.
- Ausschlussliste für Pakete (z. B. Beta-/Major-Sprünge).
- **Selbst-Update**: Die eigenen Abhängigkeiten (winget, Chocolatey, PowerShell
  via Windows Update) werden in jedem Lauf zuerst aktualisiert. Das Tool selbst kann
  sich optional aus GitHub-Releases aktualisieren (nur mit SHA-256-Prüfung,
  Anwendung erst nach dem Lauf).
- Keine Secrets, keine Telemetrie, Logs mit Rotation.

## Nicht-Ziele (ehrlich)

- AMD/Intel-Grafiktreiber, BIOS, Mainboard-Tools: keine offizielle Kommandozeilen-
  Schnittstelle → werden über Windows Update abgedeckt, soweit Microsoft sie anbietet.
- Programme ohne Paketquelle (weder winget noch Store noch choco) und Spiele-Launcher-
  Spiele (Steam/Epic aktualisieren sich selbst).
- Automatisches Anheften an die Taskleiste: Windows 11 erlaubt das Programmen
  nicht offiziell → ein Rechtsklick „An Taskleiste anheften“.
