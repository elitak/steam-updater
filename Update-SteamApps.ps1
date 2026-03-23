<#
.SYNOPSIS
    Bootstrap SteamCMD and update all Steam apps defined in settings.yml.

.DESCRIPTION
    - If Steam.exe is running, shows a countdown dialog (10s) with "Do It Now"
      and "Abort" buttons before shutting Steam down.
    - Installs SteamCMD to %ProgramData%\SteamCMD if not already present.
    - Reads settings.yml from the same directory as this script.
    - For every account entry, downloads/updates every listed appID
      into C:\SteamLibrary (or a custom library_root defined in settings.yml).
      appIDs are used directly; appREs are resolved via the Steam Web API.
    - After all updates complete, relaunches Steam.exe logged in as the first
      account listed in settings.yml.

.NOTES
    Steam Guard / Mobile Authenticator must be disabled on all accounts
    used here - SteamCMD cannot handle interactive 2-FA prompts.
#>

#Requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- YAML module --------------------------------------------------------------
# Uses the 'powershell-yaml' module (https://github.com/cloudbase/powershell-yaml).
# Installs it from PSGallery at runtime if not already present.
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Host "[yaml] 'powershell-yaml' module not found - installing from PSGallery ..." -ForegroundColor Yellow
    Install-Module -Name 'powershell-yaml' -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
}
Import-Module -Name 'powershell-yaml' -ErrorAction Stop

# -- Paths --------------------------------------------------------------------
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$SettingsFile = Join-Path $ScriptDir 'settings.yml'
$SteamCmdDir  = Join-Path $env:ProgramData 'SteamCMD'
$SteamCmdExe  = Join-Path $SteamCmdDir 'steamcmd.exe'
$SteamCmdZip  = Join-Path $env:TEMP 'steamcmd.zip'
$SteamCmdUrl  = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'

# Steam Web API endpoint - returns the full public app catalogue, no key needed
$SteamAppListUrl = 'https://api.steampowered.com/ISteamApps/GetAppList/v2/'

# Common Steam install locations - first one found wins
$SteamExeSearchPaths = @(
    'C:\Program Files (x86)\Steam\Steam.exe',
    'C:\Program Files\Steam\Steam.exe',
    (Join-Path $env:ProgramFiles       'Steam\Steam.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Steam\Steam.exe')
)

function Find-SteamExe {
    foreach ($p in $SteamExeSearchPaths) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $found = Get-Command 'Steam.exe' -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    return $null
}

# -- Steam shutdown countdown dialog ------------------------------------------
function Invoke-SteamShutdownDialog {
    <#
    Shows a WinForms dialog with a live 10-second countdown.
    Returns $true  -> proceed (countdown expired or "Do It Now" clicked)
    Returns $false -> user clicked "Abort"
    #>
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $script:countdown  = 10
    $script:userChoice = 'countdown'   # 'proceed' | 'abort'

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = 'steam-updater'
    $form.Size            = New-Object System.Drawing.Size(400, 160)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox     = $false
    $form.MinimizeBox     = $false
    $form.TopMost         = $true

    $label           = New-Object System.Windows.Forms.Label
    $label.Location  = New-Object System.Drawing.Point(20, 20)
    $label.Size      = New-Object System.Drawing.Size(360, 50)
    $label.Font      = New-Object System.Drawing.Font('Segoe UI', 11)
    $label.TextAlign = 'MiddleCenter'
    $label.Text      = "Steam is shutting down in $($script:countdown)..."
    $form.Controls.Add($label)

    $btnNow           = New-Object System.Windows.Forms.Button
    $btnNow.Text      = 'Do It Now'
    $btnNow.Size      = New-Object System.Drawing.Size(120, 34)
    $btnNow.Location  = New-Object System.Drawing.Point(60, 82)
    $btnNow.BackColor = [System.Drawing.Color]::FromArgb(0, 122, 204)
    $btnNow.ForeColor = [System.Drawing.Color]::White
    $btnNow.FlatStyle = 'Flat'
    $btnNow.Add_Click({
        $script:userChoice = 'proceed'
        $timer.Stop()
        $form.Close()
    })
    $form.Controls.Add($btnNow)

    $btnAbort          = New-Object System.Windows.Forms.Button
    $btnAbort.Text     = 'Abort'
    $btnAbort.Size     = New-Object System.Drawing.Size(120, 34)
    $btnAbort.Location = New-Object System.Drawing.Point(210, 82)
    $btnAbort.FlatStyle = 'Flat'
    $btnAbort.Add_Click({
        $script:userChoice = 'abort'
        $timer.Stop()
        $form.Close()
    })
    $form.Controls.Add($btnAbort)

    $timer          = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $script:countdown--
        if ($script:countdown -le 0) {
            $timer.Stop()
            $script:userChoice = 'proceed'
            $form.Close()
        }
        else {
            $label.Text = "Steam is shutting down in $($script:countdown)..."
        }
    })
    $timer.Start()

    [void]$form.ShowDialog()

    return ($script:userChoice -ne 'abort')
}

