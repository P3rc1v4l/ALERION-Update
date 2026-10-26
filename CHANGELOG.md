# Changelog

Alle relevanten Änderungen an Update Center (bis v1.2.0 „ALERION Update“). Format nach *Keep a Changelog*, Versionierung nach SemVer.

## [1.6.0] - 2026-10-26
### Security (Prüfung durch ein Review-Team)
- **Selbst-Update kann die App nicht mehr beschädigen**: Pakete werden im geschützten Programmordner entpackt
  (nicht mehr im Cache, den die Aufräumroutine anfasst). Der Installer prüft das Paket vorab, sichert die alte
  Version, stellt sie bei jedem Fehler automatisch wieder her und schreibt ein Installationsprotokoll.
- Signierte Pakete werden jetzt wirklich festgenagelt (der signierte Katalog wird mitinstalliert).
- Datenordner: Besitz und Rechte werden vollständig zurückgesetzt (auch vorab angelegte Unterordner); alte
  Einstellungen werden nur aus einem von Administratoren angelegten Ordner übernommen. Update-Quelle fest verdrahtet.
- Erhöhte Prozesse kompilieren und entpacken nicht mehr im Benutzer-TEMP.
- Sperrdatei statt globalem Mutex: kein „hängender“ Zustand nach Abbruch, nicht von Standardbenutzern blockierbar.
- Launcher (Epic, Discord) und Hersteller-Setups laufen ohne Administratorrechte; Programme aus Benutzerordnern
  werden nie erhöht gestartet. Release nur noch aus `main`, mit Paketprüfung vor dem Veröffentlichen.

### Added
- **ASUS-Treiber automatisch**: Abgleich über die ASUS-Support-Daten des Mainboards. Signierte Treiberpakete
  (z. B. LAN, USB-Audio) werden automatisch über die Windows-Treiberinstallation eingespielt, Hersteller-Setups
  (z. B. Chipsatz) geprüft und zum Installieren geöffnet, BIOS nur angezeigt. Alle Downloads nur von asus.com,
  mit SHA-256- und Signaturprüfung.
- **App-Update sichtbar**: Dialog „Update Center wird aktualisiert“, Benachrichtigung nach dem Update und
  „Neu in Version …“ beim ersten Start.
- **Scans mit Fortschritt und Live-Protokoll**: geschätzter Fortschritt aus der Dauer früherer Scans, Protokoll
  mit allen Schritten und gefundenen Bedrohungen – auch für Aufräumen und Deinstallation.
- **Autostart**: Ansicht „Wie im Task-Manager“ und „Erweitert“ (mit Warnhinweis), Risiko-Erklärung je Eintrag,
  mehr Schutz (Hardware-Dienste des PC-Herstellers, Windows-Teile, Systemaufgaben), **eigene Programme hinzufügen**.
- **Übersicht neu**: Schnellaktionen, letzte Läufe, Status aller Module, laufende Aufgaben.
- **Seitenleiste** zeigt mit einem pulsierenden Punkt, wo gerade etwas läuft.
- **Rechtsklick-Menüs** in allen Listen (Programme, Autostart, Aufräumen, Sicherheit, Aufgaben, Verlauf).
- **Darstellung anpassbar**: Akzentfarbe, Größe der Oberfläche, Startseite.
- Tastenkürzel: Strg+1–8 (Seiten), Strg+F (Suche der Seite), F5 (Seite neu laden), Strg+S (Einstellungen speichern).

### Changed
- Statusmeldungen während eines Laufs sind jetzt **deutsch** (bzw. in der gewählten Sprache).
- **Ausschließen** ist ein reines Symbol: offenes Auge = wird aktualisiert, durchgestrichen = ausgeschlossen;
  beim Überfahren zeigt es, was ein Klick bewirkt.

### Fixed
- Dialoge verdrängen sich nicht mehr gegenseitig; der Neustart-Countdown lässt sich nicht versehentlich wegklicken.
- Doppelklicks starten keine zweite Installation; nur eine Deinstallation gleichzeitig.
- Hängende Ladevorgänge brechen nach einer Zeitgrenze ab; Fehler in der Oberfläche werden protokolliert statt
  das Fenster zu schließen; beschädigte Datumswerte führen nicht mehr zu Fehlern.
- Ungültige Uhrzeiten in den Einstellungen werden erkannt; bei Speicherfehlern bleibt die Seite offen.
- Sprachwechsel aktualisiert alle Seiten; Datumsangaben folgen der App-Sprache.
- Nach Prüfung durch ein Test-Team: Scan-Ergebnisse und Hersteller-Hinweise sind übersetzt (keine englischen
  Texte oder Schlüssel mehr), das Live-Protokoll in der Übersicht zeigt wieder einzelne Zeilen, das geplante
  Aufräumen meldet die freigegebene Größe korrekt, beschädigte Einstellungsdateien führen nie zu einem Absturz,
  „Temporäre Dateien“ räumt weiterhin den Benutzer-TEMP auf, Einstellungen älterer Versionen werden sicher
  übernommen, Programm-Suche zeigt „nichts gefunden“ statt „lädt“, die Aktionsleiste erscheint nur mit Auswahl.

