# Replay the saved CauldronTracker debugLog through the current detection logic
# to verify what the code would have counted, without needing a live raid.
#
# Usage:
#   pwsh ./tools/replay.ps1
#   pwsh ./tools/replay.ps1 -SavedVarsPath "C:\path\to\CauldronTracker.lua" -LocalPlayer "Mychar"
#
# Log entries come in two formats:
#   old:  "HH:MM:SS <event...>"                          (pre-1.0.8, no date, 1s granularity)
#   new:  "YYYY-MM-DD HH:MM:SS <gametime>.mmm <event...>" (1.0.8+)
# New-format entries are grouped by date and timed by GetTime() with millisecond
# precision; old-format entries are treated as a single legacy group compared
# against today's stored counts.

param(
    [string]$SavedVarsPath = "$env:USERPROFILE\..\..\World of Warcraft\_retail_\WTF\Account\PTARJAN\SavedVariables\CauldronTracker.lua",
    # The character the log was recorded on. Lines whose playerName was logged
    # as secret/nil/empty fall back to this name (matching the live code's
    # UnitName("player") fallback).
    [string]$LocalPlayer = ""
)

if (-not (Test-Path $SavedVarsPath)) {
    # Try the absolute path used in this repo's host
    $alt = "D:\World of Warcraft\_retail_\WTF\Account\PTARJAN\SavedVariables\CauldronTracker.lua"
    if (Test-Path $alt) { $SavedVarsPath = $alt }
    else { throw "SavedVars not found at $SavedVarsPath" }
}

# Constants — keep in sync with CauldronTracker.lua
$BURST_THRESHOLD = 3
$BURST_WINDOW = 30.0
$LOOT_DEDUP_WINDOW = 1.0
$CAULDRON_ACTIVE_DURATION = 300.0

function ParseTimeToSeconds([string]$hms) {
    $parts = $hms.Split(':')
    return [double]([int]$parts[0] * 3600 + [int]$parts[1] * 60 + [int]$parts[2])
}

function StripRealm([string]$name) {
    return ($name -split '-', 2)[0]
}

function IsFleeting([string]$itemName) {
    return $itemName.ToLower().StartsWith('fleeting')
}

function ExtractItem([string]$msg) {
    # Pull both the raw item link and the bracketed name
    $linkMatch = [regex]::Match($msg, '\|Hitem:[^|]+\|h\[(.+?)\]\|h')
    if (-not $linkMatch.Success) { return $null }
    $name = $linkMatch.Groups[1].Value
    # Strip embedded |A:...|a icon tokens to get a clean item name
    $name = [regex]::Replace($name, '\s*\|A:[^|]*\|a', '').Trim()
    $link = $linkMatch.Value
    $qtyMatch = [regex]::Match($msg, 'x(\d+)')
    $qty = if ($qtyMatch.Success) { [int]$qtyMatch.Groups[1].Value } else { 1 }
    return @{ Name = $name; Link = $link; Qty = $qty }
}

function CountUniquePlayers($buffer) {
    $seen = @{}
    foreach ($e in $buffer) { $seen[$e.Player] = $true }
    return $seen.Keys.Count
}

function ResolvePlayer([string]$raw) {
    if ([string]::IsNullOrEmpty($raw) -or $raw -eq 'secret' -or $raw -eq 'nil') {
        if ($script:LocalPlayer) { return $script:LocalPlayer }
        $script:unresolvedPlayers++
        return $null
    }
    return StripRealm $raw
}

# Load the file (UTF-8 without BOM — default encoding in PS 5.1 would mangle names)
$content = Get-Content -Raw -Encoding UTF8 $SavedVarsPath
$logMatch = [regex]::Match($content, '\["debugLog"\]\s*=\s*\{(.*?)\n\}', 'Singleline')
if (-not $logMatch.Success) { throw "Could not find debugLog block" }
$logBody = $logMatch.Groups[1].Value
# Each entry is a quoted Lua string; pull them in order
$entryRegex = [regex]'"((?:[^"\\]|\\.)*)"\s*,'
$rawEntries = @()
foreach ($m in $entryRegex.Matches($logBody)) {
    # Unescape Lua-style \" and \\ back to literals
    $s = $m.Groups[1].Value -replace '\\"', '"' -replace '\\\\', '\'
    $rawEntries += $s
}
Write-Host ("Loaded {0} debugLog entries from {1}" -f $rawEntries.Count, $SavedVarsPath)

