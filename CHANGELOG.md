# Changelog

Alle relevanten Änderungen an ALERION Update. Format nach *Keep a Changelog*, Versionierung nach SemVer.

## [1.1.1] - 2026-10-25
### Fixed
- Selbst-Update: Die `.sha256`-Datei kommt von GitHub als Binärdaten; v1.1.0 hätte sie falsch gelesen und
  jedes Update als „Prüfsumme falsch“ abgelehnt. Jetzt korrekt – end-to-end gegen das echte Release getestet.

## [1.1.0] - 2026-10-25
### Added
- **Updates-Seite:** alle verfügbaren Updates als Liste mit Häkchen – einzelne oder ausgewählte Updates
  installieren, „Alle auswählen“ je Gruppe, „Auswahl aufheben“, Zähler und Badge in der Seitenleiste.
- **Prioritäten:** Kritisch (Sicherheit: Windows-Sicherheitsupdates, Defender, Browser, Laufzeiten, VPN,
  Fernwartung, winget/Chocolatey selbst), Wichtig (Treiber, Windows, Store, Office), Normal, Optional
  (Beta/Vorschau, unbekannte Version). Kennzeichnung „Großes Update“ bei Hauptversionssprüngen.
- **Suche** (Strg+F) über Updates **und** alle installierten Programme (inkl. Status „Aktuell“).
- **Ausschließen mit einem Klick** (Augen-Symbol in der Liste), Ansicht „Ausgeschlossen“, Chips mit ✕ in den Einstellungen.
- **Abbrechen** eines laufenden Updates (nach dem aktuellen Paket), Status je Paket live in der Liste.
- **Automatik:** „Installieren“ oder „Nur benachrichtigen“, wählbar welche Prioritäten automatisch installiert werden.
- **Verlauf:** alle bisherigen Berichte statt nur des letzten.
- Automatische Update-Prüfung beim Öffnen (wenn älter als 30 Min.), F5 = erneut prüfen.
- Fehlerprotokoll für die Oberfläche (`logs\gui-error.log`) statt stiller Abstürze.

### Changed
- Neues Design im macOS-Stil: abgerundete Fensterecken (Windows 11), Ampel-Fensterknöpfe, Segment-Schalter,
  iOS-Schalter, ruhigere Farben, Einstellungen unten in der Seitenleiste.
- Einstellungen speichern automatisch (kein Speichern-Knopf mehr); Zeitplan wird nur bei Änderung neu registriert.
- „Jetzt aktualisieren“ heißt jetzt „Empfohlene installieren“ und lässt optionale Updates (Beta/unbekannt) aus.
- Motor arbeitet in zwei Phasen: erst alle Kandidaten sammeln (parallel), dann nur die Auswahl installieren.

### Removed
- Feedback-Knopf in der App (auf Wunsch; Discord-Link steht weiter in der README).

### Fixed
- Selbst-Update zeigte auf ein Repository, das es noch nicht gab – mit diesem Release ist
  `github.com/P3rc1v4l/ALERION-Update` öffentlich und liefert die Updates (ZIP + SHA-256).
- Einstellungen werden automatisch auf Schema 2 migriert (neue Automatik-Optionen).
- Prüfläufe ohne Auswahl erzeugen keine leeren Berichte mehr.

## [1.0.0] - 2026-10-25
### Added
- Update-Motor (`UpdateEngine.ps1`) mit Quellen: winget (einzeln je Paket, winget selbst zuerst),
  Chocolatey, Microsoft Store (Scan + Vorher/Nachher-Versionsvergleich), Windows Update inkl.
  Microsoft Update und Treibern, NVIDIA-Treiber über die offizielle NVIDIA-API, Defender-Signaturen,
  Microsoft 365/Office Click-to-Run.
- Paralleler Modus: Downloads/Scans in Hintergrund-Jobs, Installationen nacheinander.
- Moderne WPF-Oberfläche (Übersicht mit Live-Fortschritt, Einstellungen, Bericht), DE/EN.
- Zeitplan über die Windows-Aufgabenplanung (manuell, täglich, wöchentlich, 2-wöchentlich, monatlich),
  verpasste Läufe werden nachgeholt, optional Aufwecken aus dem Energiesparmodus.
- Sichtbarer oder unsichtbarer Modus; Windows-Benachrichtigung mit Link zum HTML-Bericht.
- Abschlussbericht (JSON + HTML) mit Von→Auf-Versionen, Status und Neustart-Hinweis; Neustart-Optionen.
- Selbst-Update über GitHub-Releases mit SHA-256-Prüfung.
- Installer/Deinstaller, Desktop- und Startmenü-Verknüpfung mit eigenem Icon und AppUserModelID,
  Eintrag unter „Installierte Apps“.
- Smoke-Test (`tests/smoke_test.ps1`) und GitHub-Actions-Build mit Release-ZIP + SHA-256.

### Security
- Programmdateien in `Program Files`, Daten-Ordner per ACL gehärtet (nur Admins schreiben).
- Elevated-Prozesse laden Module nur aus geschützten Pfaden; winget/choco werden nicht über PATH aufgelöst.
- NVIDIA-Pakete nur von `*.download.nvidia.com` über HTTPS und nur mit gültiger NVIDIA-Signatur.
- Windows Update ersetzt den NVIDIA-Treiber nicht (Display-Treiber von NVIDIA aus WU gefiltert).
- Geplante Läufe warten bei Vollbild-Spielen (Anti-Cheat-Schutz) und bei niedrigem Akku.
