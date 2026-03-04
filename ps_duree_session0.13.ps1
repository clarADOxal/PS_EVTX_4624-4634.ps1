# =========================
# CONFIGURATION & RÉPERTOIRES
# =========================
Add-Type -AssemblyName System.Drawing

$PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $PSScriptRoot

$InDir  = Join-Path $PSScriptRoot "in"
$OutDir = Join-Path $PSScriptRoot "out"
$InCsv  = Join-Path $InDir "security.csv"
$OutCsv = Join-Path $OutDir "duree.csv"
$OutImg = Join-Path $OutDir "sessions.png"

# Création des dossiers si absents
foreach ($dir in @($InDir, $OutDir)) {
    if (-not (Test-Path $dir)) { 
        New-Item -ItemType Directory -Force -Path $dir | Out-Null 
        Write-Host "Dossier créé : $dir" -ForegroundColor Cyan
    }
}

function Get-ReadableDuration {
    param($ts)
    if (-not $ts -or $ts.TotalSeconds -lt 0) { return "N/A" }
    if ($ts.TotalDays -ge 1)    { return "{0:N1} j" -f $ts.TotalDays }
    if ($ts.TotalHours -ge 1)   { return "{0:N1} h" -f $ts.TotalHours }
    if ($ts.TotalMinutes -ge 1) { return "{0:N1} m" -f $ts.TotalMinutes }
    return "$([math]::Round($ts.TotalSeconds)) s"
}

# =========================
# LECTURE DU FICHIER SOURCE
# =========================
if (-not (Test-Path $InCsv)) { 
    Write-Host "ERREUR : Fichier '$InCsv' manquant." -ForegroundColor Red
    exit 
}
$events = Import-Csv $InCsv
$machineName = $events[0].Computer
if (-not $machineName) { $machineName = "Inconnue" }

$userInput = Read-Host "Entrez une date/heure de référence (ex: 2023-10-25 14:30:00) ou laissez vide"
$targetDate = $null
if (-not [string]::IsNullOrWhiteSpace($userInput)) {
    try { $targetDate = [datetime]$userInput } catch { Write-Warning "Format de date invalide." }
}

# =========================
# CONSTRUCTION DES SESSIONS
# =========================
$sessions = @{}
foreach ($e in $events) {
    $logonId = if ($e.LogonId) { $e.LogonId } else { $e.PayloadData1 }
    $time = if ($e.TimeCreated) { [datetime]$e.TimeCreated } else { $null }
    if (-not $logonId -or -not $time) { continue }
    
    if ($e.EventId -eq "4624") {
        if (-not $sessions.ContainsKey($logonId)) {
            $workstation = $e.RemoteHost, $e.WorkstationName, $e.PayloadData11 | Where-Object { $_ -and $_ -ne "-" } | Select-Object -First 1
            $sessions[$logonId] = [PSCustomObject]@{ 
                LogonId = $logonId
                Start   = $time
                End     = $null
                Host    = if ($workstation) { $workstation } else { "N/A" }
            }
        }
    }
    elseif ($e.EventId -eq "4634" -and $sessions.ContainsKey($logonId)) {
        if (-not $sessions[$logonId].End) { $sessions[$logonId].End = $time }
    }
}
$sessionList = $sessions.Values | Sort-Object Start

# =========================
# EXPORT CSV (CORRIGÉ)
# =========================
$sessionList | ForEach-Object {
    $d = if ($_.End) { ($_.End - $_.Start) } else { $null }
    [PSCustomObject]@{
        LogonId = $_.LogonId
        Host    = $_.Host
        Start   = $_.Start.ToString("yyyy-MM-dd HH:mm:ss")
        End     = if ($_.End) { $_.End.ToString("yyyy-MM-dd HH:mm:ss") } else { "OPEN" }
        Duree   = Get-ReadableDuration $d
    }
} | Export-Csv $OutCsv -NoTypeInformation -Encoding UTF8 -Force

# =========================
# GÉNÉRATION IMAGE
# =========================
if ($sessionList.Count -eq 0) { Write-Warning "Aucune session."; exit }
$allDates = $sessionList | ForEach-Object { $_.Start; if ($_.End) { $_.End } }
if ($targetDate) { $allDates += $targetDate }
$minTime = ($allDates | Measure-Object -Minimum).Minimum
$maxTime = ($allDates | Measure-Object -Maximum).Maximum
$totalSeconds = [math]::Max(($maxTime - $minTime).TotalSeconds, 1)

