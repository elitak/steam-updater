# steam-updater

A single PowerShell script that **bootstraps SteamCMD** (Valve's headless Steam client) and **downloads or updates every Steam app** listed in `settings.yml` — no GUI, no manual steps.

---

## How it works

1. On first run, `Update-SteamApps.ps1` downloads `steamcmd.zip` from Valve, extracts it to `%ProgramData%\SteamCMD`, and runs the self-update. Subsequent runs skip this step.
2. It reads `settings.yml` from the same directory.
3. For every account → for every `appid`, it calls:
   ```
   steamcmd.exe +force_install_dir C:\SteamLibrary +login <user> "<pwd>" +app_update <appid> validate +quit
   ```

---

## Requirements

| | |
|---|---|
| OS | Windows 10 / 11 or Windows Server 2016+ |
| PowerShell | 5.1 or later (built-in on Windows 10+) |
| Internet | Required for SteamCMD install and all downloads |
| Steam Guard | Must be **disabled** on every account (SteamCMD cannot handle interactive 2-FA) |

No extra modules or software needed — everything is self-contained.

---

## Quick start

### 1. Clone this repo

```powershell
git clone https://github.com/elitak/steam-updater.git
cd steam-updater
```

### 2. Edit `settings.yml`

```yaml
library_root: "C:\SteamLibrary"   # optional

accounts:
  my_account:
    login: my_steam_user
    password: "hunter2"
    appids:
      - 730    # CS2
      - 570    # Dota 2
```

You can have as many accounts and as many appids per account as you like.  
Find App IDs on [SteamDB](https://www.steamdb.info/).

### 3. Run

```powershell
.\Update-SteamApps.ps1
```

Running from an **elevated (Administrator) PowerShell** is recommended so SteamCMD can write to `C:\SteamLibrary` without permission issues.

If your execution policy blocks the script:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

---

## settings.yml reference

```yaml
library_root: "C:\SteamLibrary"   # Install path for all games (optional, default shown)

accounts:
  <label>:                         # Any label — not used by Steam
    login:    <steam_username>
    password: "<steam_password>"
    appids:
      - <appid_1>
      - <appid_2>
```

| Key | Required | Description |
|---|---|---|
| `library_root` | No | Where to install all games. Defaults to `C:\SteamLibrary`. |
| `accounts` | Yes | Dictionary of account entries. |
| `login` | Yes | Steam account username. |
| `password` | Yes | Steam account password. |
| `appids` | Yes | List of numeric Steam App IDs to download/update. |

---

## Scheduling (optional)

Open **Task Scheduler** and create a task that runs:

```
powershell.exe -ExecutionPolicy Bypass -File "C:\path\to\Update-SteamApps.ps1"
```

---

## Security note

`settings.yml` contains plaintext credentials. Do **not** commit a filled-in `settings.yml` to a public repository.
