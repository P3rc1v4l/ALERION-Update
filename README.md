# ALERION Update

> Programme, Treiber und Windows aktuell halten – alles auf einmal oder gezielt. · v1.2.0 · © ALERION Studios

ALERION Update ist ein Update-Tool für Windows 11. Es bündelt alles, was sonst einzeln
gepflegt werden muss: **winget-Programme** (inkl. Stream Deck, OBS, Launcher …),
**Chocolatey**, **Microsoft Store**, **Windows Update + Microsoft Update**,
**NVIDIA-Grafiktreiber** direkt von NVIDIA, **Defender-Signaturen** und **Office**.
Jedes Update bekommt eine **Priorität**, du entscheidest, was installiert wird, und am Ende gibt es
einen Bericht: *was* von *welcher Version* auf *welche* aktualisiert wurde und ob ein Neustart nötig ist.

## ✨ Funktionen

| Funktion | Details |
|---|---|
| Start ohne UAC-Abfrage | Desktop-/Startmenü-Verknüpfung startet eine geplante Aufgabe mit höchsten Rechten. UAC kommt **nur bei der Installation** |
| Updates-Liste | Alle Updates mit Häkchen: einzeln, gruppenweise oder alle Empfohlenen installieren |
| Prioritäten | 🔴 Kritisch (Sicherheit) · 🟠 Wichtig (Treiber, Windows, Store, Office) · 🔵 Normal · ⚪ Optional (Beta, unbekannte Version) |
| Suche | Strg+F durchsucht Updates **und** alle installierten Programme |
| Ausschließen | Ein Klick auf das Augen-Symbol – das Paket wird nie automatisch aktualisiert |
| Automatik | Nur manuell · täglich · wöchentlich · alle 2 Wochen · monatlich; „Installieren“ (wählbare Prioritäten) oder „Nur benachrichtigen“ |
| Sichtbar oder unsichtbar | Fenster mit Fortschritt **oder** komplett im Hintergrund + Windows-Benachrichtigung |
| Parallel | Suche und Downloads gleichzeitig, Installationen nacheinander (Windows Installer erlaubt nur eine) |
| Neustart | Nachfragen (In-App-Dialog) · sofort automatisch · zu fester Uhrzeit · nie – mit geschätzter Dauer, gemessen auf deinem PC |
| Verlauf | Alle Berichte in der App + als HTML, Neustart-Hinweis, Logs 60 Tage |
| Sicherheit | Wiederherstellungspunkt, signaturgeprüfte Treiber, geschützte Ordner, Spiele-Schutz, Abbrechen jederzeit |
| Selbst-Update | winget/Chocolatey/Windows immer; das Tool selbst optional über GitHub-Releases (SHA-256-geprüft) |
| Design | Glas-Fenster mit runden Ecken (Windows 11), eigene Fensterknöpfe, dunkles Apple-inspiriertes Design |
| Sprachen | Deutsch / Englisch |

## 🔧 Installation

1. Ordner entpacken.
2. **`Install.cmd` doppelklicken** und die Administrator-Abfrage bestätigen (einmalig – auch bei späteren Updates des Tools).
3. Fertig: Desktop-Symbol **ALERION Update** und Startmenü-Eintrag sind angelegt, das Fenster öffnet sich und sucht sofort nach Updates.
4. **An die Taskleiste anheften:** Rechtsklick auf das ALERION-Symbol in der Taskleiste → *An Taskleiste anheften*.
   (Windows 11 lässt Programme sich nicht selbst anheften.)

Deinstallieren: *Einstellungen → Apps → Installierte Apps → ALERION Update → Deinstallieren*.

## 🖱️ Bedienung

| Wo | Was |
|---|---|
| **Übersicht** | Status, Zahl der Updates je Priorität (Kachel anklicken → gefilterte Liste), „Empfohlene installieren“, „Erneut prüfen“, Abbrechen, Protokoll |
| **Updates** | Liste mit Häkchen, Filter (Alle/Kritisch/Wichtig/Normal/Optional/Ausgeschlossen/Alle Programme), Suche, „Ausgewählte installieren“ |
| **Verlauf** | Frühere Läufe, Details je Paket, HTML-Bericht, Protokolle |
| **Einstellungen** | Automatik, Verhalten, Quellen, Ausschlüsse, Selbst-Update, Sprache – speichert automatisch |

Tastatur: **Strg+F** Suche · **F5** erneut prüfen · **Esc** Suche leeren.

## 📁 Wo liegt was?

| Pfad | Inhalt |
|---|---|
| `C:\Program Files\ALERION Update` | Programm (nur für Admins beschreibbar) |
| `C:\ProgramData\ALERION\Update\config.json` | Einstellungen |
| `C:\ProgramData\ALERION\Update\reports` | Berichte (JSON + HTML) |
| `C:\ProgramData\ALERION\Update\logs` | Protokolle (inkl. `gui-error.log` bei Oberflächenfehlern) |
| Aufgabenplanung → `\ALERION\` | `ALERION Update` (Zeitplan), `ALERION Update GUI` (Start ohne UAC) |

## ⚠️ Grenzen (ehrlich)

- **AMD-/Intel-Grafiktreiber, BIOS, Mainboard-Software** haben keine offizielle Kommandozeilen-Schnittstelle.
  Sie werden nur aktualisiert, soweit Windows Update sie anbietet.
- Programme, die weder winget, Store noch Chocolatey kennen, findet die Suche (als „Aktuell“/System), kann sie aber nicht aktualisieren.
- **Funktionsupdates** (neue Windows-Version) und **optionale Vorschau-Updates** werden bewusst nicht automatisch installiert.
- Store und Office melden keine Versionen vorab – sie erscheinen als „Prüft und installiert, was verfügbar ist“.
- Die Prioritäten sind Regeln (Paketliste + Windows-Kategorien), keine Schwachstellen-Datenbank.

## 💬 Feedback

Fehler, Ideen, Fragen: **https://discord.gg/tnfgta33uj**

## 📜 Lizenz

Proprietär – siehe [LICENSE](LICENSE). © 2026 ALERION Studios (Luka Kalinka).
