# Update Center

> Programme, Treiber und Windows aktuell halten – alles auf einmal oder gezielt. · v1.3.0

Update Center ist ein Update-Tool für Windows 10/11. Es bündelt **winget-Programme** (inkl. Stream Deck,
OBS, Launcher …), **Chocolatey**, **Microsoft Store**, **Windows Update + Microsoft Update**,
**NVIDIA-Grafiktreiber** direkt von NVIDIA, **Defender-Signaturen** und **Office**. Jedes Update bekommt eine
**Priorität**, du entscheidest, was installiert wird, und am Ende gibt es einen Bericht: *was* von *welcher
Version* auf *welche* aktualisiert wurde und ob ein Neustart nötig ist.

## 📥 Installieren / weitergeben

| Weg | Für wen | So geht's |
|---|---|---|
| **Setup.exe** | alle | Auf der [Release-Seite](https://github.com/P3rc1v4l/ALERION-Update/releases/latest) `UpdateCenter-Setup-vX.Y.Z.exe` laden → Doppelklick → Admin-Abfrage bestätigen |
| **Ein Befehl** | PowerShell-Nutzer | `irm https://raw.githubusercontent.com/P3rc1v4l/ALERION-Update/main/get.ps1 \| iex` |
| **ZIP** | manuell | `UpdateCenter-vX.Y.Z.zip` entpacken → `Install.cmd` doppelklicken |

Danach liegt **Update Center** auf dem Desktop und im Startmenü; es aktualisiert sich künftig selbst.
Die Setup.exe ist nicht signiert – Windows SmartScreen zeigt beim ersten Start „Unbekannter Herausgeber“
(*Weitere Informationen → Trotzdem ausführen*).

Voraussetzung: Windows 10 (1809+) oder 11 mit winget (App Installer, ab Werk vorhanden).

## ✨ Funktionen

| Funktion | Details |
|---|---|
| Start ohne UAC-Abfrage | Desktop-/Startmenü-Verknüpfung startet eine geplante Aufgabe mit höchsten Rechten; UAC nur bei der Installation |
| Updates-Liste | Alle Updates mit Häkchen: einzeln, gruppenweise oder alle Empfohlenen installieren |
| Prioritäten | 🔴 Kritisch (Sicherheit) · 🟠 Wichtig (Treiber, Windows, Store, Office) · 🔵 Normal · ⚪ Optional (Beta, unbekannte Version) |
| Suche | Strg+F durchsucht Updates **und** alle installierten Programme |
| Ausschließen | Klick auf das Augen-Symbol – das Paket wird nie automatisch aktualisiert |
| Automatik | Nur manuell · täglich · wöchentlich · alle 2 Wochen · monatlich; „Installieren“ (wählbare Prioritäten) oder „Nur benachrichtigen“ |
| Neustart | Nachfragen (In-App-Dialog) · sofort automatisch · zu fester Uhrzeit · nie – mit geschätzter Dauer, gemessen auf deinem PC |
| Sichtbar oder unsichtbar | Fenster mit Fortschritt **oder** komplett im Hintergrund + Windows-Benachrichtigung |
| Komfort | Mit Windows starten, Testbenachrichtigung, App-Update per Knopf, Zeitwähler, Speichern mit Bestätigung |
| Verlauf | Alle Berichte in der App + als HTML, Logs 60 Tage |
| Sicherheit | Wiederherstellungspunkt, signaturgeprüfte Treiber, geschützte Ordner, Spiele-Schutz, Abbrechen jederzeit – siehe [SECURITY.md](SECURITY.md) |
| Sprachen | Deutsch / Englisch |

## 📁 Wo liegt was?

| Pfad | Inhalt |
|---|---|
| `C:\Program Files\Update Center` | Programm (nur für Admins beschreibbar) |
| `C:\ProgramData\UpdateCenter\config.json` | Einstellungen |
| `C:\ProgramData\UpdateCenter\reports` · `logs` | Berichte (JSON + HTML) · Protokolle (inkl. `gui-error.log`) |
| Aufgabenplanung → `\UpdateCenter\` | Zeitplan, Start ohne UAC, optional Autostart und geplanter Neustart |

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