## [1.5.1] - 2026-10-26
### Fixed
- **App-Update schlug fehl** („Der Prozess kann nicht auf die Datei … icon.ico zugreifen“): Das Selbst-Update kopierte
  in den laufenden Programmordner, während das geöffnete Fenster das Symbol gesperrt hielt. Jetzt wird das geprüfte
  Paket an seinen eigenen Installer übergeben: Er wartet das Ende des Laufs ab, schließt die App, ersetzt alle Dateien
  und öffnet sie wieder. Zusätzlich lädt die App Symbol und Logo in den Speicher und sperrt keine Dateien mehr.

### Added
- **Verlauf kopieren**: Text in allen Spalten lässt sich mit der Maus markieren und kopieren. Knopf „Kopieren“
  (ganzer Bericht) und Rechtsklick-Menü: markierte Zeilen, ganzer Bericht oder nur Fehler – als Tabelle, die sich
  sauber in Chats, Mails oder Excel einfügen lässt.

## [1.5.0] - 2026-10-26
### Added
- **Code-Signing-Vorbereitung**: signierter Katalog über alle Dateien (`UpdateCenter.cat`) plus Authenticode für
  Skripte und Setup.exe. Der Release-Workflow signiert automatisch, sobald ein Zertifikat hinterlegt ist (PFX oder
  Azure Trusted Signing). Selbst-Update nach dem Prinzip „Trust on first use“: Ist die installierte Version signiert,
  wird jedes Update nur mit demselben Zertifikat und unverändertem Katalog angenommen. Der Online-Installer prüft
  die Signatur ebenfalls. Anleitung: `docs/CODE_SIGNING.md`.
- **Neu installieren** für Pakete mit anderer Installationsart (z. B. Epic Online Services): direkt in der
  Updates-Liste, per winget deinstallieren und neu installieren.
- **Autostart**: neue Seite wie im Task-Manager. Einträge lassen sich ein- und ausschalten (rückgängig machbar, es
  wird nichts gelöscht). Sicherheitssoftware, Treiber-Helfer und Eingabedienste sind geschützt.
- **Hersteller-Treiber**: Dell Command Update, Lenovo System Update und HP Image Assistant über ihre offiziellen
  Befehlszeilen. ASUS bietet keine; dort erscheint ein Hinweis, der den DriverHub öffnet. BIOS/Firmware wird nie
  automatisch installiert.
- **Apps mit eigenem Updater**: Chrome, Edge, Adobe, Epic Games Launcher und Discord werden über ihren eigenen
  Updater angestoßen. Steam, Battle.net, EA und Ubisoft bekommen einen Hinweis statt eines fehlschlagenden
  winget-Updates. Office wartet jetzt auf das Ergebnis und meldet die neue Version.
- **Optionale Windows-Treiber** (wie in den Einstellungen unter „Optionale Updates“) erscheinen als „Optional“.
- **Live-Fortschritt** mit Balken für Aufräumen, Sicherheits-Scans, Deinstallation und Reste-Entfernung,
  **abbrechbar**; Aufräumen lässt sich auch **pausieren**. Wo Abbrechen unsicher wäre (DISM-Reparatur,
  laufender Hersteller-Deinstaller), ist der Knopf gesperrt und erklärt.
- **Übersicht zeigt alle Module**: laufende Aufgaben mit Fortschritt sowie der Status von Programmen, Autostart,
  Aufräumen und Sicherheit.
- **Geöffnete Programme**: vor der Installation fragen, automatisch schließen oder überspringen (Einstellung).
- **Priorität pro Programm** (Rechtsklick auf ein Update), **Versionshinweise** („Was ist neu?“).
- **Treiber-Sicherung** vor jedem Grafiktreiber-Update, **NVIDIA Studio-Treiber** als Option.
- **Geplantes Aufräumen** (wöchentlich/monatlich, nur risikofreie Bereiche) und **Infobereich-Symbol** (optional).

### Changed
- Module laden **sofort**: zuletzt bekannte Daten erscheinen beim Öffnen, frische Daten folgen im Hintergrund.
  Reihenfolge: Übersicht zuerst, dann die Seiten von unten nach oben; die gerade geöffnete Seite hat Vorrang.
- **Verlauf** sitzt jetzt unten in der Seitenleiste über den Einstellungen.

### Fixed
- Auf der Seite **Sicherheit** ließ sich mit dem Mausrad nicht scrollen.

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
