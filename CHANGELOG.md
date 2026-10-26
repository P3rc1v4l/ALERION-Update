# Changelog

Alle relevanten Änderungen an Update Center (bis v1.2.0 „ALERION Update“). Format nach *Keep a Changelog*, Versionierung nach SemVer.

## [1.4.0] - 2026-10-26
### Added
- **Programme** (sauber deinstallieren): alle installierten Programme inkl. Store-Apps mit Suche und Sortierung.
  Systemkomponenten, Treiber, Laufzeiten (VC++, .NET, WebView2, DirectX), Updates und Windows-Bausteine sind
  **geschützt** und nicht deinstallierbar. Ablauf: Wiederherstellungspunkt → Deinstallation (winget → MSI → Hersteller-
  Deinstaller → Store) → Prüfung, ob wirklich entfernt → Reste-Suche (nur eindeutig zugehörige Ordner/Schlüssel/
  Verknüpfungen) → du wählst aus; Ordner gehen in den Papierkorb, Registry-Schlüssel werden vorher gesichert.
- **Aufräumen**: nur risikofreie Bereiche mit Größenanzeige – Papierkorb, temporäre Dateien (> 24 h),
  Windows-Update-Cache, Übermittlungsoptimierung, Miniaturansichten, Fehlerberichte, DirectX-Shader-Cache,
  Browser-Cache (nie Cookies/Verlauf/Passwörter; übersprungen, solange der Browser läuft), alte Absturzabbilder,
  eigene alte Logs; optional Komponentenspeicher (DISM ohne /ResetBase). Bewusst **nicht**: Prefetch, Registry-
  „Reinigung“, WinSxS/Installer-Ordner.
- **Sicherheit**: Defender-Schnellscan und vollständiger Scan, Microsoft-Tool zum Entfernen bösartiger Software (MRT,
  schnell/vollständig), Systemdateien prüfen und reparieren (sfc, bei Bedarf DISM) – plus Schutzstatus (Virenschutz,
  Echtzeitschutz, Signaturen, Manipulationsschutz, Firewall, UAC, Secure Boot, TPM, BitLocker, SmartScreen,
  Speicherintegrität, SMBv1, Remotedesktop, PUA-Schutz, letzter Scan, Windows Update) mit „Öffnen“-Link zur
  passenden Windows-Seite und erkannte Bedrohungen der letzten 30 Tage.
- **Hintergrund-Suche** mit einstellbarem Intervall (aus, stündlich, 3/6/12 h, täglich): benachrichtigt nur über
  *neue* Updates.
- Lange Vorgänge (Scans, Deinstallation, Aufräumen) laufen im Hintergrund – die App bleibt bedienbar.

### Changed
- **Verlauf**: Texte werden umgebrochen statt abgeschnitten (voller Text auch als Tooltip), Spalten sind
  verbreiterbar und **per Klick sortierbar**.
- **Ausschließen** als beschriftete Schaltfläche („Ausschließen“/„Einschließen“), dezent bis man die Zeile überfährt.
- **Maximieren** nutzt nur den Arbeitsbereich – die Taskleiste bleibt sichtbar (auf jedem Monitor).
- **Einstellungen** nutzen die volle Fensterbreite.
- GitHub-Repository heißt jetzt **P3rc1v4l/UpdateCenter** (alte Adresse leitet weiter; Einstellung wird automatisch umgestellt).
- Actions-Läufe älter als 2 Tage werden täglich automatisch gelöscht.

### Fixed – fehlgeschlagene Updates
- **Programm geöffnet** (z. B. OBS): wird vorher erkannt (Prozess im Installationsordner) und übersprungen statt zu scheitern.
- **„Kein passendes Update“** (z. B. FACEIT): automatischer zweiter Versuch mit `--scope user` bzw. `--scope machine`.
- **Gleiche Version nach „erfolgreicher“ Installation** (z. B. Google Play Games, abweichende Versionsanzeige),
  **andere Installationsart** (z. B. Epic Online Services) und **Parallel-Installationen** (z. B. Unity-Editor):
  werden gemerkt und für genau diese Version nicht mehr empfohlen, sondern mit Erklärung als „Optional“ angezeigt.

## [1.3.0] - 2026-10-25
### Fixed
- **Ausgewählte Updates wurden nicht installiert:** Windows PowerShell 5.1 las die Auswahlliste als *ein* Element
  („Nothing selected to install“). Jetzt korrekt.
- **„Es läuft bereits ein Vorgang“ + Sprung in den Verlauf direkt nach dem Klick:** Die Oberfläche las noch den
  Status des vorigen Laufs. Sie wartet jetzt, bis der neue Lauf seinen Status geschrieben hat.