# Build event list from log lines that look like new top-level events.
# Optional leading date and gametime (new format); sub-lines starting with
# "  " are diagnostic only and never match.
$stampRegex = '^(?:(\d{4}-\d{2}-\d{2}) )?(\d{2}:\d{2}:\d{2})(?: (\d+\.\d+))? '
$events = @()
$script:unresolvedPlayers = 0
foreach ($line in $rawEntries) {
    $stamp = [regex]::Match($line, $stampRegex)
    if (-not $stamp.Success) { continue }
    $day = if ($stamp.Groups[1].Success) { $stamp.Groups[1].Value } else { 'legacy' }
    $hms = $stamp.Groups[2].Value
    # Prefer GetTime() (monotonic, millisecond) over the wall-clock stamp
    $time = if ($stamp.Groups[3].Success) { [double]$stamp.Groups[3].Value } else { ParseTimeToSeconds $hms }
    $rest = $line.Substring($stamp.Length)

    if ($rest -match '^CHAT_MSG_LOOT raw msg="(.+)"\s+playerName=(.+)$') {
        $events += @{ Day = $day; TimeStr = $hms; Time = $time; Type = 'LOOT'
                      Msg = $Matches[1]; PlayerName = $Matches[2] }
    } elseif ($rest -match '^UNIT_SPELLCAST_START cauldron:.*spellID=(\d+).*castGUID=(.+)$') {
        $events += @{ Day = $day; TimeStr = $hms; Time = $time; Type = 'SPELL'
                      SpellID = [int]$Matches[1]; CastGUID = $Matches[2] }
    }
}
Write-Host ("Parsed {0} top-level events ({1} LOOT, {2} SPELL)" -f $events.Count,
    (($events | Where-Object { $_.Type -eq 'LOOT' }).Count),
    (($events | Where-Object { $_.Type -eq 'SPELL' }).Count))

# Simulation state — sessions are delimited by time regressions; while a
# cauldron window is active, writes stay anchored to the day it opened
# (matching the live code's midnight handling).
$dayCounts = @{}       # day -> @{ player -> count }
$dayCauldrons = @{}    # day -> list
$cauldronActiveUntil = 0.0
$activeDayKey = $null
$recentCreates = New-Object System.Collections.ArrayList
$recentLootKeys = @{}
$recentCastGUIDs = @{}
$prevTime = -1.0

function ResetSession {
    $script:cauldronActiveUntil = 0.0
    $script:activeDayKey = $null
    $script:recentCreates.Clear() | Out-Null
    $script:recentLootKeys = @{}
    $script:recentCastGUIDs = @{}
}

function EnsureDay([string]$day) {
    if (-not $script:dayCounts.ContainsKey($day)) {
        $script:dayCounts[$day] = @{}
        $script:dayCauldrons[$day] = New-Object System.Collections.ArrayList
    }
}

# Mirrors ActivateCauldron in CauldronTracker.lua
function ActivateWindow([double]$now, [string]$day) {
    if ($now -ge $script:cauldronActiveUntil) { $script:activeDayKey = $day }
    $script:cauldronActiveUntil = [Math]::Max($script:cauldronActiveUntil, $now + $CAULDRON_ACTIVE_DURATION)
}

# Mirrors CurrentDayKey in CauldronTracker.lua
function CurrentDayKey([double]$now, [string]$day) {
    if ($script:activeDayKey -and $now -lt $script:cauldronActiveUntil) { return $script:activeDayKey }
    return $day
}

foreach ($evt in $events) {
    $now = $evt.Time

    if ($prevTime -ge 0 -and $now -lt $prevTime - 1.0) {
        # Time went backwards: new session (relog/reboot) — the live addon's
        # in-memory windows did not survive this boundary. (Pre-1.0.8 the
        # window also did not survive; 1.0.8 restores it from SavedVars, which
        # replay cannot see, so this is a best-effort approximation.)
        ResetSession
    }
    $prevTime = $now
    $targetDay = CurrentDayKey $now $evt.Day
    EnsureDay $targetDay
    $counts = $dayCounts[$targetDay]
    $cauldrons = $dayCauldrons[$targetDay]

    if ($evt.Type -eq 'SPELL') {
        if ($evt.CastGUID -and $evt.CastGUID -ne 'nil' -and $recentCastGUIDs.ContainsKey($evt.CastGUID)) { continue }
        if ($evt.CastGUID -and $evt.CastGUID -ne 'nil') { $recentCastGUIDs[$evt.CastGUID] = $now }
        ActivateWindow $now $evt.Day
        foreach ($e in $recentCreates) {
            if (($now - $e.Time) -le $BURST_WINDOW) {   # stale entries are dropped, matching live code
                if (-not $counts.ContainsKey($e.Player)) { $counts[$e.Player] = 0 }
                $counts[$e.Player] += 1
            }
        }
        $recentCreates.Clear() | Out-Null
        [void]$cauldrons.Add(@{ Time = $evt.TimeStr; Player = "spell"; SpellID = $evt.SpellID })
        continue
    }

    # LOOT
    $item = ExtractItem $evt.Msg
    if (-not $item) { continue }
    if (-not (IsFleeting $item.Name)) { continue }
    if ($item.Qty -gt 1) { continue }   # personal craft, skip

    $player = ResolvePlayer $evt.PlayerName
    if (-not $player) { continue }

    $key = "$player|$($item.Link)"
    if ($recentLootKeys.ContainsKey($key) -and ($now - $recentLootKeys[$key]) -lt $LOOT_DEDUP_WINDOW) {
        continue
    }
    $recentLootKeys[$key] = $now

    if ($now -lt $cauldronActiveUntil) {
        if (-not $counts.ContainsKey($player)) { $counts[$player] = 0 }
        $counts[$player] += 1
        continue
    }

    [void]$recentCreates.Add(@{ Time = $now; Player = $player })
    while ($recentCreates.Count -gt 0 -and ($now - $recentCreates[0].Time) -gt $BURST_WINDOW) {
        $recentCreates.RemoveAt(0)
    }
    $unique = CountUniquePlayers $recentCreates
    if ($unique -ge $BURST_THRESHOLD) {
        ActivateWindow $now $evt.Day
        [void]$cauldrons.Add(@{ Time = $evt.TimeStr; Player = "?"; FromBurst = $true; Unique = $unique })
        foreach ($e in $recentCreates) {
            if (-not $counts.ContainsKey($e.Player)) { $counts[$e.Player] = 0 }
            $counts[$e.Player] += 1
        }
        $recentCreates.Clear() | Out-Null
    }
}