# -- Bootstrap SteamCMD -------------------------------------------------------
function Install-SteamCmd {
    if (Test-Path $SteamCmdExe) {
        Write-Host "[bootstrap] SteamCMD already installed at $SteamCmdExe" -ForegroundColor Cyan
        return
    }

    Write-Host "[bootstrap] Downloading SteamCMD from $SteamCmdUrl ..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $SteamCmdDir -Force | Out-Null
    Invoke-WebRequest -Uri $SteamCmdUrl -OutFile $SteamCmdZip -UseBasicParsing

    Write-Host "[bootstrap] Extracting to $SteamCmdDir ..." -ForegroundColor Yellow
    Expand-Archive -Path $SteamCmdZip -DestinationPath $SteamCmdDir -Force
    Remove-Item $SteamCmdZip -Force

    Write-Host "[bootstrap] Running initial SteamCMD self-update ..." -ForegroundColor Yellow
    & $SteamCmdExe +quit | Out-Null

    Write-Host "[bootstrap] SteamCMD installed successfully." -ForegroundColor Green
}

# -- Load settings ------------------------------------------------------------
function Get-Settings {
    if (-not (Test-Path $SettingsFile)) {
        throw "settings.yml not found at: $SettingsFile"
    }
    $raw = Get-Content $SettingsFile -Encoding UTF8 -Raw
    return ConvertFrom-Yaml -Yaml $raw -Ordered
}

# -- Resolve appREs to appIDs via Steam Web API --------------------------------
# Fetches the public app list once and caches it for the lifetime of the script.
$script:SteamAppList = $null

function Resolve-AppREs {
    param(
        [string[]]$Patterns
    )

    if ($null -eq $script:SteamAppList) {
        Write-Host "[api] Fetching Steam app catalogue ..." -ForegroundColor DarkCyan
        $response = Invoke-RestMethod -Uri $SteamAppListUrl -UseBasicParsing
        $script:SteamAppList = $response.applist.apps
        Write-Host "[api] Catalogue loaded ($($script:SteamAppList.Count) entries)." -ForegroundColor DarkCyan
    }

    $resolved = [System.Collections.Generic.List[string]]::new()
    foreach ($pattern in $Patterns) {
        $hits = $script:SteamAppList | Where-Object { $_.name -match $pattern }
        if (-not $hits) {
            Write-Warning "  [api] No apps matched pattern '$pattern'"
            continue
        }
        foreach ($app in $hits) {
            Write-Host "  [api] Pattern '$pattern' -> AppID $($app.appid)  ($($app.name))" -ForegroundColor DarkCyan
            $resolved.Add([string]$app.appid)
        }
    }
    return $resolved.ToArray()
}

# -- Update a single app ------------------------------------------------------
function Update-App {
    param(
        [string]$Login,
        [string]$Password,
        [string]$AppId,
        [string]$LibraryRoot
    )

    Write-Host "  [update] AppID $AppId  (account: $Login)" -ForegroundColor White

    $steamArgs = @(
        "+force_install_dir `"$LibraryRoot`", 
        "+login `"$Login`" `"$Password`", 
        "+app_update $AppId validate", 
        '+quit'
    ) -join ' '

    $proc = Start-Process -FilePath $SteamCmdExe `
                          -ArgumentList $steamArgs `
                          -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -ne 0) {
        Write-Warning "  [warning] SteamCMD exited with code $($proc.ExitCode) for AppID $AppId"
    }
    else {
        Write-Host "  [done]   AppID $AppId updated successfully." -ForegroundColor Green
    }
}

