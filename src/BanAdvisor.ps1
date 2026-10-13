<#
  Ranked 5s Ban Advisor
  ---------------------
  Finds the enemy team in champ select and shows ban recommendations plus each
  enemy's strengths and weaknesses in your browser at http://localhost:8765

  Two ways to find the enemy team (pick in the dashboard menu):
    1. League client  - asks your own League client (local API on 127.0.0.1)
    2. Screen reading - reads names off the League window with Windows' built-in
                        text recognition, then looks the players up on op.gg
    Auto tries the League client first and falls back to screen reading.

  - Recent games count more than older ones.
  - Games an enemy played WITH their current teammates (premades) count extra.
  - Players whose names are hidden by the game are never looked up.
#>
param(
    [int]$Port = 8765,
    [int]$Games = 20,
    [string[]]$Players,      # test mode, e.g. -Players "ShoTeru#NA1","Gildarts#NA2"
    [ValidateSet('', 'auto', 'client', 'screen')][string]$Method = '',
    [switch]$Demo,           # show the dashboard with sample data
    [switch]$NoBrowser,
    [string]$BaseUrl,        # developer testing only
    [string]$Token,
    [string]$OpggBase = 'https://lol-api-summoner.op.gg',
    [string]$PoroBase = 'https://porofessor.gg',
    [string]$DonateUrl = '',
    [string]$RiotBase = ''       # developer testing only (sends every Riot API call to this host)
)

# Put your donation page here (for example https://ko-fi.com/yourname). settings.json "donateUrl" also works.
$DefaultDonateUrl = 'https://ko-fi.com/biscuitables'

$AppVersion = '1.6.2'
# -Players "a#1","b#2" arrives as one comma-joined string when started with -File; split it.
if ($Players) { $Players = @($Players | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'Ranked 5s Ban Advisor' } catch {}
$IsCore    = $PSVersionTable.PSVersion.Major -ge 6
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# The League client uses a self-signed certificate on 127.0.0.1. Allow only that one.
if (-not $IsCore) {
    if (-not ('BanAdvisorCerts' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class BanAdvisorCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return problem == 0 || (req != null && req.RequestUri.Host == "127.0.0.1");
    }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object BanAdvisorCerts
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

function Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

# ---------------------------------------------------------------- state
$script:Conn        = $null
$script:Champs      = @{}      # id -> name
$script:ChampByNorm = @{}      # normalized name -> id
$script:Region      = 'na'
$script:RegionAuto  = $false   # true when the League client told us the region
$script:Mode        = 'auto'   # auto | client | screen
$script:Source      = ''       # client | screen (what produced the current enemies)
$script:Status      = 'starting'
$script:ClientState = 'no-client'
$script:Session     = $null
$script:Enemies     = @()      # current enemy players
$script:Identity    = @{}      # cellId -> resolved player (client)
$script:ScreenRows  = @{}      # row -> player (screen)
$script:ScreenAlly  = @()      # champion ids seen on your team (screen)
$script:ScreenNote  = ''
$script:OcrLines    = @()
$script:OcrReady    = $null
$script:OcrError    = ''
$script:WebError    = ''
$script:Data        = @{}      # player key -> fetched data
$script:GameCache   = @{}      # gameId -> game
$script:LastGameId  = $null
$script:StateKey    = ''
$script:StateJson   = '{}'
$script:Icons       = @{}      # champion id -> png bytes
$script:NextClient  = Get-Date
$script:NextScreen  = Get-Date
$script:WorkDir     = $ScriptDir
$script:SettingsFile = Join-Path $ScriptDir 'settings.json'
$script:LastTeam    = @()      # enemies kept after champ select ends (for the loading screen / in game)
$script:PostSelectAt = $null
$script:ScreenMisses = 0
$script:Poro        = @{ Status = 'none'; Next = (Get-Date); Tries = 0; Map = @{}; Note = '' }
$script:Phase       = ''
$script:NextFlow    = Get-Date
$script:LastEogId   = $null
$script:LastResult  = $null
$script:Record      = @{ W = 0; L = 0 }
$script:Donate      = ''
$script:RiotKey     = ''
$script:RiotStatus  = 'off'     # off | checking | ok | invalid | expired | error
$script:RiotNote    = ''
$script:RiotCalls   = New-Object System.Collections.Generic.List[double]
$script:RiotBlockedUntil = Get-Date '2000-01-01'
$script:RiotGames   = 12        # games per player from the Riot API (keeps within development-key rate limits)
$script:Regions     = @('na', 'euw', 'eune', 'kr', 'br', 'lan', 'las', 'oce', 'tr', 'ru', 'jp', 'ph', 'sg', 'th', 'tw', 'vn', 'me')

$Tiers = @{ IRON = 0.70; BRONZE = 0.75; SILVER = 0.80; GOLD = 0.85; PLATINUM = 0.90; EMERALD = 0.95
            DIAMOND = 1.00; MASTER = 1.10; GRANDMASTER = 1.15; CHALLENGER = 1.20 }

# ---------------------------------------------------------------- settings (the menu choice is remembered)
# The Riot API key is stored encrypted for the current Windows user (DPAPI) when possible.
function Protect-Secret([string]$t) {
    try {
        Add-Type -AssemblyName System.Security
        $b = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($t), $null, 'CurrentUser')
        return 'dpapi:' + [Convert]::ToBase64String($b)
    } catch { return 'plain:' + $t }
}
function Unprotect-Secret([string]$t) {
    try {
        if ($t -like 'dpapi:*') {
            Add-Type -AssemblyName System.Security
            $b = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($t.Substring(6)), $null, 'CurrentUser')
            return [Text.Encoding]::UTF8.GetString($b)
        }
        if ($t -like 'plain:*') { return $t.Substring(6) }
        return $t
    } catch { return '' }
}

function Load-Settings {
    try {
        if (Test-Path $script:SettingsFile) {
            $s = Get-Content $script:SettingsFile -Raw | ConvertFrom-Json
            if ($s.mode -in 'auto', 'client', 'screen') { $script:Mode = [string]$s.mode }
            if ($s.region -and $script:Regions -contains [string]$s.region) { $script:Region = [string]$s.region }
            if ($s.donateUrl) { $script:Donate = [string]$s.donateUrl }
            if ($s.riotKey) { $script:RiotKey = Unprotect-Secret ([string]$s.riotKey) }
        }
    } catch {}
    if ($Method) { $script:Mode = $Method }
    if (-not $script:Donate) { $script:Donate = $DefaultDonateUrl }
    if ($DonateUrl) { $script:Donate = $DonateUrl }
    if ($script:Donate -notmatch '^https://') { $script:Donate = '' }
}
function Save-Settings {
    $o = @{ mode = $script:Mode; region = $script:Region }
    if ($script:Donate -and $script:Donate -ne $DefaultDonateUrl) { $o.donateUrl = $script:Donate }
    if ($script:RiotKey) { $o.riotKey = Protect-Secret $script:RiotKey }
    try { ConvertTo-Json -InputObject $o | Set-Content -Path $script:SettingsFile -Encoding UTF8 } catch {}
}

# ---------------------------------------------------------------- League client connection
function Get-LcuConnection {
    if ($BaseUrl) { return @{ Base = $BaseUrl.TrimEnd('/'); Token = $Token } }
    $candidates = @()
    $proc = $null
    try { $proc = Get-CimInstance Win32_Process -Filter "Name='LeagueClientUx.exe'" -ErrorAction Stop | Select-Object -First 1 } catch {}
    if (-not $proc) { return $null }
    if ($proc.CommandLine) {
        $port = [regex]::Match($proc.CommandLine, '--app-port=(\d+)').Groups[1].Value
        $tok  = [regex]::Match($proc.CommandLine, '--remoting-auth-token=([^"\s]+)').Groups[1].Value
        if ($port -and $tok) { return @{ Base = "https://127.0.0.1:$port"; Token = $tok } }
    }
    if ($proc.ExecutablePath) { $candidates += (Join-Path (Split-Path $proc.ExecutablePath) 'lockfile') }
    $candidates += 'C:\Riot Games\League of Legends\lockfile', 'D:\Riot Games\League of Legends\lockfile'
    foreach ($lf in $candidates) {
        if (Test-Path $lf) {
            try {
                $fs = [System.IO.File]::Open($lf, 'Open', 'Read', 'ReadWrite')
                $sr = New-Object System.IO.StreamReader($fs); $txt = $sr.ReadToEnd(); $sr.Close()
                $parts = $txt.Split(':')
                if ($parts.Count -ge 4) { return @{ Base = "https://127.0.0.1:$($parts[2])"; Token = $parts[3] } }
            } catch {}
        }
    }
    return $null
}

function Invoke-Lcu([string]$Path) {
    if (-not $script:Conn) { return $null }
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('riot:' + $script:Conn.Token))
    $req = @{ Uri = $script:Conn.Base + $Path; Method = 'Get'; TimeoutSec = 10
              Headers = @{ Authorization = "Basic $auth"; Accept = 'application/json' } }
    if ($IsCore) { $req.SkipCertificateCheck = $true }
    try {
        $r = Invoke-WebRequest @req -UseBasicParsing -ErrorAction Stop
        $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
        return (ConvertFrom-Json -InputObject $txt)
    } catch { return $null }
}

function Normalize-Text([string]$s) { if (-not $s) { return '' }; return ([regex]::Replace($s.ToLowerInvariant(), '[^\p{L}\p{N}]', '')) }

# Chinese, Japanese (kana) and Korean (Hangul) characters
$script:CjkClass = '\u3040-\u30ff\u31f0-\u31ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff\uff66-\uff9f'
function Test-Cjk([string]$s) { return ($s -match "[$($script:CjkClass)]") }
function Repair-CjkSpacing([string]$s) { return [regex]::Replace($s, "(?<=[$($script:CjkClass)])\s+(?=[$($script:CjkClass)])", '') }

function Set-Champions($pairs) {
    foreach ($kv in $pairs) {
        $script:Champs[[int]$kv[0]] = [string]$kv[1]
        $script:ChampByNorm[(Normalize-Text ([string]$kv[1]))] = [int]$kv[0]
    }
}

function Initialize-ClientInfo {
    $list = Invoke-Lcu '/lol-game-data/assets/v1/champion-summary.json'
    $pairs = @(); foreach ($c in @($list)) { if ([int]$c.id -gt 0) { $pairs += , @([int]$c.id, [string]$c.name) } }
    Set-Champions $pairs
    $rl = Invoke-Lcu '/riotclient/region-locale'
    if ($rl -and $rl.region) {
        $r = ([string]$rl.region).ToUpper()
        $map = @{ LA1 = 'lan'; LA2 = 'las'; OC1 = 'oce'; NA1 = 'na'; EUW1 = 'euw'; EUN1 = 'eune'; BR1 = 'br'; TR1 = 'tr'; JP1 = 'jp'; KR = 'kr' }
        if ($map.ContainsKey($r)) { $script:Region = $map[$r] } else { $script:Region = $r.ToLower() }
        $script:RegionAuto = $true
    }
    Log ("Connected to League client. {0} champions loaded, region {1}." -f $script:Champs.Count, $script:Region)
}

# ---------------------------------------------------------------- web (op.gg + Riot's public champion list)
function Invoke-WebText([string]$Url, [switch]$Opgg) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
        if ($Opgg) { $wc.Headers['Origin'] = 'https://op.gg'; $wc.Headers['Referer'] = 'https://op.gg/' }
        $txt = $wc.DownloadString($Url)
        $wc.Dispose()
        $script:WebError = ''
        return $txt
    } catch { $script:WebError = $_.Exception.Message; return $null }
}

function Invoke-WebJson([string]$Url, [switch]$Opgg, [switch]$Timeline) {
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
        $wc.Headers['Accept'] = 'application/json'
        if ($Opgg) { $wc.Headers['Origin'] = 'https://op.gg'; $wc.Headers['Referer'] = 'https://op.gg/' }
        $txt = $wc.DownloadString($Url)
        $wc.Dispose()
        # op.gg includes a large per-minute score timeline we do not need
        $txt = [regex]::Replace($txt, '"op_score_timeline":\[[^\]]*\]', '"op_score_timeline":null')
        if ($Timeline) { $txt = [regex]::Replace($txt, '"(champion_stats|damage_stats)":\{[^{}]*\}', '"$1":null') }
        $script:WebError = ''
        return (ConvertFrom-Json -InputObject $txt)
    } catch {
        $script:WebError = $_.Exception.Message
        return $null
    }
}

function Initialize-ChampionsFromWeb {
    if ($script:Champs.Count -gt 0) { return }
    $vers = Invoke-WebJson 'https://ddragon.leagueoflegends.com/api/versions.json'
    if (-not $vers) { return }
    $v = @($vers)[0]
    $data = Invoke-WebJson "https://ddragon.leagueoflegends.com/cdn/$v/data/en_US/champion.json"
    if (-not $data) { return }
    $pairs = @()
    foreach ($prop in $data.data.PSObject.Properties) { $pairs += , @([int]$prop.Value.key, [string]$prop.Value.name) }
    Set-Champions $pairs
    Log "Loaded $($script:Champs.Count) champions from Riot's public list."
}

function ChampName($id) { $n = $script:Champs[[int]$id]; if ($n) { return $n } return "Champion $id" }