if ($script:unresolvedPlayers -gt 0) {
    Write-Host ("WARNING: {0} loot lines had secret/empty playerName and no -LocalPlayer was given; they were skipped." -f $script:unresolvedPlayers) -ForegroundColor Red
}

# Extract stored counts for a given day: locate the day block first, then find
# the counts sub-block anywhere inside it (serialized key order is not stable).
function GetStoredCounts([string]$day) {
    $stored = @{}
    $dayMatch = [regex]::Match($script:content, "\[`"$day`"\]\s*=\s*\{(.*?)\n\}", 'Singleline')
    if (-not $dayMatch.Success) { return $stored }
    $body = $dayMatch.Groups[1].Value
    $countsMatch = [regex]::Match($body, '\["counts"\]\s*=\s*\{(.*?)\}', 'Singleline')
    if (-not $countsMatch.Success) {
        Write-Host ("WARNING: day {0} exists in SavedVars but no counts block was found inside it." -f $day) -ForegroundColor Red
        return $stored
    }
    foreach ($m in [regex]::Matches($countsMatch.Groups[1].Value, '\["([^"]+)"\]\s*=\s*(\d+)')) {
        $stored[$m.Groups[1].Value] = [int]$m.Groups[2].Value
    }
    return $stored
}

foreach ($day in ($dayCounts.Keys | Sort-Object)) {
    $storedDay = if ($day -eq 'legacy') { Get-Date -Format 'yyyy-MM-dd' } else { $day }
    $storedCounts = GetStoredCounts $storedDay
    $counts = $dayCounts[$day]
    $cauldrons = $dayCauldrons[$day]

    Write-Host ""
    Write-Host ("=== Replay results for {0} (stored under {1}) ===" -f $day, $storedDay) -ForegroundColor Cyan
    Write-Host ("Cauldrons detected: {0}" -f $cauldrons.Count)
    foreach ($c in $cauldrons) {
        if ($c.FromBurst) {
            Write-Host ("  {0}  burst (unique={1})" -f $c.Time, $c.Unique)
        } else {
            Write-Host ("  {0}  spell (id={1})" -f $c.Time, $c.SpellID)
        }
    }

    Write-Host ""
    Write-Host ("{0,-20} {1,-8} {2,-8} {3}" -f 'Player', 'Replay', 'Stored', 'Diff') -ForegroundColor Yellow
    $allPlayers = @{}
    $counts.Keys | ForEach-Object { $allPlayers[$_] = $true }
    $storedCounts.Keys | ForEach-Object { $allPlayers[$_] = $true }
    $total = 0
    $totalStored = 0
    foreach ($p in ($allPlayers.Keys | Sort-Object)) {
        $r = if ($counts.ContainsKey($p)) { $counts[$p] } else { 0 }
        $s = if ($storedCounts.ContainsKey($p)) { $storedCounts[$p] } else { 0 }
        $diff = $r - $s
        $diffStr = if ($diff -eq 0) { '=' } elseif ($diff -gt 0) { "+$diff" } else { "$diff" }
        $color = if ($diff -eq 0) { 'Gray' } else { 'Red' }
        Write-Host ("{0,-20} {1,-8} {2,-8} {3}" -f $p, $r, $s, $diffStr) -ForegroundColor $color
        $total += $r
        $totalStored += $s
    }
    Write-Host ("{0,-20} {1,-8} {2,-8}" -f 'TOTAL', $total, $totalStored) -ForegroundColor Yellow
}
