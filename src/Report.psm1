# ALERION Update - report rendering (JSON + self-contained HTML).
# Keep this file ASCII-only (Windows PowerShell 5.1).

Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'Common.psm1') -DisableNameChecking

function Resolve-Text {
    <# Translates values that are i18n keys (msg.*), leaves everything else untouched. #>
    param([string]$Value)
    if ($Value -and $Value -like 'msg.*') { return (T $Value) }
    return $Value
}

function Get-LastReport {
    $file = Join-Path (Get-AppPaths).StateDir 'last-report.json'
    if (-not (Test-Path $file)) { return $null }
    try { return Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function ConvertTo-ReportHtml {
    param([Parameter(Mandatory)]$Report)
    $e = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $order = @{ Failed = 0; Updated = 1; Available = 2; Triggered = 3; Skipped = 4; Info = 5 }
    $rows = foreach ($i in (@($Report.Items) | Sort-Object { $order[[string]$_.Status] }, Source, Name)) {
        $status = [string]$i.Status
        $reboot = if ($i.RebootRequired) { ' <span class="tag">' + (& $e (T 'report.rebootTag')) + '</span>' } else { '' }
        "<tr><td><span class='src'>$(& $e (T ('source.' + $i.Source)))</span></td><td>$(& $e (Resolve-Text $i.Name))<div class='id'>$(& $e $i.Id)$(if ($i.PSObject.Properties.Name -contains 'Priority' -and $i.Priority) { ' &middot; <span class=''p p-' + $i.Priority + '''>' + (& $e (T ('prio.' + $i.Priority))) + '</span>' })</div></td>" +
        "<td class='v'>$(& $e $i.From)</td><td class='arrow'>$(if ($i.From -or $i.To) { '&rarr;' })</td><td class='v'>$(& $e $i.To)</td>" +
        "<td><span class='st st-$status'>$(& $e (T ('status.' + $status)))</span>$reboot<div class='msg'>$(& $e (Resolve-Text $i.Message))</div></td></tr>"
    }
    $started = [datetime]::Parse($Report.StartedAt)
    $ended = [datetime]::Parse($Report.EndedAt)
    $duration = '{0:hh\:mm\:ss}' -f ($ended - $started)
    $banner = if ($Report.RebootRequired) { "<div class='banner warn'>$(& $e (T 'report.rebootRequired'))</div>" } else { "<div class='banner ok'>$(& $e (T 'report.noReboot'))</div>" }
    if ($Report.DryRun) { $banner = "<div class='banner info'>$(& $e (T 'report.dryRun'))</div>" + $banner }
    $lang = Get-CurrentLanguage
    @"
<!doctype html>
<html lang="$lang"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ALERION Update - $(& $e (T 'report.title'))</title>
<style>
:root{--bg:#0d0f17;--card:#151826;--line:#262a3d;--text:#e8eaf3;--muted:#8b90a8;--ok:#34d399;--bad:#f87171;--warn:#fbbf24;--info:#60a5fa;--acc1:#7c3aed;--acc2:#0a84ff}
@media (prefers-color-scheme: light){:root{--bg:#f4f5fa;--card:#fff;--line:#e3e5ef;--text:#14172a;--muted:#5d6380}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 "Segoe UI Variable Text","Segoe UI",system-ui,sans-serif;padding:32px 16px}
.wrap{max-width:1100px;margin:0 auto}h1{font-size:26px;margin:0 0 4px;background:linear-gradient(90deg,var(--acc1),var(--acc2));-webkit-background-clip:text;background-clip:text;color:transparent}
.meta{color:var(--muted);margin-bottom:20px}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px}.card b{font-size:26px;display:block}.card span{color:var(--muted)}
.banner{border-radius:12px;padding:12px 16px;margin-bottom:12px;font-weight:600}.banner.ok{background:rgba(52,211,153,.12);color:var(--ok)}.banner.warn{background:rgba(251,191,36,.14);color:var(--warn)}.banner.info{background:rgba(96,165,250,.12);color:var(--info)}
.table{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow-x:auto}table{width:100%;border-collapse:collapse;min-width:720px}
th,td{text-align:left;padding:10px 14px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
tr:last-child td{border-bottom:0}.id,.msg{color:var(--muted);font-size:12px}.v{font-family:"Cascadia Mono",Consolas,monospace;font-size:12.5px;white-space:nowrap}.arrow{color:var(--muted)}
.src{font-size:12px;padding:2px 8px;border-radius:99px;border:1px solid var(--line);white-space:nowrap}.st{font-weight:600}.st-Updated{color:var(--ok)}.st-Failed{color:var(--bad)}.st-Skipped,.st-Info{color:var(--muted)}.st-Available,.st-Triggered{color:var(--info)}
.p{font-weight:600}.p-Critical{color:#ff453a}.p-Important{color:#ff9f0a}.p-Normal{color:#0a84ff}.p-Optional{color:var(--muted)}.tag{font-size:11px;background:rgba(251,191,36,.15);color:var(--warn);padding:1px 6px;border-radius:6px;margin-left:6px}footer{color:var(--muted);margin-top:16px;font-size:12px}a{color:var(--acc2)}
</style></head><body><div class="wrap">
<h1>ALERION Update</h1>
<div class="meta">$(& $e (T 'report.title')) &middot; $(& $e $Report.Computer) &middot; $(& $e $started.ToString('g')) &middot; $(& $e (T 'report.duration')) $duration &middot; v$(& $e $Report.AppVersion)</div>
$banner
<div class="cards">
<div class="card"><b style="color:var(--ok)">$($Report.Counts.Updated)</b><span>$(& $e (T 'status.Updated'))</span></div>
<div class="card"><b style="color:var(--bad)">$($Report.Counts.Failed)</b><span>$(& $e (T 'status.Failed'))</span></div>
<div class="card"><b>$($Report.Counts.Skipped)</b><span>$(& $e (T 'status.Skipped'))</span></div>
<div class="card"><b style="color:var(--info)">$($Report.Counts.Available)</b><span>$(& $e (T 'status.Available'))</span></div>
</div>
<div class="table"><table><thead><tr><th>$(& $e (T 'report.colSource'))</th><th>$(& $e (T 'report.colName'))</th><th>$(& $e (T 'report.colFrom'))</th><th></th><th>$(& $e (T 'report.colTo'))</th><th>$(& $e (T 'report.colStatus'))</th></tr></thead>
<tbody>
$($rows -join "`n")
</tbody></table></div>
<footer>Log: $(& $e $Report.LogFile) &middot; &copy; ALERION Studios</footer>
</div></body></html>
"@
}

function Save-Report {
    param([Parameter(Mandatory)]$Report)
    $paths = Get-AppPaths
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $json = Join-Path $paths.ReportDir "report-$stamp.json"
    $html = Join-Path $paths.ReportDir "report-$stamp.html"
    $Report | Add-Member -NotePropertyName HtmlPath -NotePropertyValue $html -Force
    $text = $Report | ConvertTo-Json -Depth 6
    Write-AtomicFile -Path $json -Content $text
    Write-AtomicFile -Path (Join-Path $paths.StateDir 'last-report.json') -Content $text
    Write-AtomicFile -Path $html -Content (ConvertTo-ReportHtml -Report $Report)
    return [pscustomobject]@{ Json = $json; Html = $html }
}

Export-ModuleMember -Function *