function Find-OpggPlayer($p) {
    $q = [uri]::EscapeDataString(($p.Name -replace '\s+$', ''))
    $r = Invoke-WebJson "$OpggBase/api/v3/$($script:Region)/summoners?riot_id=$q&hl=en_US" -Opgg
    $list = @(); if ($r -and $r.data) { $list = @($r.data) }
    if ($list.Count -eq 0) { return $null }
    $want = Normalize-Text (($p.Name -split '#')[0])
    $best = $list | Sort-Object -Descending -Property `
        @{ Expression = { if ((Normalize-Text ([string]$_.game_name)) -eq $want) { 1 } else { 0 } } },
        @{ Expression = { if ($_.solo_tier_info -and $_.solo_tier_info.tier) { 1 } else { 0 } } },
        @{ Expression = { [string]$_.revision_at } } | Select-Object -First 1
    return @{ Best = $best; Count = $list.Count }
}

function Get-OpggGames([string]$summonerId) {
    $r = Invoke-WebJson "$OpggBase/api/$($script:Region)/summoners/$summonerId/games?limit=$Games&game_type=total&hl=en_US" -Opgg
    $out = @()
    if (-not $r -or -not $r.data) { return , $out }
    foreach ($g in @($r.data)) {
        if ($g.game_map -ne 'SUMMONERS_RIFT' -or $g.is_remake -or [int]$g.game_length_second -lt 300) { continue }
        $parts = @(); $ids = @(); $num = 0
        foreach ($pp in @($g.participants)) {
            $num++
            $st = $pp.stats
            $team = 200; if ($pp.team_key -eq 'BLUE') { $team = 100 }
            $parts += [pscustomobject]@{
                participantId = $num; teamId = $team; championId = [int]$pp.champion_id; teamPosition = [string]$pp.position
                stats = [pscustomobject]@{
                    win = ($st.result -eq 'WIN'); kills = [int]$st.kill; deaths = [int]$st.death; assists = [int]$st.assist
                    totalMinionsKilled = [int]$st.minion_kill; neutralMinionsKilled = [int]$st.neutral_minion_kill
                    visionScore = [int]$st.vision_score; totalDamageDealtToChampions = [double]$st.total_damage_dealt_to_champions
                    firstBloodKill = $false; firstBloodAssist = $false }
            }
            $ids += [pscustomobject]@{ participantId = $num; player = [pscustomobject]@{
                puuid = [string]$pp.summoner.puuid; gameName = [string]$pp.summoner.game_name; tagLine = [string]$pp.summoner.tagline } }
        }
        $created = 0
        try { $created = ([DateTimeOffset]::Parse([string]$g.created_at)).ToUnixTimeMilliseconds() } catch {}
        $out += [pscustomobject]@{ gameId = 'opgg-' + $g.id; opggId = [string]$g.id; createdAt = [string]$g.created_at; mapId = 11; gameMode = 'CLASSIC'; queueId = [int]$g.queue_id
                                   gameDuration = [int]$g.game_length_second; gameCreation = $created
                                   participants = $parts; participantIdentities = $ids }
    }
    return , $out
}

# ---------------------------------------------------------------- identifying players (client)
function Format-Name($o) {
    if ($o.gameName) { if ($o.tagLine) { return "$($o.gameName)#$($o.tagLine)" } return [string]$o.gameName }
    if ($o.displayName) { return [string]$o.displayName }
    if ($o.summonerName) { return [string]$o.summonerName }
    return $null
}

function Get-SummonerByPuuid($puuid) {
    foreach ($p in "/lol-summoner/v2/summoners/puuid/$puuid", "/lol-summoner/v1/summoners-by-puuid-cached/$puuid") {
        $s = Invoke-Lcu $p
        if ($s -and $s.puuid) { return $s }
    }
    return $null
}

function New-Player($name, $puuid, $sid, $champ, $key, $hidden, $source) {
    return [pscustomobject]@{ Name = $name; OcrName = $name; Puuid = $puuid; SummonerId = $sid; ChampionId = $champ
                              Key = $key; Hidden = $hidden; Source = $source }
}

function Resolve-Member($m) {
    $cell = [string]$m.cellId
    $champ = [int]$m.championId
    if ($script:Identity.ContainsKey($cell)) {
        $p = $script:Identity[$cell]; $p.ChampionId = $champ; return $p
    }
    if ($m.nameVisibilityType -eq 'HIDDEN') { return New-Player '(hidden by game)' '' 0 $champ '' $true 'client' }
    $puuid = [string]$m.puuid
    $sid = 0; if ($m.summonerId) { $sid = [int64]$m.summonerId }
    $name = Format-Name $m
    $s = $null
    if ([string]::IsNullOrEmpty($puuid) -and $sid -gt 0) {
        $s = Invoke-Lcu "/lol-summoner/v1/summoners/$sid"
        if ($s) { $puuid = [string]$s.puuid }
    }
    if (-not [string]::IsNullOrEmpty($puuid) -and (-not $name -or $name -notmatch '#')) {
        if (-not $s) { $s = Get-SummonerByPuuid $puuid }
        if ($s) { $n2 = Format-Name $s; if ($n2) { $name = $n2 }; if (-not $sid -and $s.summonerId) { $sid = [int64]$s.summonerId } }
    }
    if ([string]::IsNullOrEmpty($puuid)) {
        if ($name) {   # name is visible but the client gave no id: look it up on op.gg instead
            $p = New-Player $name '' 0 $champ "name:$name" $false 'web'
            $script:Identity[$cell] = $p; return $p
        }
        return New-Player '(hidden by game)' '' 0 $champ '' $true 'client'
    }
    if (-not $name) { $name = 'Unknown player' }
    $p = New-Player $name $puuid $sid $champ $puuid $false 'client'
    $script:Identity[$cell] = $p
    Log "Enemy found: $name"
    return $p
}

function Resolve-ByRiotId([string]$riotId) {
    $parts = $riotId.Split('#', 2)
    $g = $parts[0]; $t = ''; if ($parts.Count -gt 1) { $t = $parts[1] }
    $q = '?gameName=' + [uri]::EscapeDataString($g) + '&tagLine=' + [uri]::EscapeDataString($t)
    $a = Invoke-Lcu "/lol-summoner/v1/alias/lookup$q"
    $puuid = ''; if ($a -and $a.puuid) { $puuid = [string]$a.puuid }
    $sid = 0
    if ($puuid) {
        $s = Get-SummonerByPuuid $puuid; if ($s -and $s.summonerId) { $sid = [int64]$s.summonerId }
        return New-Player $riotId $puuid $sid 0 $puuid $false 'client'
    }
    return New-Player $riotId '' 0 0 "name:$riotId" $false 'web'
}

# ---------------------------------------------------------------- screen reading
$script:WinApiLoaded = $false
$script:CjkEngines = @(); $script:OcrLangs = @()
function Initialize-Ocr {
    if ($script:OcrReady -ne $null) { return $script:OcrReady }
    try {
        if ($IsCore) { throw 'Screen reading needs Windows PowerShell 5.1. Start Ranked 5s Ban Advisor with the .exe or Start-BanAdvisor.bat.' }
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
        $null = [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
        $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
        $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics, ContentType = WindowsRuntime]
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
        $script:AsTask = @([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language 'en-US'))
        if (-not $script:OcrEngine) { $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
        $script:CjkEngines = @(); $script:OcrLangs = @()
        if ($script:OcrEngine) { $script:OcrLangs += [string]$script:OcrEngine.RecognizerLanguage.LanguageTag }
        foreach ($lang in [Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages) {
            $tag = [string]$lang.LanguageTag
            if ($tag -match '^(zh|ja|ko)') {
                $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
                if ($eng) { $script:CjkEngines += $eng; $script:OcrLangs += $tag }
            }
        }
        Log ("Text recognition languages: " + ($script:OcrLangs -join ', '))
        if (-not $script:OcrEngine) { throw 'Windows text recognition (OCR) is not installed for your language.' }
        if (-not ('BAWin' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class BAWin {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
        }
        [void][BAWin]::SetProcessDPIAware()
        $script:ScreenDir = Join-Path $script:WorkDir 'screen-debug'
        New-Item -ItemType Directory -Force -Path $script:ScreenDir | Out-Null
        $script:OcrReady = $true
        Log 'Screen reading is ready.'
    } catch {
        $script:OcrReady = $false
        $script:OcrError = $_.Exception.Message
        Log "Screen reading unavailable: $($script:OcrError)"
    }
    return $script:OcrReady
}

function Wait-WinRt($op, [type]$resultType) {
    $t = $script:AsTask.MakeGenericMethod($resultType).Invoke($null, @($op))
    [void]$t.Wait(-1)
    return $t.Result
}

function Invoke-Ocr([string]$path, $engine = $null) {
    if (-not $engine) { $engine = $script:OcrEngine }
    $file = Wait-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Wait-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $dec = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bmp = Wait-WinRt ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $res = Wait-WinRt ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
    } finally { $stream.Dispose() }
    $lines = @()
    foreach ($l in $res.Lines) {
        $w = @($l.Words); if ($w.Count -eq 0) { continue }
        $y = ($w | ForEach-Object { $_.BoundingRect.Y } | Measure-Object -Minimum).Minimum
        $h = ($w | ForEach-Object { $_.BoundingRect.Height } | Measure-Object -Maximum).Maximum
        $lines += [pscustomobject]@{ Text = (Repair-CjkSpacing ([string]$l.Text)); Y = [double]$y; H = [double]$h }
    }
    return , $lines
}

function Test-MostlyBlack($bmp) {
    $sum = 0; $n = 0
    for ($i = 1; $i -le 9; $i++) { for ($j = 1; $j -le 9; $j++) {
        $c = $bmp.GetPixel([int]($bmp.Width * $i / 10), [int]($bmp.Height * $j / 10)); $sum += $c.R + $c.G + $c.B; $n++ } }
    return ($sum / ($n * 3)) -lt 6
}

function Get-LeagueWindowImage {
    $h = [BAWin]::FindWindow('RCLIENT', $null)
    if ($h -eq [IntPtr]::Zero) {
        $pr = Get-Process -Name LeagueClientUx -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
        if ($pr) { $h = $pr.MainWindowHandle }
    }
    if ($h -eq [IntPtr]::Zero) { $script:ScreenNote = 'League window not found. Open the League client.'; return $null }
    if ([BAWin]::IsIconic($h)) { $script:ScreenNote = 'The League window is minimized. Restore it so it can be read.'; return $null }
    $r = New-Object BAWin+RECT
    [void][BAWin]::GetWindowRect($h, [ref]$r)
    $w = $r.Right - $r.Left; $hh = $r.Bottom - $r.Top
    if ($w -lt 400 -or $hh -lt 300) { $script:ScreenNote = 'The League window is too small to read.'; return $null }
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc(); $ok = [BAWin]::PrintWindow($h, $hdc, 2); $g.ReleaseHdc($hdc); $g.Dispose()
    if (-not $ok -or (Test-MostlyBlack $bmp)) {
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
        $g.Dispose()
    }
    return $bmp
}

# Crops part of the window (fractions of width/height), enlarges it, and turns
# light text on a dark background into black text on white for better OCR.
function Save-Crop($bmp, [double]$x0, [double]$y0, [double]$x1, [double]$y1, [string]$path) {
    $W = $bmp.Width; $H = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle ([int]($x0 * $W)), ([int]($y0 * $H)), ([int](($x1 - $x0) * $W)), ([int](($y1 - $y0) * $H))
    $scale = [Math]::Min(3.0, 2400.0 / [Math]::Max(1, $rect.Height))
    $out = New-Object System.Drawing.Bitmap ([int]($rect.Width * $scale)), ([int]($rect.Height * $scale))
    $g = [System.Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $c = 1.8; $a = [single](-0.30 * $c); $b = [single](-0.59 * $c); $d = [single](-0.11 * $c)
    $m = [single[][]]@([single[]]@($a, $a, $a, 0, 0), [single[]]@($b, $b, $b, 0, 0), [single[]]@($d, $d, $d, 0, 0),
                       [single[]]@(0, 0, 0, 1, 0), [single[]]@(1, 1, 1, 0, 1))
    $cm = New-Object System.Drawing.Imaging.ColorMatrix -ArgumentList (, $m)
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($cm)
    $g.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0, 0, $out.Width, $out.Height), $rect.X, $rect.Y, $rect.Width, $rect.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
    $g.Dispose()
    $out.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $height = $out.Height
    $out.Dispose()
    return $height
}

# Champ select layout (fractions of the League window). Five rows per team.
$script:RowTop = 0.128; $script:RowBottom = 0.686
$script:EnemyCols = @(0.815, 0.927)
$script:AllyCols  = @(0.09, 0.27)

function Split-Rows($lines, [double]$height) {
    $rows = @{}; for ($i = 0; $i -lt 5; $i++) { $rows[$i] = @() }
    $rowH = $height / 5.0
    foreach ($l in ($lines | Sort-Object Y)) {
        $i = [int][Math]::Floor(($l.Y + $l.H / 2) / $rowH)
        if ($i -ge 0 -and $i -lt 5) { $rows[$i] += $l }
    }
    return $rows
}

function Get-RowInfo($rowLines) {
    $champ = 0; $name = $null
    foreach ($l in $rowLines) {
        $t = ($l.Text -replace '\s+', ' ').Trim()
        if ($t.Length -lt 2) { continue }
        if ($t -match '^(banning|picking|ban|pick|declined|locked|swap)\b' -or $t -match '\.\.\.?$' -or $t -match '^[\d\s:]+$') { continue }
        $n = Normalize-Text $t
        if ($n -in 'top', 'jungle', 'mid', 'middle', 'bottom', 'bot', 'support', 'utility', 'fill', 'next') { continue }
        if ($n -and $script:ChampByNorm.ContainsKey($n)) { $champ = $script:ChampByNorm[$n]; continue }
        # drop stray marks the portrait glow or timer can add at the edges
        $tok = @($t -split ' ' | Where-Object { $_ -match '[\p{L}\p{N}]' })
        if ($tok.Count -gt 1 -and $tok[-1].Length -le 2 -and -not (Test-Cjk $tok[-1])) { $tok = $tok[0..($tok.Count - 2)] }
        if ($tok.Count -gt 1 -and $tok[0].Length -le 1 -and -not (Test-Cjk $tok[0])) { $tok = $tok[1..($tok.Count - 1)] }
        if ($tok.Count -gt 0) { $name = ($tok -join ' ') }
    }
    return @{ Champ = $champ; Name = $name }
}

function Get-Distance([string]$a, [string]$b) {
    $a = $a.ToLowerInvariant(); $b = $b.ToLowerInvariant()
    if ($a -eq $b) { return 0 }
    $prev = 0..$b.Length
    for ($i = 1; $i -le $a.Length; $i++) {
        $cur = @($i) + (@(0) * $b.Length)
        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = 1; if ($a[$i - 1] -eq $b[$j - 1]) { $cost = 0 }
            $cur[$j] = [Math]::Min([Math]::Min($cur[$j - 1] + 1, $prev[$j] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    return $prev[$b.Length]
}

function Update-FromScreen {
    if (-not (Initialize-Ocr)) { $script:ScreenNote = $script:OcrError; return $false }
    Initialize-ChampionsFromWeb
    $bmp = $null
    try {
        $bmp = Get-LeagueWindowImage
        if (-not $bmp) { return $false }
        $ePath = Join-Path $script:ScreenDir 'enemy.png'; $aPath = Join-Path $script:ScreenDir 'ally.png'
        $eH = Save-Crop $bmp $script:EnemyCols[0] $script:RowTop $script:EnemyCols[1] $script:RowBottom $ePath
        $aH = Save-Crop $bmp $script:AllyCols[0] $script:RowTop $script:AllyCols[1] $script:RowBottom $aPath
        $hPath = Join-Path $script:ScreenDir 'header.png'
        $null = Save-Crop $bmp 0.28 0.0 0.72 0.13 $hPath
        $hText = (@(Invoke-Ocr $hPath) | ForEach-Object { $_.Text }) -join ' '
        $eLines = Invoke-Ocr $ePath
        $eText = (@($eLines) | ForEach-Object { $_.Text }) -join ' '
        if ($hText -notmatch '(?i)choose|champion|ban|pick|loadout|declare|planning|lock' -and $eText -notmatch '(?i)banning|picking') {
            $script:ScreenNote = 'League window found, but it is not on the champ select screen.'
            $script:OcrLines = @($hText)
            # (keep known players; a bad frame is not the end of champ select)
            return $false
        }
        $aLines = Invoke-Ocr $aPath
        $cjkSets = @()
        foreach ($eng in $script:CjkEngines) { $cjkSets += , (Invoke-Ocr $ePath $eng) }
    } catch {
        $script:ScreenNote = "Screen reading error: $($_.Exception.Message)"
        return $false
    } finally { if ($bmp) { $bmp.Dispose() } }

    $script:OcrLines = @($eLines | ForEach-Object { $_.Text })
    foreach ($set in $cjkSets) { $script:OcrLines += @($set | Where-Object { Test-Cjk $_.Text } | ForEach-Object { $_.Text }) }
    $eRows = Split-Rows $eLines $eH
    $cjkRows = @(); foreach ($set in $cjkSets) { $cjkRows += , (Split-Rows $set $eH) }
    $aRows = Split-Rows $aLines $aH
    $ally = @(); for ($i = 0; $i -lt 5; $i++) { $ri = Get-RowInfo $aRows[$i]; if ($ri.Champ) { $ally += $ri.Champ } }

    $players = @(); $found = 0
    for ($i = 0; $i -lt 5; $i++) {
        $ri = Get-RowInfo $eRows[$i]
        # Prefer a Chinese/Japanese/Korean reading when one of those recognizers found such characters in this row
        foreach ($cr in $cjkRows) {
            $ci = Get-RowInfo $cr[$i]
            if ($ci.Name -and (Test-Cjk $ci.Name) -and -not (Test-Cjk $ri.Name)) { $ri.Name = $ci.Name; if (-not $ri.Champ) { $ri.Champ = $ci.Champ }; break }
        }
        if (-not $ri.Name) { continue }
        $found++
        $old = $script:ScreenRows[$i]
        if (-not ($old -and (Get-Distance $old.OcrName $ri.Name) -le 2)) {
            foreach ($cand in @($script:ScreenRows.Values)) { if ($cand -and (Get-Distance $cand.OcrName $ri.Name) -le 2) { $old = $cand; $script:ScreenRows[$i] = $cand; break } }
        }
        if ($old -and (Get-Distance $old.OcrName $ri.Name) -le 2) {
            $old.ChampionId = $ri.Champ; $players += $old
        } else {
            $p = New-Player $ri.Name '' 0 $ri.Champ "screen:${i}:$($ri.Name)" $false 'web'
            $script:ScreenRows[$i] = $p
            Log "Read from screen: $($ri.Name)"
            $players += $p
        }
    }
    if ($found -eq 0) {
        $script:ScreenNote = 'League window found, but no champ select names were read. Keep the champ select screen visible.'
        # (keep known players; a bad frame is not the end of champ select)
        return $false
    }
    $script:ScreenNote = ''
    $script:ScreenAlly = $ally
    $script:Enemies = $players
    return $true
}

# ---------------------------------------------------------------- fetching data (one call per step)
function Get-Rank($puuid) {
    $r = Invoke-Lcu "/lol-ranked/v1/ranked-stats/$puuid"
    if (-not $r) { return $null }
    $q = $null
    if ($r.queueMap) { $q = $r.queueMap.RANKED_SOLO_5x5 }
    if (-not $q -or -not $q.tier -or $q.tier -eq 'NONE') {
        if ($r.queueMap -and $r.queueMap.RANKED_FLEX_SR -and $r.queueMap.RANKED_FLEX_SR.tier -and $r.queueMap.RANKED_FLEX_SR.tier -ne 'NONE') { $q = $r.queueMap.RANKED_FLEX_SR }
        elseif ($r.highestRankedEntry -and $r.highestRankedEntry.tier -and $r.highestRankedEntry.tier -ne 'NONE') { $q = $r.highestRankedEntry }
        else { return $null }
    }
    return @{ Tier = [string]$q.tier; Division = [string]$q.division; LP = [int]$q.leaguePoints }
}

function Get-Mastery($p) {
    $m = Invoke-Lcu "/lol-champion-mastery/v1/$($p.Puuid)/champion-mastery"
    if (-not $m -and $p.SummonerId -gt 0) { $m = Invoke-Lcu "/lol-collections/v1/inventories/$($p.SummonerId)/champion-mastery" }
    if ($m -and $m -isnot [array] -and $m.PSObject.Properties['masteries']) { $m = $m.masteries }
    $out = @{}
    foreach ($e in @($m)) { if ($e -and $e.championId) { $out[[int]$e.championId] = [int64]$e.championPoints } }
    return $out
}

function Get-MatchList($puuid) {
    $mh = Invoke-Lcu "/lol-match-history/v1/products/lol/$puuid/matches?begIndex=0&endIndex=$([Math]::Min(49, $Games * 2))"
    $list = @()
    if ($mh -and $mh.games -and $mh.games.games) { $list = @($mh.games.games) }
    $sr = @($list | Where-Object { $_.mapId -eq 11 -and (-not $_.gameMode -or $_.gameMode -eq 'CLASSIC') -and $_.gameDuration -ge 300 })
    $sr = @($sr | Sort-Object { [int64]$_.gameCreation } -Descending | Select-Object -First $Games)
    return , $sr
}

# A player object can be re-created (for example after a misread screen frame). Give it back
# the identity its data was resolved to, so its games still match.
function Sync-Player($p, $d) {
    if (-not $p -or -not $d) { return }
    if ($d.Puuid -and -not $p.Puuid) { $p.Puuid = $d.Puuid }
    if ($d.Name -and $p.Name -notmatch '#') { $p.Name = $d.Name }
    if (-not $d.Puuid -and $p.Puuid) { $d.Puuid = $p.Puuid }
    if (-not $d.Name -and $p.Name -match '#') { $d.Name = $p.Name }
}

function Step-Work {
    foreach ($p in $script:Enemies) {
        if ($p.Hidden -or -not $p.Key) { continue }
        $d = $script:Data[$p.Key]
        Sync-Player $p $d
        if (-not $d) {
            $first = 'rank'; if ($p.Source -eq 'web') { $first = 'search' }
            $d = @{ Stage = $first; Next = 0; Rank = $null; Mastery = @{}; List = @(); Done = $false; Error = ''; Note = ''; OpggId = '' }
            $script:Data[$p.Key] = $d
            Log "Analyzing $($p.Name)..."
        }
        if ($d.Done) { continue }
        if ($d.Stage -eq 'rank')    { $d.Rank = Get-Rank $p.Puuid; $d.Stage = 'mastery'; return $true }
        if ($d.Stage -eq 'mastery') { $d.Mastery = Get-Mastery $p; $d.Stage = 'list'; return $true }
        if ($d.Stage -eq 'list') {
            $d.List = Get-MatchList $p.Puuid
            if ($d.List.Count -eq 0 -and (Test-RiotReady)) { Log "No match history from the client for $($p.Name); using the Riot API."; $d.Stage = 'riotlist' }
            elseif ($d.List.Count -eq 0 -and $p.Name -match '#') { Log "No match history from the client for $($p.Name); trying op.gg."; $d.Stage = 'search' }
            else { $d.Stage = 'games' }
            return $true
        }
        if ($d.Stage -eq 'search' -and (Test-RiotReady) -and $p.Name -match '#' -and -not $d.TriedRiotAccount) {
            if (-not (Test-RiotBudget)) { continue }
            $d.TriedRiotAccount = $true
            $acc = Get-RiotAccount $p.Name
            if ($acc -and $acc.puuid) {
                $p.Puuid = [string]$acc.puuid; $p.Name = "$($acc.gameName)#$($acc.tagLine)"; $d.Name = $p.Name; $d.Puuid = $p.Puuid
                $d.Stage = 'riotrank'
            }
            return $true
        }
        if ($d.Stage -eq 'search') {
            $found = Find-OpggPlayer $p
            if (-not $found) {
                $d.Error = "Couldn't find '$($p.Name)' on op.gg ($($script:Region.ToUpper()))."
                if ($script:WebError) { $d.Error += " $($script:WebError)" }
                $d.Done = $true; Log $d.Error; return $true
            }
            $b = $found.Best
            if ($found.Count -gt 1 -and $p.Name -notmatch '#') { $d.Note = "Best match of $($found.Count) accounts with this name" }
            $p.Name = "$($b.game_name)#$($b.tagline)"
            if (-not $p.Puuid) { $p.Puuid = [string]$b.puuid }
            $d.Name = $p.Name; $d.Puuid = $p.Puuid
            $d.OpggId = [string]$b.summoner_id
            if (-not $d.Rank -and $b.solo_tier_info -and $b.solo_tier_info.tier) {
                $roman = @('', 'I', 'II', 'III', 'IV')
                $div = [int]$b.solo_tier_info.division
                $d.Rank = @{ Tier = [string]$b.solo_tier_info.tier; Division = $(if ($div -ge 1 -and $div -le 4) { $roman[$div] } else { '' }); LP = [int]$b.solo_tier_info.lp }
            }
            $d.Stage = 'webgames'
            if (Test-RiotReady) { $d.Stage = 'riotmastery' }   # op.gg found the account; the Riot API gives the games
            return $true
        }
        # Riot API stages (one call per step, paced to the key's rate limits)
        if ($d.Stage -in 'riotrank', 'riotmastery', 'riotlist', 'riotgames') {
            if (-not (Test-RiotReady)) { $d.Stage = $(if ($d.OpggId) { 'webgames' } else { 'search' }); return $true }
            if (-not (Test-RiotBudget)) { continue }
            if ($d.Stage -eq 'riotrank') { $rk = Get-RiotRank $p.Puuid; if ($rk) { $d.Rank = $rk }; $d.Stage = 'riotmastery'; return $true }
            if ($d.Stage -eq 'riotmastery') { $d.Mastery = Get-RiotMastery $p.Puuid; $d.Stage = 'riotlist'; return $true }
            if ($d.Stage -eq 'riotlist') {
                $d.RiotIds = Get-RiotMatchIds $p.Puuid; $d.RiotNext = 0; $d.List = @(); $d.Stage = 'riotgames'
                if (-not $d.Rank) { $rk = $null }   # rank comes from riotrank when that stage ran
                return $true
            }
            if ($d.RiotNext -lt @($d.RiotIds).Count) {
                $mid = [string]$d.RiotIds[$d.RiotNext]; $d.RiotNext++
                $key = 'riot-' + $mid
                if (-not $script:GameCache.ContainsKey($key)) {
                    $g = Get-RiotMatch $mid
                    if ($g -and $g.retry) { $d.RiotNext--; return $true }    # rate limited: try this game again shortly
                    if ($g -and -not $g.skip) { $script:GameCache[$key] = $g }
                }
                if ($script:GameCache.ContainsKey($key)) { $d.List = @($d.List) + @($script:GameCache[$key]) }
                return $true
            }
            if ($d.List.Count -eq 0) { $d.Error = 'The Riot API returned no recent Summoner''s Rift games.' }
            $d.Done = $true
            Log ("Finished {0}: {1} recent games (Riot API)" -f $p.Name, $d.List.Count)
            return $true
        }
        if ($d.Stage -eq 'webgames') {
            $d.List = Get-OpggGames $d.OpggId
            foreach ($g in $d.List) { $script:GameCache[[string]$g.gameId] = $g }
            if ($d.List.Count -eq 0) { $d.Error = 'op.gg returned no recent games.'; if ($script:WebError) { $d.Error += " $($script:WebError)" } }
            $d.Done = $true
            Log ("Finished {0}: {1} recent games (op.gg)" -f $p.Name, $d.List.Count)
            return $true
        }
        while ($d.Next -lt $d.List.Count) {
            $g = $d.List[$d.Next]; $d.Next++
            $key = [string]$g.gameId
            if ($script:GameCache.ContainsKey($key)) { continue }
            if (@($g.participantIdentities).Count -ge 10) { $script:GameCache[$key] = $g; continue }
            $full = Invoke-Lcu "/lol-match-history/v1/games/$key"
            if ($full -and $full.participants) { $script:GameCache[$key] = $full } else { $script:GameCache[$key] = $g }
            return $true
        }
        $d.Done = $true
        Log ("Finished {0}: {1} recent games" -f $p.Name, $d.List.Count)
        return $true
    }
    # Second pass: once a player locks in, study their jungle pathing (one timeline per step).
    foreach ($p in @($script:Enemies) + @($script:LastTeam)) {
        if ($p.Hidden -or -not $p.Key -or $p.ChampionId -le 0) { continue }
        $d = $script:Data[$p.Key]
        Sync-Player $p $d
        if (-not $d -or -not $d.Done -or $d.PathDone) { continue }
        if (-not $d.PathPlanned) {
            $d.PathGames = Get-PathingGames $p $d
            $roles = @{}
            foreach ($lg in $d.List) { $g = $script:GameCache[[string]$lg.gameId]; if (-not $g) { $g = $lg }; $me = Find-Me $g $p.Puuid; if ($me) { $r = Get-Role $me; if ($r) { $roles[$r] = 1 + [int]$roles[$r] } } }
            $d.JungleMain = ($roles.Count -gt 0 -and ($roles.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key -eq 'Jungle')
            $onChampJg = @($d.PathGames | Where-Object { $_.champ -eq $p.ChampionId }).Count -gt 0
            if (-not $onChampJg -and -not $d.JungleMain) { $d.PathGames = @() }   # not playing jungle this game
            $d.Timelines = @{}; $d.PathNext = 0; $d.PathPlanned = $true
            if ($d.PathGames.Count -gt 0) { Log "Studying $($p.Name)'s jungle pathing..." }
            return $true
        }
        if ($d.PathNext -lt $d.PathGames.Count) {
            $g = $d.PathGames[$d.PathNext].g; $d.PathNext++
            $tl = $null
            if ($g.riotId) {
                if (-not (Test-RiotBudget)) { $d.PathNext--; continue }
                $tl = Get-TimelineRiot $g
            } elseif ($g.opggId) { $tl = Get-TimelineOpgg $g } else { $tl = Get-TimelineLcu $g.gameId }
            if ($tl) { $d.Timelines[[string]$g.gameId] = $tl }
            return $true
        }
        $d.PathDone = $true
        return $true
    }
    return $false
}

# ---------------------------------------------------------------- Riot Games API (optional, needs the player's own API key)
function Get-RiotPlatform {
    $m = @{ na = 'na1'; euw = 'euw1'; eune = 'eun1'; kr = 'kr'; br = 'br1'; lan = 'la1'; las = 'la2'; oce = 'oc1'; tr = 'tr1'; ru = 'ru'
            jp = 'jp1'; ph = 'ph2'; sg = 'sg2'; th = 'th2'; tw = 'tw2'; vn = 'vn2'; me = 'me1' }
    if ($m.ContainsKey($script:Region)) { return $m[$script:Region] }; return 'na1'
}
function Get-RiotRegional([switch]$Account) {
    $r = $script:Region
    if ($r -in 'na', 'br', 'lan', 'las') { return 'americas' }
    if ($r -in 'euw', 'eune', 'tr', 'ru', 'me') { return 'europe' }
    if ($r -in 'kr', 'jp') { return 'asia' }
    if ($Account) { return 'asia' }      # account-v1 has no "sea" cluster
    return 'sea'
}
function Test-RiotReady { return ($script:RiotKey -and $script:RiotStatus -eq 'ok') }

# Development keys allow 20 calls per second and 100 per 2 minutes. Stay under both.
function Test-RiotBudget {
    $now = [double](Get-Date).Ticks / 1e7
    while ($script:RiotCalls.Count -gt 0 -and $script:RiotCalls[0] -lt $now - 120) { $script:RiotCalls.RemoveAt(0) }
    if ((Get-Date) -lt $script:RiotBlockedUntil) { return $false }
    $lastSec = @($script:RiotCalls | Where-Object { $_ -gt $now - 1 }).Count
    return ($lastSec -lt 18 -and $script:RiotCalls.Count -lt 95)
}

# Returns @{ ok; status; data }. status 429 = rate limited (waits as Riot asks), 401/403 = key problem.
function Invoke-Riot([string]$cluster, [string]$path) {
    $script:RiotCalls.Add([double](Get-Date).Ticks / 1e7)
    $base = "https://$cluster.api.riotgames.com"; if ($RiotBase) { $base = $RiotBase.TrimEnd('/') + "/$cluster" }
    $req = @{ Uri = $base + $path; Method = 'Get'; TimeoutSec = 12; UseBasicParsing = $true; Headers = @{ 'X-Riot-Token' = $script:RiotKey } }
    try {
        $r = Invoke-WebRequest @req -ErrorAction Stop
        $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        return @{ ok = $true; status = 200; data = (ConvertFrom-Json -InputObject $txt) }
    } catch {
        $code = 0; $retry = 10
        try { $code = [int]$_.Exception.Response.StatusCode } catch {}
        try { $ra = $_.Exception.Response.Headers['Retry-After']; if ($ra) { $retry = [int]$ra } } catch {}
        try { if ($_.Exception.Response.Headers.RetryAfter.Delta) { $retry = [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds } } catch {}
        if ($code -eq 429) { $script:RiotBlockedUntil = (Get-Date).AddSeconds([Math]::Max(1, $retry)); Log "Riot API rate limit reached; waiting $retry s." }
        if ($code -in 401, 403) {
            $script:RiotStatus = 'expired'
            $script:RiotNote = 'The Riot API key was rejected. Development keys expire every 24 hours; paste a new one.'
            Log $script:RiotNote
        }
        return @{ ok = $false; status = $code; data = $null }
    }
}

function Test-RiotKey {
    if (-not $script:RiotKey) { $script:RiotStatus = 'off'; $script:RiotNote = ''; return }
    $script:RiotStatus = 'checking'
    $r = Invoke-Riot (Get-RiotPlatform) '/lol/status/v4/platform-data'
    if ($r.ok) { $script:RiotStatus = 'ok'; $script:RiotNote = "Using the $((Get-RiotPlatform).ToUpper()) server."; Log 'Riot API key works.' }
    elseif ($r.status -in 401, 403) { $script:RiotStatus = 'invalid'; $script:RiotNote = 'Riot rejected this key. Check it, or get a new one (development keys expire every 24 hours).' }
    else { $script:RiotStatus = 'error'; $script:RiotNote = "Couldn't reach the Riot API (code $($r.status))."; }
}

function Get-RiotAccount([string]$riotId) {
    $parts = $riotId.Split('#', 2); if ($parts.Count -lt 2) { return $null }
    $r = Invoke-Riot (Get-RiotRegional -Account) ("/riot/account/v1/accounts/by-riot-id/" + [uri]::EscapeDataString($parts[0]) + '/' + [uri]::EscapeDataString($parts[1]))
    if ($r.ok) { return $r.data }; return $null
}

function Get-RiotRank([string]$puuid) {
    $r = Invoke-Riot (Get-RiotPlatform) "/lol/league/v4/entries/by-puuid/$puuid"
    if (-not $r.ok) { return $null }
    $e = @($r.data) | Where-Object { $_.queueType -eq 'RANKED_SOLO_5x5' } | Select-Object -First 1
    if (-not $e) { $e = @($r.data) | Where-Object { $_.queueType -eq 'RANKED_FLEX_SR' } | Select-Object -First 1 }
    if (-not $e) { return $null }
    return @{ Tier = [string]$e.tier; Division = [string]$e.rank; LP = [int]$e.leaguePoints }
}

function Get-RiotMastery([string]$puuid) {
    $out = @{}
    $r = Invoke-Riot (Get-RiotPlatform) "/lol/champion-mastery/v4/champion-masteries/by-puuid/$puuid/top?count=10"
    if ($r.ok) { foreach ($m in @($r.data)) { $out[[int]$m.championId] = [int64]$m.championPoints } }
    return $out
}

function Get-RiotMatchIds([string]$puuid) {
    $r = Invoke-Riot (Get-RiotRegional) "/lol/match/v5/matches/by-puuid/$puuid/ids?start=0&count=$([Math]::Min($Games, $script:RiotGames))"
    if ($r.ok) { return , @($r.data) }; return , @()
}

# Converts a match-v5 game to the same shape the League client uses, so the analysis code is shared.
function Get-RiotMatch([string]$matchId) {
    $r = Invoke-Riot (Get-RiotRegional) "/lol/match/v5/matches/$matchId"
    if ($r.status -eq 429) { return @{ retry = $true } }
    if (-not $r.ok -or -not $r.data.info) { return $null }
    $i = $r.data.info
    if ([int]$i.mapId -ne 11 -or ($i.gameMode -and $i.gameMode -ne 'CLASSIC')) { return @{ skip = $true } }
    $dur = [int]$i.gameDuration; if ($dur -gt 100000) { $dur = [int]($dur / 1000) }   # very old games used milliseconds
    if ($dur -lt 300) { return @{ skip = $true } }
    $parts = @(); $ids = @()
    foreach ($pp in @($i.participants)) {
        $parts += [pscustomobject]@{
            participantId = [int]$pp.participantId; teamId = [int]$pp.teamId; championId = [int]$pp.championId; teamPosition = [string]$pp.teamPosition
            stats = [pscustomobject]@{ win = [bool]$pp.win; kills = [int]$pp.kills; deaths = [int]$pp.deaths; assists = [int]$pp.assists
                totalMinionsKilled = [int]$pp.totalMinionsKilled; neutralMinionsKilled = [int]$pp.neutralMinionsKilled; visionScore = [int]$pp.visionScore
                totalDamageDealtToChampions = [double]$pp.totalDamageDealtToChampions; firstBloodKill = [bool]$pp.firstBloodKill; firstBloodAssist = [bool]$pp.firstBloodAssist }
        }
        $ids += [pscustomobject]@{ participantId = [int]$pp.participantId; player = [pscustomobject]@{ puuid = [string]$pp.puuid; gameName = [string]$pp.riotIdGameName; tagLine = [string]$pp.riotIdTagline } }
    }
    return [pscustomobject]@{ gameId = 'riot-' + $matchId; riotId = $matchId; mapId = 11; gameMode = 'CLASSIC'; queueId = [int]$i.queueId
                              gameDuration = $dur; gameCreation = [int64]$i.gameCreation; participants = $parts; participantIdentities = $ids }
}

function Get-TimelineRiot($g) {
    if (-not $g.riotId) { return $null }
    $r = Invoke-Riot (Get-RiotRegional) "/lol/match/v5/matches/$($g.riotId)/timeline"
    if (-not $r.ok -or -not $r.data.info) { return $null }
    $map = @{}
    foreach ($pp in @($r.data.info.participants)) { if ($pp.puuid) { $map[[string]$pp.puuid] = [int]$pp.participantId } }
    $frames = @(); $kills = @()
    foreach ($f in @($r.data.info.frames)) {
        $pos = @{}
        if ($f.participantFrames) { foreach ($prop in $f.participantFrames.PSObject.Properties) { $pf = $prop.Value; if ($pf.position) { $pos[[int]$prop.Name] = @([int]$pf.position.x, [int]$pf.position.y) } } }
        $frames += @{ ts = [int64]$f.timestamp; pos = $pos }
        foreach ($e in @($f.events)) {
            if ($e.type -eq 'CHAMPION_KILL' -and $e.position) {
                $kills += @{ ts = [int64]$e.timestamp; killer = [int]$e.killerId; victim = [int]$e.victimId
                             assists = @(@($e.assistingParticipantIds) | Where-Object { $_ -ne $null } | ForEach-Object { [int]$_ }); x = [int]$e.position.x; y = [int]$e.position.y }
            }
        }
    }
    return @{ frames = $frames; kills = $kills; pidByPuuid = $map }
}

# ---------------------------------------------------------------- timelines (for jungle pathing)
function Get-TimelineLcu($gameId) {
    $t = Invoke-Lcu "/lol-match-history/v1/game-timelines/$gameId"
    if (-not $t -or -not $t.frames) { return $null }
    $frames = @(); $kills = @()
    foreach ($f in @($t.frames)) {
        $pos = @{}
        if ($f.participantFrames) {
            foreach ($prop in $f.participantFrames.PSObject.Properties) {
                $pf = $prop.Value
                if ($pf.position) { $pos[[int]$prop.Name] = @([int]$pf.position.x, [int]$pf.position.y) }
            }
        }
        $frames += @{ ts = [int64]$f.timestamp; pos = $pos }
        foreach ($e in @($f.events)) {
            if ($e.type -eq 'CHAMPION_KILL' -and $e.position) {
                $kills += @{ ts = [int64]$e.timestamp; killer = [int]$e.killerId; victim = [int]$e.victimId
                             assists = @(@($e.assistingParticipantIds) | ForEach-Object { [int]$_ }); x = [int]$e.position.x; y = [int]$e.position.y }
            }
        }
    }
    return @{ frames = $frames; kills = $kills; pidByPuuid = $null }
}

function Get-TimelineOpgg($g) {
    if (-not $g.opggId) { return $null }
    $url = "$OpggBase/api/$($script:Region)/games/$([uri]::EscapeDataString($g.opggId))/analysis?created_at=$([uri]::EscapeDataString($g.createdAt))&hl=en_US"
    $r = Invoke-WebJson $url -Opgg -Timeline
    if (-not $r -or -not $r.data -or -not $r.data.timeline) { return $null }
    $map = @{}
    foreach ($pp in @($r.data.participants)) { $map[[string]$pp.puuid] = [int]$pp.participant_id }
    $frames = @(); $kills = @()
    foreach ($f in @($r.data.timeline.frames)) {
        $pos = @{}
        foreach ($pf in @($f.participant_frames)) { if ($pf.position) { $pos[[int]$pf.participant_id] = @([int]$pf.position.x, [int]$pf.position.y) } }
        $frames += @{ ts = [int64]$f.timestamp; pos = $pos }
        foreach ($e in @($f.events)) {
            if ($e.type -eq 'CHAMPION_KILL' -and $e.position) {
                $kills += @{ ts = [int64]$e.timestamp; killer = [int]$e.killer_id; victim = [int]$e.victim_id
                             assists = @(@($e.assisting_participant_ids) | Where-Object { $_ -ne $null } | ForEach-Object { [int]$_ }); x = [int]$e.position.x; y = [int]$e.position.y }
            }
        }
    }
    return @{ frames = $frames; kills = $kills; pidByPuuid = $map }
}

# Map coordinates: blue base bottom-left (0,0), red base top-right (~14800,14800).
function Get-Lane([int]$x, [int]$y) {
    if (($x -lt 2300 -and $y -gt 5500) -or ($y -gt 12500 -and $x -lt 9300)) { return 'top' }
    if (($y -lt 2300 -and $x -gt 5500) -or ($x -gt 12500 -and $y -lt 9300)) { return 'bot' }
    if ([Math]::Abs($x - $y) -lt 900 -and $x -gt 4000 -and $x -lt 10800) { return 'mid' }
    return ''
}

function Find-Me($g, [string]$puuid) {
    $ids = @($g.participantIdentities); $parts = @($g.participants)
    $id = $ids | Where-Object { $_.player.puuid -eq $puuid } | Select-Object -First 1
    if ($id) { return ($parts | Where-Object { $_.participantId -eq $id.participantId } | Select-Object -First 1) }
    if ($parts.Count -eq 1) { return $parts[0] }
    return $null
}

# Picks up to 4 recent jungle games (games on the locked champion first) to study.
function Get-PathingGames($p, $d) {
    $mine = @()
    foreach ($lg in $d.List) {
        $g = $script:GameCache[[string]$lg.gameId]; if (-not $g) { $g = $lg }
        $me = Find-Me $g $p.Puuid
        if ($me -and (Get-Role $me) -eq 'Jungle') { $mine += @{ g = $g; champ = [int]$me.championId } }
    }
    $first = @($mine | Where-Object { $_.champ -eq $p.ChampionId }); $rest = @($mine | Where-Object { $_.champ -ne $p.ChampionId })
    return @(@($first + $rest) | Select-Object -First 4)
}

function Measure-Pathing($p, $d) {
    $out = [ordered]@{ jungler = $false; loading = $false; games = 0; lines = @(); note = '' }
    if (-not $d.PathPlanned) { $out.loading = $true; return $out }
    if ($d.PathGames.Count -eq 0) {
        if ($d.JungleMain) { $out.jungler = $true; $out.note = 'No recent jungle games to study, so their pathing is unknown.' }
        return $out
    }
    $out.jungler = $true
    if (-not $d.PathDone) { $out.loading = $true; return $out }
    $n = 0; $top = 0; $invade = 0; $lanes = @{}; $laneMin = @{}; $early = 0; $earlyLanes = @{}; $noTl = 0
    foreach ($pg in $d.PathGames) {
        $g = $pg.g
        $tl = $d.Timelines[[string]$g.gameId]
        if (-not $tl) { $noTl++; continue }
        $me = Find-Me $g $p.Puuid; if (-not $me) { continue }
        $mpid = [int]$me.participantId
        if ($tl.pidByPuuid -and $tl.pidByPuuid.ContainsKey($p.Puuid)) { $mpid = $tl.pidByPuuid[$p.Puuid] }
        $blue = ([int]$me.teamId -eq 100)
        $f1 = $tl.frames | Where-Object { $_.ts -ge 45000 -and $_.ts -le 90000 -and $_.pos.ContainsKey($mpid) } | Select-Object -First 1
        if (-not $f1) { continue }
        $n++
        $x = $f1.pos[$mpid][0]; $y = $f1.pos[$mpid][1]
        if ($y -gt $x) { $top++ }
        if (($blue -and ($x + $y) -gt 15400) -or (-not $blue -and ($x + $y) -lt 14200)) { $invade++ }
        foreach ($f in @($tl.frames | Where-Object { $_.ts -ge 150000 -and $_.ts -le 430000 } | Sort-Object { $_.ts })) {
            if (-not $f.pos.ContainsKey($mpid)) { continue }
            $ln = Get-Lane $f.pos[$mpid][0] $f.pos[$mpid][1]
            if ($ln) { $lanes[$ln] = 1 + [int]$lanes[$ln]; $laneMin[$ln] = @($laneMin[$ln]) + [Math]::Round($f.ts / 60000.0); break }
        }
        $k = @($tl.kills | Where-Object { $_.ts -lt 360000 -and ($_.killer -eq $mpid -or $_.assists -contains $mpid) } | Sort-Object { $_.ts }) | Select-Object -First 1
        if ($k) { $early++; $ln = Get-Lane $k.x $k.y; if ($ln) { $earlyLanes[$ln] = 1 + [int]$earlyLanes[$ln] } }
    }
    $out.games = $n
    if ($n -eq 0) { $out.note = 'Their recent jungle games had no timeline data, so pathing is unknown.'; return $out }
    $L = @()
    $side = 'top side'; $cnt = $top; if ($top * 2 -lt $n) { $side = 'bot side'; $cnt = $n - $top }
    if ($cnt * 2 -eq $n) { $L += "Starts top side and bot side equally ($n games)" } else { $L += "Starts $side in $cnt of $n games" }
    if ($lanes.Count) {
        $best = $lanes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        $mins = @($laneMin[$best.Key] | Where-Object { $_ -gt 0 }); $avg = 0; if ($mins.Count) { $avg = [Math]::Round(($mins | Measure-Object -Average).Average) }
        $L += "First visits $($best.Key) lane most often ($($best.Value) of $n games, around minute $avg)"
    } else { $L += 'Usually stays in the jungle for the first few minutes (full clears)' }
    if ($invade -gt 0) { $L += "Started in your jungle (invade) in $invade of $n games" }
    if ($early -gt 0) {
        $t = "Got a kill or assist before 6:00 in $early of $n games"
        if ($earlyLanes.Count) { $el = ($earlyLanes.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key; $t += ", mostly $el side" }
        $L += $t
    } else { $L += 'No early kills (before 6:00) in these games' }
    $out.lines = $L
    if ($noTl -gt 0) { $out.note = "$noTl game(s) had no timeline data." }
    return $out
}

# ---------------------------------------------------------------- Porofessor (available once the game reaches the loading screen)
function Get-PoroRegion { $r = $script:Region; if ($r -in 'ph', 'sg', 'th') { return 'sea' }; return $r }

function Get-PoroData($players) {
    $names = @($players | Where-Object { $_.Name -match '#' } | ForEach-Object { $_.Name } | Select-Object -First 2)
    if ($names.Count -eq 0) { return @{ ok = $false; note = 'Porofessor needs full names with #tags.' } }
    foreach ($nm in $names) {
        $np = $nm.Split('#', 2)
        $slug = ([uri]::EscapeDataString($np[0]) -replace '%20', '+') + '-' + [uri]::EscapeDataString($np[1])
        $txt = Invoke-WebText "$PoroBase/partial/live-partial/$(Get-PoroRegion)/$slug"
        if (-not $txt) { continue }
        if ($txt -match 'not in-game') { return @{ ok = $false; note = 'Not in game yet. Porofessor fills in at the loading screen.' } }
        $map = @{}
        $chunks = $txt -split 'data-summonername="'
        for ($i = 1; $i -lt $chunks.Count; $i++) {
            $c = $chunks[$i]
            $name = [System.Net.WebUtility]::HtmlDecode($c.Substring(0, [Math]::Max(0, $c.IndexOf('"'))))
            $tags = @()
            foreach ($m in [regex]::Matches($c, '<div class="tag requireTooltip ([a-z]+)[^"]*" tooltip="([^"]*)">\s*([^<]+?)\s*</div>')) {
                $tip = [System.Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
                $desc = [regex]::Match($tip, "tagDescription'>(.*)</span>").Groups[1].Value
                if (-not $desc) { $desc = $tip }
                $desc = ([regex]::Replace($desc, '<[^>]+>', '') -replace '\s+', ' ').Trim()
                $tone = 'neutral'; if ($m.Groups[1].Value -eq 'green') { $tone = 'good' } elseif ($m.Groups[1].Value -eq 'red') { $tone = 'bad' }
                $tags += @{ text = [System.Net.WebUtility]::HtmlDecode($m.Groups[3].Value.Trim()); desc = $desc; tone = $tone }
            }
            $pm = [regex]::Match($c, 'premadeHistoryTagContainer">([\s\S]{0,3000}?)</div>\s*</div>\s*<div class="cardBody"').Groups[1].Value
            $pmTip = [regex]::Match($pm, 'tooltip="([^"]*)"').Groups[1].Value
            $pmText = ([regex]::Replace([System.Net.WebUtility]::HtmlDecode($pm + ' ' + $pmTip), '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
            $map[(Normalize-Text (($name -split '#')[0]))] = @{ tags = $tags; premade = $pmText }
        }
        if ($map.Count -gt 0) { return @{ ok = $true; map = $map } }
    }
    $n = 'Porofessor could not be reached.'; if ($script:WebError) { $n += " $($script:WebError)" }
    return @{ ok = $false; note = $n }
}

function Update-Porofessor {
    if ($script:LastTeam.Count -eq 0) { return }
    if ($script:Poro.Status -in 'loaded', 'gaveup') { return }
    if ((Get-Date) -lt $script:Poro.Next) { return }
    $script:Poro.Tries++
    $r = Get-PoroData $script:LastTeam
    if ($r.ok) { $script:Poro.Status = 'loaded'; $script:Poro.Map = $r.map; $script:Poro.Note = ''; Log 'Porofessor data loaded.'; return }
    $script:Poro.Note = $r.note
    $script:Poro.Status = 'waiting'
    if ($script:Poro.Tries -ge 30) { $script:Poro.Status = 'gaveup'; $script:Poro.Note = 'Porofessor had no live game for these players.' }
    $script:Poro.Next = (Get-Date).AddSeconds(30)
}

# ---------------------------------------------------------------- game flow: loading screen, end of game, win tracking
function Update-GameFlow {
    if (-not $script:Conn -or (Get-Date) -lt $script:NextFlow) { return }
    $script:NextFlow = (Get-Date).AddSeconds(3)
    $ph = Invoke-Lcu '/lol-gameflow/v1/gameflow-phase'
    if (-not $ph) { return }
    $script:Phase = [string]$ph
    if ($script:Phase -in 'PreEndOfGame', 'EndOfGame', 'WaitingForStats') {
        $eog = Invoke-Lcu '/lol-end-of-game/v1/eog-stats-block'
        if ($eog -and $eog.gameId -and [string]$eog.gameId -ne [string]$script:LastEogId) {
            $win = $null
            foreach ($t in @($eog.teams)) { if ($t.isPlayerTeam) { $win = [bool]$t.isWinningTeam } }
            if ($win -eq $null -and $eog.localPlayer -and $eog.localPlayer.stats -and $eog.localPlayer.stats.WIN -ne $null) { $win = ([int]$eog.localPlayer.stats.WIN -eq 1) }
            if ($win -ne $null) {
                $script:LastEogId = [string]$eog.gameId
                $script:LastResult = @{ id = [string]$eog.gameId; win = $win }
                if ($win) { $script:Record.W++ } else { $script:Record.L++ }
                Clear-Backup 'game over'
                Log $(if ($win) { 'Game won. GG!' } else { 'Game lost.' })
            }
        }
    }
    # Back in the lobby without a game (dodge) or after the game: forget the last team.
    if ($script:LastTeam.Count -gt 0 -and $script:Phase -in 'None', 'Lobby', 'Matchmaking', 'ReadyCheck' -and
        $script:PostSelectAt -and ((Get-Date) - $script:PostSelectAt).TotalSeconds -gt 20) {
        $script:LastTeam = @(); $script:PostSelectAt = $null
        Clear-Backup 'back in lobby'
    }
}

# ---------------------------------------------------------------- analysis
function Get-Role($part) {
    $lane = ''; $role = ''
    if ($part.timeline) { $lane = [string]$part.timeline.lane; $role = [string]$part.timeline.role }
    if ($part.teamPosition) { $lane = [string]$part.teamPosition }
    switch -regex ($lane) {
        'TOP'             { return 'Top' }
        'JUNGLE'          { return 'Jungle' }
        'MID'             { return 'Mid' }
        'BOT|BOTTOM|ADC'  { if ($role -match 'SUPPORT') { return 'Support' } return 'Bot' }
        'UTILITY|SUPPORT' { return 'Support' }
    }
    return ''
}

function Format-Rank($r) {
    if (-not $r -or -not $r.Tier) { return 'Unranked' }
    $t = $r.Tier.Substring(0, 1) + $r.Tier.Substring(1).ToLower()
    if ($r.Tier -in 'MASTER', 'GRANDMASTER', 'CHALLENGER') { return "$t $($r.LP) LP" }
    return "$t $($r.Division) $($r.LP) LP"
}

function Get-Links($name) {
    $reg = $script:Region
    if ($name -match '^(.+)#(.+)$') {
        $slug = [uri]::EscapeDataString($Matches[1]) + '-' + [uri]::EscapeDataString($Matches[2])
        return @{ opgg = "https://op.gg/lol/summoners/$reg/$slug"; poro = "https://porofessor.gg/live/$reg/$slug" }
    }
    return @{ opgg = "https://op.gg/summoners/search?q=$([uri]::EscapeDataString($name))&region=$reg"; poro = '' }
}

function Measure-Player($p, $others) {
    $d = $null; if ($p.Key) { $d = $script:Data[$p.Key] }
    Sync-Player $p $d
    $res = [ordered]@{
        name = $p.Name; links = (Get-Links $p.Name); hidden = [bool]$p.Hidden; source = $p.Source
        locked = $null; loading = $true; error = ''; note = ''; rank = 'Unranked'; role = ''; games = 0
        winRate = $null; kda = $null; csm = $null; vision = $null; kp = $null
        streak = ''; topChamps = @(); strengths = @(); weaknesses = @(); premades = @(); candidates = @()
        onChamp = $null; pathing = $null; poro = $null
    }
    if ($script:Poro.Status -eq 'loaded') {
        $pk = Normalize-Text (($p.Name -split '#')[0])
        if ($script:Poro.Map.ContainsKey($pk)) { $res.poro = $script:Poro.Map[$pk] } else { $res.poro = @{ tags = @(); premade = ''; missing = $true } }
    }
    if ($p.ChampionId -gt 0) { $res.locked = @{ id = $p.ChampionId; name = (ChampName $p.ChampionId) } }
    if ($p.Hidden -or -not $d) { if ($p.Hidden) { $res.loading = $false }; return $res }
    $res.rank = Format-Rank $d.Rank
    $res.note = $d.Note
    $res.loading = -not $d.Done
    if (-not $d.Done) { return $res }
    if ($d.Error -and $d.List.Count -eq 0) { $res.error = $d.Error; return $res }

    $otherByPuuid = @{}
    foreach ($o in $others) { if ($o.Puuid -and $o.Puuid -ne $p.Puuid) { $otherByPuuid[$o.Puuid] = $o.Name } }

    $champs = @{}; $mates = @{}; $roles = @{}; $results = @()
    $wT = 0.0; $wW = 0.0; $n = 0; $premadeGames = 0
    $sK = 0.0; $sD = 0.0; $sA = 0.0; $sCsm = 0.0; $sVis = 0.0; $sKp = 0.0; $kpW = 0.0; $sDmg = 0.0; $dmgW = 0.0; $fb = 0

    $i = 0
    foreach ($lg in $d.List) {
        $g = $script:GameCache[[string]$lg.gameId]; if (-not $g) { $g = $lg }
        $ids = @($g.participantIdentities); $parts = @($g.participants)
        $me = $null
        $myIdent = $ids | Where-Object { $_.player.puuid -eq $p.Puuid } | Select-Object -First 1
        if ($myIdent) { $me = $parts | Where-Object { $_.participantId -eq $myIdent.participantId } | Select-Object -First 1 }
        if (-not $me -and $parts.Count -eq 1) { $me = $parts[0] }
        if (-not $me) { continue }

        $w = [Math]::Pow(0.92, $i); $i++
        $withMates = @()
        foreach ($id in $ids) {
            if ($id.player -and $otherByPuuid.ContainsKey([string]$id.player.puuid)) {
                $op = $parts | Where-Object { $_.participantId -eq $id.participantId } | Select-Object -First 1
                if ($op -and $op.teamId -eq $me.teamId) { $withMates += $otherByPuuid[[string]$id.player.puuid] }
            }
        }
        if ($withMates.Count -gt 0) { $w *= 1.75; $premadeGames++ }

        $s = $me.stats; $win = [bool]$s.win; $mins = [Math]::Max(1.0, [double]$g.gameDuration / 60.0)
        $winN = 0; if ($win) { $winN = 1 }
        $n++; $wT += $w; $wW += $w * $winN; $results += $win
        $cid = [int]$me.championId
        if (-not $champs.ContainsKey($cid)) { $champs[$cid] = @{ w = 0.0; ww = 0.0; n = 0; wins = 0; pm = 0; k = 0; d = 0; a = 0; cs = 0.0; kp = 0.0; kpn = 0; dmg = 0.0; dmgn = 0; fb = 0; roles = @{} } }
        $c = $champs[$cid]; $c.w += $w; $c.ww += $w * $winN; $c.n += 1; $c.wins += $winN
        $c.k += [int]$me.stats.kills; $c.d += [int]$me.stats.deaths; $c.a += [int]$me.stats.assists
        $c.cs += (([double]$me.stats.totalMinionsKilled + [double]$me.stats.neutralMinionsKilled) / [Math]::Max(1.0, [double]$g.gameDuration / 60.0))
        if ($me.stats.firstBloodKill -or $me.stats.firstBloodAssist) { $c.fb++ }
        if ($withMates.Count -gt 0) { $c.pm += 1 }
        foreach ($mn in $withMates) {
            if (-not $mates.ContainsKey($mn)) { $mates[$mn] = @{ n = 0; wins = 0 } }
            $mates[$mn].n += 1; $mates[$mn].wins += $winN
        }
        $role = Get-Role $me; if ($role) { $roles[$role] = 1 + [int]$roles[$role]; $c.roles[$role] = 1 + [int]$c.roles[$role] }

        $sK += $w * $s.kills; $sD += $w * $s.deaths; $sA += $w * $s.assists
        $sCsm += $w * (([double]$s.totalMinionsKilled + [double]$s.neutralMinionsKilled) / $mins)
        $sVis += $w * ([double]$s.visionScore / $mins)
        if ($s.firstBloodKill -or $s.firstBloodAssist) { $fb++ }
        if ($parts.Count -ge 10) {
            $team = @($parts | Where-Object { $_.teamId -eq $me.teamId })
            $tk = ($team | ForEach-Object { [double]$_.stats.kills } | Measure-Object -Sum).Sum
            $td = ($team | ForEach-Object { [double]$_.stats.totalDamageDealtToChampions } | Measure-Object -Sum).Sum
            if ($tk -gt 0) { $sKp += $w * (($s.kills + $s.assists) / $tk); $kpW += $w; $c.kp += (($s.kills + $s.assists) / $tk); $c.kpn++ }
            if ($td -gt 0) { $sDmg += $w * ([double]$s.totalDamageDealtToChampions / $td); $dmgW += $w; $c.dmg += ([double]$s.totalDamageDealtToChampions / $td); $c.dmgn++ }
        }
    }
    $res.games = $n
    if ($n -eq 0) { $res.weaknesses = @('No recent Summoner''s Rift games found'); return $res }

    $wr = $wW / $wT; $k = $sK / $wT; $de = $sD / $wT; $a = $sA / $wT
    $csm = $sCsm / $wT; $vis = $sVis / $wT
    $kp = $null; if ($kpW -gt 0) { $kp = $sKp / $kpW }
    $dmg = $null; if ($dmgW -gt 0) { $dmg = $sDmg / $dmgW }
    $kda = ($k + $a) / [Math]::Max(1.0, $de)
    $mainRole = ''; if ($roles.Count) { $mainRole = ($roles.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key }
    $res.role = $mainRole
    $res.winRate = [Math]::Round($wr * 100); $res.kda = [Math]::Round($kda, 2)
    $res.csm = [Math]::Round($csm, 1); $res.vision = [Math]::Round($vis, 2)
    if ($kp -ne $null) { $res.kp = [Math]::Round($kp * 100) }

    $st = 0; $first = $results[0]
    foreach ($r in $results) { if ($r -eq $first) { $st++ } else { break } }
    $res.streak = $(if ($first) { "W$st" } else { "L$st" })

    $top = @($champs.GetEnumerator() | Sort-Object { $_.Value.w } -Descending)
    $res.topChamps = @($top | Select-Object -First 4 | ForEach-Object {
        @{ id = $_.Key; name = (ChampName $_.Key); games = $_.Value.n; wins = $_.Value.wins; wr = [Math]::Round(100 * $_.Value.wins / [Math]::Max(1, $_.Value.n)) }
    })
    $topShare = $top[0].Value.w / $wT

    $strs = @(); $weaks = @()
    $isSup = $mainRole -eq 'Support'; $isJg = $mainRole -eq 'Jungle'
    if ($wr -ge 0.58) { $strs += "In good form lately ($([Math]::Round($wr*100))% recent WR)" }
    if ($wr -le 0.42) { $weaks += "Lower win rate lately ($([Math]::Round($wr*100))%)" }
    if ($first -and $st -ge 3) { $strs += "Won $st in a row" }
    if (-not $first -and $st -ge 3) { $weaks += "Lost the last $st games" }
    if ($kda -ge 4) { $strs += "Rarely dies (KDA $([Math]::Round($kda,1)))" }
    if ($de -ge 6.5) { $weaks += "Dies fairly often ($([Math]::Round($de,1)) per game)" }
    if ($k -ge 8) { $strs += "Gets a lot of kills ($([Math]::Round($k,1)) per game)" }
    if (-not $isSup -and -not $isJg) {
        if ($csm -ge 8) { $strs += "Excellent farmer ($([Math]::Round($csm,1)) CS/min)" }
        elseif ($csm -le 5.5) { $weaks += "Lower farm ($([Math]::Round($csm,1)) CS/min)" }
    }
    $visHi = 1.3; $visLo = 0.6; if ($isSup) { $visHi = 2.4; $visLo = 1.4 }
    if ($vis -ge $visHi) { $strs += 'Strong vision control' }
    if ($vis -le $visLo) { $weaks += 'Places few wards' }
    if ($kp -ne $null -and $kp -ge 0.62) { $strs += "Joins most fights ($([Math]::Round($kp*100))% kill participation)" }
    if ($kp -ne $null -and $kp -le 0.40) { $weaks += "Often plays away from the team ($([Math]::Round($kp*100))% kill participation)" }
    if ($dmg -ne $null -and $dmg -ge 0.28) { $strs += "Deals most of the team's damage ($([Math]::Round($dmg*100))%)" }
    if ($n -ge 5 -and ($fb / $n) -ge 0.3) { $strs += "Active early (in first blood $([Math]::Round(100*$fb/$n))% of games)" }
    if ($topShare -ge 0.5 -and $top[0].Value.n -ge 4) { $weaks += "Mostly plays $(ChampName $top[0].Key)" }
    elseif ($champs.Count -ge 7) { $strs += "Deep champion pool ($($champs.Count) champs recently)" }
    $res.strengths = @($strs); $res.weaknesses = @($weaks)

    $res.premades = @($mates.GetEnumerator() | Where-Object { $_.Value.n -ge 2 } | Sort-Object { $_.Value.n } -Descending | ForEach-Object {
        @{ name = $_.Key; games = $_.Value.n; wr = [Math]::Round(100 * $_.Value.wins / $_.Value.n) }
    })

    # After lock-in: how they play the champion they picked
    if ($p.ChampionId -gt 0) {
        $lc = [int]$p.ChampionId; $cn = ChampName $lc
        $oc = [ordered]@{ id = $lc; name = $cn; games = 0; lines = @(); note = '' }
        if ($champs.ContainsKey($lc)) {
            $c = $champs[$lc]; $oc.games = $c.n
            $cwr = [Math]::Round(100 * $c.wins / [Math]::Max(1, $c.n))
            $ckda = [Math]::Round(($c.k + $c.a) / [Math]::Max(1, $c.d), 2)
            $cr = ''; if ($c.roles.Count) { $cr = ($c.roles.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key }
            $L = @("$($c.n) of their last $n games, $cwr% win rate")
            $L += ("Averages {0} / {1} / {2} (KDA {3})" -f [Math]::Round($c.k / $c.n, 1), [Math]::Round($c.d / $c.n, 1), [Math]::Round($c.a / $c.n, 1), $ckda)
            if ($cr) { $L += "Plays it $cr" + $(if ($cr -ne $mainRole -and $mainRole) { " (usually plays $mainRole)" } else { '' }) }
            if ($c.kpn -gt 0) { $ckp = [Math]::Round(100 * $c.kp / $c.kpn); if ($ckp -ge 62) { $L += "Joins most fights on it ($ckp% kill participation)" } elseif ($ckp -le 42) { $L += "Plays more on their own on it ($ckp% kill participation)" } }
            if ($c.dmgn -gt 0) { $cd = [Math]::Round(100 * $c.dmg / $c.dmgn); if ($cd -ge 28) { $L += "Main damage dealer on it ($cd% of team damage)" } }
            if ($c.n -ge 3 -and ($c.fb / $c.n) -ge 0.34) { $L += "Often involved in first blood on it" }
            if ($c.n -le 2) { $oc.note = "Only $($c.n) recent game(s) on $cn, so this is a small sample." }
            $oc.lines = $L
        } else {
            $pts = 0; if ($d.Mastery.ContainsKey($lc)) { $pts = $d.Mastery[$lc] }
            $oc.note = "No games on $cn in their last $n games, so there's no recent playstyle information."
            if ($pts -gt 0) { $oc.note += " They have $([Math]::Round($pts/1000))k mastery points on it." }
        }
        $res.onChamp = $oc
        $res.pathing = Measure-Pathing $p $d
    }

    $mult = 0.85; if ($d.Rank -and $d.Rank.Tier -and $Tiers.ContainsKey($d.Rank.Tier)) { $mult = $Tiers[$d.Rank.Tier] }
    $mTotal = 0.0; foreach ($v in @($d.Mastery.Values | Sort-Object -Descending | Select-Object -First 10)) { $mTotal += $v }
    $cands = @()
    $ids = @(@($champs.Keys) + @($d.Mastery.Keys) | Select-Object -Unique)
    foreach ($cid in $ids) {
        $cid = [int]$cid
        $c = $null; if ($champs.ContainsKey($cid)) { $c = $champs[$cid] }
        $pts = 0; if ($d.Mastery.ContainsKey($cid)) { $pts = $d.Mastery[$cid] }
        $mShare = 0.0; if ($mTotal -gt 0) { $mShare = $pts / $mTotal }
        $score = $mShare * 15
        if ($c) {
            $share = $c.w / $wT
            $cwr = ($c.ww + 1.5) / ($c.w + 3.0)
            $conf = [Math]::Min($c.n, 10) / 10.0
            $score += $share * 60 + ($cwr - 0.5) * 120 * $conf
            if ($c.pm -gt 0 -and $premadeGames -gt 0) { $score += 10 * ($c.pm / $premadeGames) }
        } elseif ($mShare -lt 0.25) { continue }
        $score *= $mult
        if ($score -lt 4) { continue }
        $why = ''
        if ($c) { $why = "$($c.n) of last $n games, $([Math]::Round(100*$c.wins/[Math]::Max(1,$c.n)))% WR" } else { $why = 'top mastery, not played recently' }
        if ($c -and $c.pm -gt 0) { $why += ", $($c.pm) with current teammates" }
        if ($pts -ge 100000) { $why += ", $([Math]::Round($pts/1000))k mastery" }
        $cands += @{ id = $cid; score = $score; why = $why }
    }
    $res.candidates = @($cands)
    return $res
}

function Get-Exclusions {
    $ex = @{}
    if ($script:Source -eq 'screen') {
        foreach ($p in $script:Enemies) { if ($p.ChampionId -gt 0) { $ex[[int]$p.ChampionId] = 'picked' } }
        foreach ($cid in $script:ScreenAlly) { $ex[[int]$cid] = 'your team has it' }
        return $ex
    }
    $session = $script:Session
    if (-not $session) { return $ex }
    foreach ($b in @($session.bans.myTeamBans) + @($session.bans.theirTeamBans)) { if ([int]$b -gt 0) { $ex[[int]$b] = 'banned' } }
    foreach ($grp in @($session.actions)) {
        foreach ($a in @($grp)) {
            if ($a.completed -and [int]$a.championId -gt 0) {
                if ($a.type -eq 'ban') { $ex[[int]$a.championId] = 'banned' } else { $ex[[int]$a.championId] = 'picked' }
            }
        }
    }
    foreach ($m in @($session.theirTeam)) { if ([int]$m.championId -gt 0) { $ex[[int]$m.championId] = 'picked' } }
    foreach ($m in @($session.myTeam)) {
        if ([int]$m.championPickIntent -gt 0) { $ex[[int]$m.championPickIntent] = 'your team is hovering it' }
        if ([int]$m.championId -gt 0) { $ex[[int]$m.championId] = 'your team picked it' }
    }
    return $ex
}

# ---------------------------------------------------------------- backup of the last good results
# From champ select through the loading screen, every good player card is backed up (in memory and in
# backup.json). If a glitch makes a card lose its data, or the whole team drops out, the last known
# result is shown instead until fresh data is good again.
$script:Backup = @{ Cards = @(); Team = @(); Bans = @(); At = $null; SeenAt = $null }
$script:BackupFile = Join-Path $script:WorkDir 'backup.json'
$script:BackupSavedAt = Get-Date '2000-01-01'
$script:Restoring = $false

function Get-GameName([string]$n) { return Normalize-Text (($n -split '#')[0]) }
function Test-SamePerson([string]$a, [string]$b) {
    $x = Get-GameName $a; $y = Get-GameName $b
    if (-not $x -or -not $y) { return $false }
    if ($x -eq $y) { return $true }
    return ((Get-Distance $x $y) -le 2)
}
function Test-GoodCard($e) {
    return ($e -and -not $e.hidden -and -not $e.loading -and -not $e.error -and [int]$e.games -gt 0 -and ([string]$e.name) -match '#')
}
function Clear-Backup([string]$why) {
    if ($script:Backup.Cards.Count -gt 0) { Log "Backup cleared ($why)." }
    $script:Backup = @{ Cards = @(); Team = @(); Bans = @(); At = $null; SeenAt = $null }
    $script:Restoring = $false
    try { if (Test-Path $script:BackupFile) { Remove-Item $script:BackupFile -Force } } catch {}
}
# Is this enemy team the same match as the backup? (2+ of the same players)
function Test-SameMatch($players) {
    if ($script:Backup.Cards.Count -eq 0) { return $false }
    $hits = 0
    foreach ($p in $players) { foreach ($c in $script:Backup.Cards) { if (Test-SamePerson $p.Name $c.name) { $hits++; break } } }
    return ($hits -ge 2)
}
function Save-Backup {
    if ($script:Backup.Cards.Count -eq 0 -or ((Get-Date) - $script:BackupSavedAt).TotalSeconds -lt 5) { return }
    $script:BackupSavedAt = Get-Date
    try {
        $o = @{ savedAt = (Get-Date).ToString('o'); cards = $script:Backup.Cards; bans = $script:Backup.Bans
                team = @($script:Backup.Team | ForEach-Object { @{ Name = $_.Name; Puuid = $_.Puuid; Key = $_.Key; Source = $_.Source; ChampionId = $_.ChampionId } }) }
        ConvertTo-Json -InputObject $o -Depth 12 -Compress | Set-Content -Path $script:BackupFile -Encoding UTF8
    } catch {}
}
# After a crash or restart in the middle of a match, pick up the saved backup (if it is recent).
function Restore-BackupFromDisk {
    try {
        if (-not (Test-Path $script:BackupFile)) { return }
        $o = Get-Content $script:BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = ((Get-Date) - [DateTime]::Parse($o.savedAt)).TotalMinutes
        if ($age -gt 45) { Remove-Item $script:BackupFile -Force; return }
        $script:Backup.Cards = @($o.cards); $script:Backup.Bans = @($o.bans)
        $script:Backup.Team = @($o.team | ForEach-Object { $q = New-Player $_.Name $_.Puuid 0 ([int]$_.ChampionId) $_.Key $false $_.Source; $q })
        $script:Backup.At = Get-Date; $script:Backup.SeenAt = (Get-Date).AddMinutes(-$age)
        if ($script:Backup.Team.Count -gt 0) {
            $script:LastTeam = @($script:Backup.Team); $script:PostSelectAt = (Get-Date).AddMinutes(-$age)
            $script:Poro = @{ Status = 'waiting'; Next = (Get-Date).AddSeconds(5); Tries = 0; Map = @{}; Note = 'Restored the last match after a restart.' }
        }
        Log ("Restored backup of the last match ({0:N0} min old)." -f $age)
    } catch {}
}

# Replace degraded cards with their last good version; back up good ones.
function Use-Backup($enemies, $bans, $team) {
    $out = @(); $used = @{}; $restored = $false
    for ($i = 0; $i -lt $enemies.Count; $i++) {
        $e = $enemies[$i]
        if (Test-GoodCard $e) { $out += $e; continue }
        $bk = $null
        for ($j = 0; $j -lt $script:Backup.Cards.Count; $j++) {
            if ($used.ContainsKey($j)) { continue }
            $c = $script:Backup.Cards[$j]
            if (Test-SamePerson $e.name $c.name) { $bk = $c; $used[$j] = 1; break }
        }
        if (-not $bk -and ($e.hidden -or -not (Get-GameName $e.name)) -and $i -lt $script:Backup.Cards.Count -and -not $used.ContainsKey($i)) { $bk = $script:Backup.Cards[$i]; $used[$i] = 1 }
        if ($bk) {
            $r = ConvertFrom-Json (ConvertTo-Json -InputObject $bk -Depth 12)   # copy
            if ($e.locked) { $r.locked = $e.locked }
            if ($e.onChamp -and -not $r.onChamp) { $r | Add-Member -Force -NotePropertyName onChamp -NotePropertyValue $e.onChamp }
            if ($e.poro) { $r | Add-Member -Force -NotePropertyName poro -NotePropertyValue $e.poro }
            $r | Add-Member -Force -NotePropertyName restored -NotePropertyValue $true
            $out += $r; $restored = $true
        } else { $out += $e }
    }
    # Players missing from this read (the team shrank because of a glitch)
    if ($out.Count -lt $script:Backup.Cards.Count) {
        for ($j = 0; $j -lt $script:Backup.Cards.Count -and $out.Count -lt 5; $j++) {
            if ($used.ContainsKey($j)) { continue }
            $c = $script:Backup.Cards[$j]
            $present = $false; foreach ($e in $out) { if (Test-SamePerson $e.name $c.name) { $present = $true; break } }
            if (-not $present) {
                $r = ConvertFrom-Json (ConvertTo-Json -InputObject $c -Depth 12)
                $r | Add-Member -Force -NotePropertyName restored -NotePropertyValue $true
                $out += $r; $restored = $true
            }
        }
    }
    # Back up the good cards (merge by person)
    $cards = @($script:Backup.Cards)
    foreach ($e in $out) {
        if (-not (Test-GoodCard $e) -or $e.restored) { continue }
        $k = -1; for ($j = 0; $j -lt $cards.Count; $j++) { if (Test-SamePerson $e.name $cards[$j].name) { $k = $j; break } }
        if ($k -ge 0) { $cards[$k] = $e } else { $cards += $e }
    }
    $script:Backup.Cards = $cards
    $goodTeam = @($team | Where-Object { $_.Puuid -and $_.Name -match '#' })
    if ($goodTeam.Count -ge [Math]::Max(1, $script:Backup.Team.Count)) { $script:Backup.Team = $goodTeam }
    if (@($bans).Count -gt 0) { $script:Backup.Bans = @($bans) }
    elseif ($script:Backup.Bans.Count -gt 0 -and $script:Status -eq 'champselect') { $bans = @($script:Backup.Bans); $restored = $true }
    if ($script:Backup.Cards.Count -gt 0) { $script:Backup.At = Get-Date }
    $script:Restoring = $restored
    Save-Backup
    return @{ enemies = @($out); bans = @($bans) }
}

function Build-State {
    $ex = Get-Exclusions
    $key = "$($script:RiotStatus)|$($script:RiotNote)|$($script:Backup.Cards.Count)|$($script:Restoring)|$($script:Poro.Status)|$($script:Poro.Note)|$($script:Record.W)-$($script:Record.L)|$($script:LastEogId)|$($script:Donate)|" +
           (((@($script:Enemies) + @($script:LastTeam)) | ForEach-Object { if ($_.Key -and $script:Data[$_.Key]) { "$($script:Data[$_.Key].PathPlanned)$($script:Data[$_.Key].PathNext)$($script:Data[$_.Key].PathDone)" } }) -join '') + '|' +
           "$($script:Status)|$($script:Mode)|$($script:Source)|$($script:Region)|$($script:ScreenNote)|$($script:ClientState)|" +
           (($script:Enemies | ForEach-Object { "$($_.Key):$($_.Name):$($_.ChampionId):" + $(if ($_.Key -and $script:Data[$_.Key]) { "$($script:Data[$_.Key].Stage)$($script:Data[$_.Key].Done)" } else { '' }) }) -join ',') +
           '|' + (($ex.Keys | Sort-Object) -join ',')
    if ($key -eq $script:StateKey) { return $script:StateJson }

    $team = $script:Enemies; if ($script:Status -eq 'ingame') { $team = $script:LastTeam }
    $enemies = @(); $all = @()
    foreach ($p in $team) {
        $e = Measure-Player $p $team
        if (-not $e.locked) { foreach ($c in $e.candidates) { $all += @{ id = $c.id; score = $c.score; why = $c.why; player = $p.Name } } }
        $e.Remove('candidates')
        $enemies += $e
    }
    $bans = @($all | Where-Object { -not $ex.ContainsKey([int]$_.id) } | Group-Object { $_.id } | ForEach-Object {
        $g = @($_.Group | Sort-Object { $_.score } -Descending)
        $sum = ($g | ForEach-Object { $_.score } | Measure-Object -Sum).Sum
        [ordered]@{ id = [int]$_.Name; name = (ChampName $_.Name); score = [Math]::Round($sum, 1)
                    reasons = @($g | ForEach-Object { "$(($_.player -split '#')[0]): $($_.why)" }) }
    } | Sort-Object { $_.score } -Descending | Select-Object -First 6)

    if ($script:Status -in 'champselect', 'ingame') {
        if ($script:Status -eq 'champselect') { $script:Backup.SeenAt = Get-Date }
        $bk = Use-Backup $enemies $bans $team
        $enemies = $bk.enemies; $bans = $bk.bans
    } else { $script:Restoring = $false }

    $excluded = @($ex.GetEnumerator() | ForEach-Object { @{ id = $_.Key; name = (ChampName $_.Key); reason = $_.Value } })
    $named = @($team | Where-Object { $_.Name -match '#' } | ForEach-Object { $_.Name })
    $multi = ''
    if ($named.Count) { $multi = "https://op.gg/lol/multisearch/$($script:Region)?summoners=" + [uri]::EscapeDataString(($named -join ',')) }

    $state = [ordered]@{
        status = $script:Status; mode = $script:Mode; source = $script:Source; clientState = $script:ClientState
        region = $script:Region; regionAuto = $script:RegionAuto; regions = $script:Regions
        screenNote = $script:ScreenNote; ocrError = $script:OcrError; ocrLines = @($script:OcrLines)
        ocrLangs = @($script:OcrLangs); cjkOcr = (@($script:CjkEngines).Count -gt 0); version = $AppVersion
        poro = @{ status = $script:Poro.Status; note = $script:Poro.Note }; restoring = $script:Restoring
        riot = @{ status = $script:RiotStatus; note = $script:RiotNote; hasKey = [bool]$script:RiotKey; platform = (Get-RiotPlatform) }
        donateUrl = $script:Donate; record = @{ w = $script:Record.W; l = $script:Record.L }; lastResult = $script:LastResult
        updated = (Get-Date -Format 'HH:mm:ss'); bans = $bans; enemies = $enemies; excluded = $excluded; multisearch = $multi
    }
    $script:StateJson = ConvertTo-Json -InputObject $state -Depth 10 -Compress
    $script:StateKey = $key
    return $script:StateJson
}

# ---------------------------------------------------------------- polling
# Returns $true when the client produced an enemy team with at least one visible player.
function Update-FromClient {
    if (-not $script:Conn) {
        $script:Conn = Get-LcuConnection
        if (-not $script:Conn) { $script:ClientState = 'no-client'; return $false }
        Initialize-ClientInfo
    }
    if ($Players) {
        if (-not $script:TestLoaded) { $script:Enemies = @($Players | ForEach-Object { Resolve-ByRiotId $_ }); $script:TestLoaded = $true }
        $script:ClientState = 'test'; return $true
    }
    $s = Invoke-Lcu '/lol-champ-select/v1/session'
    if (-not $s) {
        if (-not (Invoke-Lcu '/lol-gameflow/v1/gameflow-phase')) { $script:Conn = $null; $script:ClientState = 'no-client'; return $false }
        if ($script:ClientState -ne 'waiting') { Log 'Connected. Waiting for champ select...' }
        $script:ClientState = 'waiting'; $script:Session = $null
        return $false
    }
    if ([string]$s.gameId -ne [string]$script:LastGameId -or $script:ClientState -ne 'champselect') {
        $script:LastGameId = $s.gameId; $script:Identity = @{}
        Log 'Champ select started (League client).'
        try { ConvertTo-Json -InputObject $s -Depth 12 | Set-Content -Path (Join-Path $script:WorkDir 'last-session.json') -Encoding UTF8 } catch {}
    }
    $script:ClientState = 'champselect'
    $script:Session = $s
    $team = @(@($s.theirTeam) | ForEach-Object { Resolve-Member $_ })
    if (@($team | Where-Object { -not $_.Hidden }).Count -eq 0) { $script:ClientState = 'hidden'; return $false }
    $script:Enemies = $team
    return $true
}

function Start-ChampSelect([string]$src) {
    if ($script:LastTeam.Count -gt 0) { $script:LastTeam = @(); $script:PostSelectAt = $null }
    if ($script:Backup.Cards.Count -gt 0 -and -not (Test-SameMatch $script:Enemies)) { Clear-Backup 'new match' }
    $script:Poro = @{ Status = 'none'; Next = (Get-Date); Tries = 0; Map = @{}; Note = '' }
    $script:ScreenMisses = 0
    $script:Source = $src; $script:Status = 'champselect'
}

# Champ select is over: keep the enemy team on screen for the loading screen / game, and ask Porofessor.
function Stop-ChampSelect {
    $visible = @($script:Enemies | Where-Object { -not $_.Hidden })
    if ($visible.Count -lt $script:Backup.Team.Count -and $script:Backup.Team.Count -gt 0) { $script:Enemies = @($script:Backup.Team) }
    if (@($script:Enemies | Where-Object { -not $_.Hidden }).Count -gt 0) {
        $script:LastTeam = @($script:Enemies); $script:PostSelectAt = Get-Date
        $script:Poro = @{ Status = 'waiting'; Next = (Get-Date).AddSeconds(8); Tries = 0; Map = @{}; Note = 'Waiting for the loading screen.' }
        Log 'Champ select ended. Waiting for the game to load (Porofessor).'
    }
    $script:Source = ''; $script:Enemies = @(); $script:ScreenRows = @{}
}

function Update-Sources {
    $now = Get-Date
    if ($script:Mode -ne 'screen' -and $now -ge $script:NextClient) {
        $script:NextClient = $now.AddMilliseconds(1500)
        if (Update-FromClient) {
            if ($script:Source -ne 'client') { Start-ChampSelect 'client' } else { $script:Status = 'champselect' }
            if ($Players) { $script:Status = 'test' }
            return
        }
        if ($script:Source -eq 'client') { Stop-ChampSelect }
    } elseif ($script:Mode -ne 'screen' -and $script:Source -eq 'client') { return }

    # In Auto, only read the screen when the client can't be used (not running, or names hidden).
    # Otherwise the screen reader could mistake the lobby's friends list for an enemy team.
    $clientUsable = $script:ClientState -in 'waiting', 'champselect', 'test'
    if ($script:Mode -eq 'auto' -and $clientUsable) {
        if ($script:Source -eq 'screen') { Stop-ChampSelect }
    } elseif ($script:Mode -ne 'client' -and $now -ge $script:NextScreen) {
        $script:NextScreen = $now.AddMilliseconds(2500)
        $saved = $script:Enemies
        if (Update-FromScreen) {
            if ($script:Source -ne 'screen') { Start-ChampSelect 'screen' } else { $script:Status = 'champselect' }
            $script:ScreenMisses = 0
            return
        }
        if ($script:Source -eq 'screen') {
            $script:ScreenMisses++
            if ($script:ScreenMisses -lt 3) { $script:Enemies = $saved; return }   # one bad read is not the end of champ select
            Stop-ChampSelect
        }
    } elseif ($script:Mode -ne 'client' -and $script:Source -eq 'screen') { return }

    if ($script:Source) { return }
    if ($script:LastTeam.Count -gt 0 -and $script:PostSelectAt -and ((Get-Date) - $script:PostSelectAt).TotalMinutes -lt 60) { $script:Status = 'ingame'; return }
    if ($script:LastTeam.Count -gt 0) { $script:LastTeam = @() }
    if ($script:Backup.Team.Count -gt 0 -and $script:Backup.SeenAt -and ((Get-Date) - $script:Backup.SeenAt).TotalSeconds -lt 90 -and
        $script:Phase -notin 'Lobby', 'None', 'Matchmaking', 'ReadyCheck') {
        $script:LastTeam = @($script:Backup.Team); $script:PostSelectAt = Get-Date; $script:Status = 'ingame'; return
    }
    if ($script:Mode -eq 'client') { $script:Status = $script:ClientState; if ($script:Status -eq 'hidden') { $script:Status = 'waiting' } }
    elseif ($script:Mode -eq 'screen') { $script:Status = 'waiting' }
    else { if ($script:ClientState -eq 'no-client' -and $script:ScreenNote -like 'League window not found*') { $script:Status = 'no-client' } else { $script:Status = 'waiting' } }
}

# ---------------------------------------------------------------- web server
function Send-Response($ctx, [int]$code, [string]$type, [byte[]]$bytes, [string]$cache = 'no-store') {
    try {
        $ctx.Response.StatusCode = $code
        $ctx.Response.ContentType = $type
        $ctx.Response.Headers.Add('Cache-Control', $cache)
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $ctx.Response.OutputStream.Close()
    } catch {}
}

function Reset-Enemies {
    $script:Source = ''; $script:Enemies = @(); $script:ScreenRows = @{}; $script:Identity = @{}; $script:LastTeam = @(); $script:TestLoaded = $false
    $script:NextClient = Get-Date; $script:NextScreen = Get-Date; $script:StateKey = ''
}

function Invoke-Request($ctx) {
    $path = $ctx.Request.Url.AbsolutePath
    $qs = $ctx.Request.QueryString
    if ($path -eq '/' -or $path -eq '/index.html') {
        $file = Join-Path $ScriptDir 'index.html'
        if (Test-Path $file) { Send-Response $ctx 200 'text/html; charset=utf-8' ([System.IO.File]::ReadAllBytes($file)) }
        else { Send-Response $ctx 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('index.html is missing. Put it in the same folder as BanAdvisor.ps1.')) }
    } elseif ($path -eq '/api/state') {
        $json = '{"status":"demo"}'
        if (-not $Demo) { $json = Build-State }
        Send-Response $ctx 200 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
    } elseif ($path -eq '/api/mode') {
        $m = [string]$qs['m']
        if ($m -in 'auto', 'client', 'screen' -and $m -ne $script:Mode) { $script:Mode = $m; Save-Settings; Reset-Enemies; Log "Method changed to: $m" }
        Send-Response $ctx 200 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"ok":true}'))
    } elseif ($path -eq '/api/riotkey' -and $ctx.Request.HttpMethod -eq 'POST') {
        $body = ''
        try { $sr = New-Object System.IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8); $body = $sr.ReadToEnd(); $sr.Close() } catch {}
        $k = ''
        try { $k = [string](ConvertFrom-Json -InputObject $body).key } catch {}
        $k = $k.Trim()
        if ($k -and $k -notmatch '^RGAPI-[0-9a-fA-F-]{20,}$') {
            $script:RiotStatus = 'invalid'; $script:RiotNote = 'That does not look like a Riot API key (it should start with RGAPI-).'
        } else {
            $script:RiotKey = $k; Save-Settings; Test-RiotKey
            if ($k) { $script:Data = @{}; Reset-Enemies; Log 'Riot API key saved.' } else { Log 'Riot API key removed.' }
        }
        $script:StateKey = ''
        Send-Response $ctx 200 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"ok":true}'))
    } elseif ($path -eq '/api/region') {
        $r = [string]$qs['r']
        if ($script:Regions -contains $r -and $r -ne $script:Region) {
            $script:Region = $r; $script:RegionAuto = $false; Save-Settings
            if ($script:RiotKey) { Test-RiotKey }
            $script:Data = @{}; Reset-Enemies; Log "Region changed to: $r"
        }
        Send-Response $ctx 200 'application/json' ([Text.Encoding]::UTF8.GetBytes('{"ok":true}'))
    } elseif ($path -match '^/icon/(\d+)$') {
        $id = $Matches[1]
        if (-not $script:Icons.ContainsKey($id) -and $script:Conn) {
            $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('riot:' + $script:Conn.Token))
            $req = @{ Uri = "$($script:Conn.Base)/lol-game-data/assets/v1/champion-icons/$id.png"; UseBasicParsing = $true; TimeoutSec = 5
                      Headers = @{ Authorization = "Basic $auth" } }
            if ($IsCore) { $req.SkipCertificateCheck = $true }
            try { $r = Invoke-WebRequest @req -ErrorAction Stop; $script:Icons[$id] = $r.RawContentStream.ToArray() } catch {}
        }
        if ($script:Icons.ContainsKey($id)) { Send-Response $ctx 200 'image/png' $script:Icons[$id] 'public, max-age=86400' }
        else { Send-Response $ctx 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('no icon')) }
    } else {
        Send-Response $ctx 404 'text/plain' ([Text.Encoding]::UTF8.GetBytes('Not found'))
    }
}

Load-Settings
if ($script:RiotKey) { Test-RiotKey }
Restore-BackupFromDisk
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() } catch {
    Write-Host "Could not start on port $Port. Is Ranked 5s Ban Advisor already open in another window?" -ForegroundColor Red
    exit 1
}
$url = "http://localhost:$Port/"
Write-Host ''
Write-Host "  RANKED 5S BAN ADVISOR v$AppVersion" -ForegroundColor Yellow
Write-Host "  Dashboard: $url" -ForegroundColor Cyan
Write-Host "  Method: $($script:Mode)  (change it in the dashboard menu)" -ForegroundColor DarkGray
Write-Host '  Keep this window open. Close it to quit.' -ForegroundColor DarkGray
Write-Host ''
if (-not $NoBrowser) { try { Start-Process $url } catch {} }

$task = $listener.GetContextAsync()
try {
    while ($true) {
        while ($task.IsCompleted) { Invoke-Request $task.Result; $task = $listener.GetContextAsync() }
        if ($Demo) { [void]$task.Wait(300); continue }
        Update-Sources
        Update-GameFlow
        Update-Porofessor
        $worked = Step-Work
        if (-not $worked) { [void]$task.Wait(200) }
    }
} finally {
    $listener.Stop()
}