$width = 1850; $rowH = 145; $leftTextEnd = 430; $leftGraph = 460; $top = 180
$height = $top + ($sessionList.Count * $rowH) + 60
$bmp = New-Object System.Drawing.Bitmap $width, $height
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.Clear([System.Drawing.Color]::White)

$font  = New-Object System.Drawing.Font("Segoe UI", 9)
$fontB = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$penC  = New-Object System.Drawing.Pen([System.Drawing.Color]::SteelBlue, 18)
$penO  = New-Object System.Drawing.Pen([System.Drawing.Color]::Orange, 18)
$penS  = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220, 220, 220), 1)
$penBlack = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 2)
$penR  = New-Object System.Drawing.Pen([System.Drawing.Color]::Red, 2); $penR.DashStyle = 2
$brushP = [System.Drawing.Brushes]::BlueViolet

# Dessin Légende & Barre
$gfx.DrawString("Timeline Sessions - Machine: $machineName", $fontB, [System.Drawing.Brushes]::Black, 15, 15)
$gfx.FillRectangle([System.Drawing.Brushes]::SteelBlue, 15, 45, 20, 10)
$gfx.DrawString("Session Complète", $font, [System.Drawing.Brushes]::Black, 40, 42)
$gfx.FillRectangle([System.Drawing.Brushes]::Orange, 15, 65, 20, 10)
$gfx.DrawString("Session Ouverte", $font, [System.Drawing.Brushes]::Black, 40, 62)
$gfx.FillRectangle($brushP, 15, 85, 10, 10)
$gfx.DrawString("Session Ultra-courte (< 1 min)", $font, [System.Drawing.Brushes]::Black, 40, 82)
$gfx.DrawLine($penBlack, $leftTextEnd + 5, $top - 30, $leftTextEnd + 5, $height - 40)

$y = $top
foreach ($s in $sessionList) {
    $gfx.DrawLine($penS, 10, $y + 75, $width - 20, $y + 75)
    $startStr = $s.Start.ToString("dd/MM HH:mm:ss")
    $endStr   = if ($s.End) { $s.End.ToString("dd/MM HH:mm:ss") } else { "En cours" }
    $durTs    = if ($s.End) { ($s.End - $s.Start) } else { $null }
    $durStr   = if ($s.End) { Get-ReadableDuration $durTs } else { "En cours..." }
    
    $infoText = "ID: $($s.LogonId)`nHost: $($s.Host)`nDurée: $durStr`n[$startStr -> $endStr]"
    $gfx.DrawString($infoText, $font, [System.Drawing.Brushes]::Black, 15, $y - 45) 
    
    $x1 = $leftGraph + ((($s.Start - $minTime).TotalSeconds / $totalSeconds) * ($width - $leftGraph - 80))
    if ($s.End) {
        $x2 = $leftGraph + ((($s.End - $minTime).TotalSeconds / $totalSeconds) * ($width - $leftGraph - 80))
        if (($x2 - $x1) -lt 8) { $gfx.FillRectangle($brushP, $x1 - 4, $y - 10, 8, 20) }
        else { $gfx.DrawLine($penC, $x1, $y, $x2, $y) }
    } else {
        $gfx.DrawLine($penO, $x1, $y, $width - 80, $y)
    }
    $y += $rowH
}

# Ligne Cible
if ($targetDate) {
    $xT = $leftGraph + ((($targetDate - $minTime).TotalSeconds / $totalSeconds) * ($width - $leftGraph - 80))
    $gfx.DrawLine($penR, $xT, $top - 30, $xT, $height - 40)
    $gfx.DrawString("Cible: $($targetDate.ToString('yyyy-MM-dd HH:mm:ss'))", $font, [System.Drawing.Brushes]::Red, $xT + 5, $top - 50)
}

$bmp.Save($OutImg, [System.Drawing.Imaging.ImageFormat]::Png)
$gfx.Dispose(); $bmp.Dispose()

Write-Host "`n? Terminé." -ForegroundColor Green

Write-Host "Fichiers disponibles dans : $OutDir" -ForegroundColor White