- **Neustart-Hinweis trotz frischem Neustart:** `PendingFileRenameOperations` (z. B. dauerhaft von Xbox Gaming
  Services belegt) wird nicht mehr ausgewertet; zusätzlich zählt der eigene letzte Lauf nur, wenn seitdem kein
  Neustart war. winget-Ausgaben mit dem Wort „restart“ lösen keinen Neustart-Hinweis mehr aus.
- **Einzelnes Windows-Update / einzelner Grafiktreiber wurde übersprungen bzw. scheiterte** („Eigenschaft Count nicht
  gefunden“): PS 5.1 liefert bei genau einem Element ein Einzelobjekt – jetzt immer als Liste behandelt.
- winget-Codes `0x8A15008E` (andere Installationsart) und `0x8A150111` (Programm in Benutzung) werden verständlich
  angezeigt statt als Fehlercode.
- „Verwerfen“ in den Einstellungen springt auf den zuletzt gespeicherten Stand zurück.

### Changed
- **Neuer Name „Update Center“** (Fenster, Verknüpfungen, Startmenü, „Installierte Apps“, Aufgaben, Benachrichtigungen,
  Bericht). Neue Pfade: `C:\Program Files\Update Center`, `C:\ProgramData\UpdateCenter`, Aufgaben unter `\UpdateCenter\`.
  Bestehende „ALERION Update“-Installationen werden automatisch umgezogen (Einstellungen und Verlauf bleiben).
- **Neues Logo** als App-, Desktop- und Taskleisten-Icon.
- **Fenster:** nicht mehr transparent, kein Balken oben, Eckenradius wie die Seitenleiste, eigener Schatten.
- **Einstellungen** werden erst mit „Speichern“ (mitlaufende Leiste) oder beim Wechsel in ein anderes Modul
  gespeichert – mit Bestätigungs-Toast; „Verwerfen“ setzt zurück.
- **Ausschließen-Symbol** neu gestaltet (eigenes Vektor-Auge, rot beim Überfahren, blau wenn ausgeschlossen).
- Selbst-Updates führen danach den Installer aus (Verknüpfungen, Icon, Aufgaben werden mit aktualisiert).

### Added
- **Zeitwähler** für Uhrzeiten: Klick markiert den Inhalt, ein Feld mit scrollbaren Stunden/Minuten klappt aus.
- **Mit Windows starten** (minimiert, ohne UAC-Abfrage).
- **Testbenachrichtigung senden** und **Nach App-Update suchen** in den Einstellungen.
- **Weitergabe:** `UpdateCenter-Setup-vX.Y.Z.exe` (Doppelklick) und Online-Installer `get.ps1`.
- **Sicherheit:** wöchentlicher GitHub-Workflow (Sicherheitsregeln, Secret-Scan, Smoke-Test), `SECURITY.md`.
- **Automatischer UI-Test** (`tests/ui_test.ps1`): bedient das echte Fenster unsichtbar (Speichern-Leiste, Zeitwähler,
  Verwerfen, Toast) – 19 Prüfungen.

## [1.2.0] - 2026-10-25
### Added
- **Neustart-Optionen:** Nachfragen · sofort automatisch (2 Min. Vorwarnung) · zu fester Uhrzeit (einmalige Aufgabe
  „ALERION Restart“, läuft als SYSTEM, wird nicht nachgeholt, löscht sich selbst) · nie.
- **Dauer-Schätzung** für den Neustart, gemessen aus den letzten Neustarts dieses PCs (Ereignisprotokoll 6006 → 6005)
  plus Zuschlag, wenn Windows Updates einrichtet. Angezeigt im Dialog, im Banner, in den Einstellungen und im Bericht.
- **In-App-Dialoge** im App-Design statt Windows-Meldungsfenster (Neustart, „läuft bereits“, Fehler), mit
  „Jetzt neu starten“, „Zu Uhrzeit neu starten“, „Neustart abbrechen“, „Später“.
- Neues **Logo** (transparent, Taskleiste/Desktop/Startmenü/App); `tools/make_icon.py` erzeugt alle Größen aus der Vorlage.

### Changed
- **Komplett neues Design „Glass“:** echtes Acrylic-Glas-Fenster (Windows 11), schwebende Seitenleiste mit farbigen
  Symbol-Kacheln, gruppierte Listen im Apple-Stil, Logo-Farbverlauf (Cyan → Blau → Violett), schwebende Aktionsleiste,
  Einstellungen als Zeilen-Gruppen, „Gespeichert“-Hinweis als Pille.
- **Eigene Fensterknöpfe** oben rechts in einer Kapsel (weder Apple noch Windows), Schließen mit rotem Glühen.
- Layout in `src/Gui.xaml` ausgelagert.

### Removed
- Alter Icon-Generator `tools/New-Icon.ps1` (ersetzt durch das echte Logo).

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