# -- Main ---------------------------------------------------------------------

# 1. Load settings early (needed for Steam relaunch credentials)
$settings    = Get-Settings
$libraryRoot = if ($settings['library_root']) { $settings['library_root'] } else { 'C:\SteamLibrary' }
$accounts    = $settings['accounts']
if ($null -eq $accounts) { throw "No 'accounts' key found in settings.yml" }

# First account is used to relaunch Steam.exe after updates
$firstAccountName = @($accounts.Keys)[0]
$firstAccount     = $accounts[$firstAccountName]
$firstLogin       = $firstAccountName
$firstPassword    = $firstAccount['password']

# 2. Handle running Steam instance
$steamExePath = Find-SteamExe
$steamWasOpen = $false
$steamProcs   = Get-Process -Name 'steam' -ErrorAction SilentlyContinue

if ($steamProcs) {
    $steamWasOpen = $true
    Write-Host "[steam] Steam is currently running." -ForegroundColor Yellow

    $proceed = Invoke-SteamShutdownDialog
    if (-not $proceed) {
        Write-Host "[abort] User aborted. Exiting." -ForegroundColor Red
        exit 0
    }

    Write-Host "[steam] Shutting down Steam ..." -ForegroundColor Yellow
    if ($steamExePath) {
        Start-Process -FilePath $steamExePath -ArgumentList '-shutdown' -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 4
    }
    # Force-kill any remaining steam processes
    Get-Process -Name 'steam' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Write-Host "[steam] Steam stopped." -ForegroundColor Green
}

# 3. Bootstrap SteamCMD
Install-SteamCmd

# 4. Update all apps
Write-Host "`n[config] Library root : $libraryRoot"
New-Item -ItemType Directory -Path $libraryRoot -Force | Out-Null

foreach ($accountName in $accounts.Keys) {
    $account  = $accounts[$accountName]
    $login    = $accountName                  # account label IS the Steam login
    $password = $account['password']

    # powershell-yaml may return $null, a bare string, or a List/array depending
    # on the YAML content.  Re-wrap via @() to guarantee a plain [object[]] whose
    # .Count is a real concrete property under Set-StrictMode -Version Latest.
    $appIDs = @(if ($null -ne $account['appIDs']) { $account['appIDs'] })
    $appREs = @(if ($null -ne $account['appREs']) { $account['appREs'] })

    if ($null -eq $password) { Write-Warning "Account '$accountName' has no 'password' -- skipping."; continue }
    if ($appIDs.Count -eq 0 -and $appREs.Count -eq 0) {
        Write-Warning "Account '$accountName' has neither 'appIDs' nor 'appREs' -- skipping."
        continue
    }

    # Resolve regex patterns to additional app IDs
    $resolvedIDs = @()
    if ($appREs.Count -gt 0) {
        $resolvedIDs = @(Resolve-AppREs -Patterns ([string[]]$appREs))
    }

    # Merge explicit + resolved IDs, deduplicate - keep as plain array
    $allIDs = @($appIDs + $resolvedIDs | Select-Object -Unique)

    Write-Host "`n[account] $accountName  ($($allIDs.Count) app(s))" -ForegroundColor Magenta

    foreach ($appId in $allIDs) {
        Update-App -Login $login -Password $password -AppId ([string]$appId) -LibraryRoot $libraryRoot
    }
}

Write-Host "`n[all done] Steam library update complete." -ForegroundColor Green

# 5. Relaunch Steam.exe logged in as the first account
if ($steamWasOpen) {
    if ($steamExePath) {
        Write-Host "[steam] Relaunching Steam as '$firstLogin' ..." -ForegroundColor Cyan
        # Steam.exe accepts -login <username> <password> on the command line
        Start-Process -FilePath $steamExePath -ArgumentList "-login `"$firstLogin`" `"$firstPassword`""
    }
    else {
        Write-Warning "[steam] Could not find Steam.exe -- please start Steam manually."
    }
}