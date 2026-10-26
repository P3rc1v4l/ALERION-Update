# Update Center

> Programme, Treiber und Windows aktuell halten – alles auf einmal oder gezielt. · v1.6.0

Update Center ist ein Update-Tool für Windows 10/11. Es bündelt **winget-Programme** (inkl. Stream Deck,
OBS, Launcher …), **Chocolatey**, **Microsoft Store**, **Windows Update + Microsoft Update**,
**NVIDIA-Grafiktreiber** direkt von NVIDIA, **Defender-Signaturen** und **Office**. Jedes Update bekommt eine
**Priorität**, du entscheidest, was installiert wird, und am Ende gibt es einen Bericht: *was* von *welcher
Version* auf *welche* aktualisiert wurde und ob ein Neustart nötig ist. Dazu kommen ein sauberer
**Deinstallierer**, ein **Autostart-Manager**, ein risikofreies **Aufräumen** und ein **Sicherheits-Check** (Defender, MRT, Systemdateien) – alles mit Live-Fortschritt und abbrechbar.

## 📥 Installieren / weitergeben

| Weg | Für wen | So geht's |
|---|---|---|
| **Setup.exe** | alle | Auf der [Release-Seite](https://github.com/P3rc1v4l/UpdateCenter/releases/latest) `UpdateCenter-Setup-vX.Y.Z.exe` laden → Doppelklick → Admin-Abfrage bestätigen |
| **Ein Befehl** | PowerShell-Nutzer | `irm https://raw.githubusercontent.com/P3rc1v4l/UpdateCenter/main/get.ps1 \| iex` |
| **ZIP** | manuell | `UpdateCenter-vX.Y.Z.zip` entpacken → `Install.cmd` doppelklicken |

Danach liegt **Update Center** auf dem Desktop und im Startmenü; es aktualisiert sich künftig selbst.
Solange kein Zertifikat hinterlegt ist, ist die Setup.exe nicht signiert (Infrastruktur steht bereit, siehe [docs/CODE_SIGNING.md](docs/CODE_SIGNING.md)) – Windows SmartScreen zeigt dann beim ersten Start „Unbekannter Herausgeber“
(*Weitere Informationen → Trotzdem ausführen*).

Voraussetzung: Windows 10 (1809+) oder 11 mit winget (App Installer, ab Werk vorhanden).

## ✨ Funktionen

| Funktion | Details |
|---|---|
| Start ohne UAC-Abfrage | Desktop-/Startmenü-Verknüpfung startet eine geplante Aufgabe mit höchsten Rechten; UAC nur bei der Installation |
| Updates-Liste | Alle Updates mit Häkchen: einzeln, gruppenweise oder alle Empfohlenen installieren |
| Prioritäten | 🔴 Kritisch (Sicherheit) · 🟠 Wichtig (Treiber, Windows, Store, Office) · 🔵 Normal · ⚪ Optional (Beta, unbekannte Version) |
| Suche | Strg+F durchsucht Updates **und** alle installierten Programme |
| Ausschließen | Schaltfläche „Ausschließen“ in der Zeile – das Paket wird nie automatisch aktualisiert |
| Hersteller & eigene Updater | Dell/Lenovo/HP-Treiber über deren offizielle Tools; ASUS-Mainboards über die ASUS-Supportdaten (signierte Treiber automatisch, Setups zum Bestätigen, BIOS nur als Hinweis); Chrome, Edge, Adobe, Epic, Discord über ihren eigenen Updater; Office mit Ergebnis |
| Neu installieren | Pakete mit anderer Installationsart (z. B. Epic Online Services) per Klick sauber über winget neu installieren |
| Priorität pro Programm | Rechtsklick auf ein Update → Priorität festlegen oder „Was ist neu?“ |
| Geöffnete Programme | vor dem Update fragen, automatisch schließen oder überspringen |
| Hintergrund-Suche | Sucht stündlich bis täglich (einstellbar) und meldet nur **neue** Updates |
| Fehlgeschlagene Updates | Geöffnete Programme werden übersprungen, Scope-Probleme automatisch erneut versucht, dauerhaft unpassende Pakete gemerkt und als „Optional“ mit Erklärung angezeigt |
| Programme | Sauber deinstallieren: Wiederherstellungspunkt → Hersteller-Deinstaller → Prüfung → Reste zur Auswahl (Ordner in den Papierkorb, Registry gesichert). Systemkomponenten, Treiber und Laufzeiten sind geschützt |
| Autostart | Ein-/ausschalten wie im Task-Manager (rückgängig machbar), Ansicht „Erweitert“ für Hintergrundaufgaben, Risiko je Eintrag, eigene Programme hinzufügen; Windows-, Sicherheits-, Treiber- und Hersteller-Dienste geschützt |
| Aufräumen | Papierkorb, Temp, Update-/Shader-/Browser-Cache, Fehlerberichte u. a. – nur Bereiche, die Windows selbst neu aufbaut; nie Cookies, Passwörter oder Verläufe |
| Sicherheit | Defender-Schnell-/Vollscan, Microsoft-Tool zum Entfernen bösartiger Software (MRT), sfc/DISM, Schutzstatus mit Direktlinks, Bedrohungen der letzten 30 Tage |
| Automatik | Nur manuell · täglich · wöchentlich · alle 2 Wochen · monatlich; „Installieren“ (wählbare Prioritäten) oder „Nur benachrichtigen“ |
| Neustart | Nachfragen (In-App-Dialog) · sofort automatisch · zu fester Uhrzeit · nie – mit geschätzter Dauer, gemessen auf deinem PC |
| Sichtbar oder unsichtbar | Fenster mit Fortschritt **oder** komplett im Hintergrund + Windows-Benachrichtigung |
| Komfort | Mit Windows starten, Testbenachrichtigung, App-Update per Knopf, Zeitwähler, Speichern mit Bestätigung |
| Verlauf | Alle Berichte in der App (sortierbar, volle Texte, markier- und kopierbar) + als HTML, Logs 60 Tage |
| Übersicht | Schnellaktionen, laufende Aufgaben mit Fortschritt (Abbrechen/Pausieren, Live-Protokoll), Status jedes Moduls, letzte Läufe |
| Bedienung | Rechtsklick-Menüs überall, Tastenkürzel (Strg+1–8, Strg+F, F5), Akzentfarbe, Größe und Startseite wählbar |
| Treiber | Sicherung vor jedem Grafiktreiber-Update, NVIDIA Game Ready oder Studio |
| Schutz der App | Code-Signing-fähig (signierter Katalog, Updates nur mit gleichem Zertifikat), Wiederherstellungspunkt, signaturgeprüfte Treiber, geschützte Ordner, Spiele-Schutz, Abbrechen jederzeit – siehe [SECURITY.md](SECURITY.md) |
| Sprachen | Deutsch / Englisch |

## 📁 Wo liegt was?

| Pfad | Inhalt |
|---|---|
| `C:\Program Files\Update Center` | Programm (nur für Admins beschreibbar) |
| `C:\ProgramData\UpdateCenter\config.json` | Einstellungen |
| `C:\ProgramData\UpdateCenter\reports` · `logs` | Berichte (JSON + HTML) · Protokolle (inkl. `gui-error.log`) |
| Aufgabenplanung → `\UpdateCenter\` | Zeitplan, Hintergrund-Suche, Start ohne UAC, optional Autostart und geplanter Neustart |

Deinstallieren: *Einstellungen → Apps → Installierte Apps → Update Center → Deinstallieren*.

## ⚠️ Grenzen (ehrlich)

- **AMD-/Intel-Grafiktreiber, BIOS, Mainboard-Software** haben keine offizielle Kommandozeilen-Schnittstelle –
  nur soweit Windows Update sie anbietet.
- Programme ohne Paketquelle (weder winget, Store noch Chocolatey) findet die Suche, kann sie aber nicht aktualisieren.
- **Funktionsupdates** (neue Windows-Version) und **Vorschau-Updates** werden bewusst nicht automatisch installiert.
- Die Prioritäten sind Regeln (Paketliste + Windows-Kategorien), keine Schwachstellen-Datenbank.

## 💬 Feedback

Fehler, Ideen, Fragen: **https://discord.gg/tnfgta33uj**

## 📜 Lizenz

Proprietär – siehe [LICENSE](LICENSE).
