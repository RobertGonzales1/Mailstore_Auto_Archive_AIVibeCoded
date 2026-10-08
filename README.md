# MailStore Home Auto Archive

A PowerShell script that runs your [MailStore Home](https://www.mailstore.com/en/products/mailstore-home/) archiving profiles automatically on a schedule. It shows a small progress window, and closes MailStore when the work is done.

MailStore Home has no built-in scheduler, and when started from the command line it **does not exit after archiving finishes**. This script works around both problems:

- It runs each archiving profile one at a time, exactly like MailStore's own desktop shortcuts.
- It watches MailStore's CPU usage and closes the app once it has been idle long enough (i.e. archiving is done).
- It registers itself as a daily Windows Scheduled Task with one command.
- It cleans up stale `.lock` files left behind if MailStore was force-closed.
- It writes a daily log file and deletes old logs automatically.

> **Note:** This project was written with AI assistance ("vibe coded") and tested on the author's own setup. Review the script and test it by hand before you rely on it. It is not affiliated with or endorsed by MailStore Software GmbH.

---

## Requirements

- Windows 10 / 11 (or Windows Server) with **Windows PowerShell 5.1** (built in)
- **MailStore Home**, either the portable version or a normal install
- At least one **archiving profile** already set up and working in MailStore
- An **active desktop session** for the user that runs the task. A locked screen or a disconnected RDP session is fine; being fully logged out is not (MailStore needs a desktop to run).

---

## Installation

### 1. Download the script

Download [`Invoke-MailStoreArchive.ps1`](Invoke-MailStoreArchive.ps1) (or clone this repo) and put it somewhere **permanent**, for example:

```
C:\Scripts\Invoke-MailStoreArchive.ps1
```

Don't leave it in `Downloads` or a temp folder. The scheduled task points at this exact path.

### 2. Unblock the file

Files downloaded from the internet are blocked by Windows. Open PowerShell and run:

```powershell
Unblock-File C:\Scripts\Invoke-MailStoreArchive.ps1
```

If scripts are disabled on your machine, allow them for your user:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### 3. Find your MailStore paths and profile IDs

The easiest way to get the exact values is to let MailStore tell you:

1. Open MailStore Home.
2. Go to **Archive E-mail**, right-click (or select) one of your profiles and choose **Create Shortcut on Desktop**.
3. Right-click the new desktop shortcut and choose **Properties**.
4. Look at the **Target** and **Start in** fields. They will look something like:

   ```
   Target:   D:\Mailstore\Application\MailStoreHome.exe /portable /c archive --id="2"
   Start in: D:\Mailstore\Application
   ```

   - The `.exe` path → `$Exe`
   - The **Start in** folder → `$WorkDir`
   - `/portable` present? → keep `$PreArgs = '/portable'`. Not present → set `$PreArgs = ''`
   - The number in `--id="2"` → that profile's `Id`

Repeat step 2–4 for each profile you want to archive.

### 4. Edit the configuration block

Open the script in a text editor (Notepad, VS Code, PowerShell ISE) and edit the **CONFIGURE THIS BLOCK** section near the top:

```powershell
$Exe     = 'D:\Mailstore\Application\MailStoreHome.exe'
$WorkDir = 'D:\Mailstore\Application'
$PreArgs = '/portable'          # '' for a normally installed copy
$DataDir = 'D:\Mailstore\Data'  # for stale .lock cleanup; '' to skip

$Profiles = @(
    @{ Id = '1';  Label = 'My Mailbox' }
    @{ Id = '2';  Label = 'Work Mailbox' }
)
```

The `Label` is just a friendly name shown in the progress window and logs.

### 5. Test it by hand

```powershell
cd C:\Scripts
.\Invoke-MailStoreArchive.ps1
```

You should see a progress window, MailStore start minimized, archive each profile, and then close. Check the log afterwards (see [Logs](#logs)).

### 6. Install the daily scheduled task

```powershell
.\Invoke-MailStoreArchive.ps1 -Install                 # runs daily at 07:30
.\Invoke-MailStoreArchive.ps1 -Install -RunAt '22:00'  # or pick your own time
```

The task is created for the **current user**, so run this as the user who uses MailStore. To test the task right away:

```powershell
Start-ScheduledTask -TaskName 'MailStore Daily Archive'
```

---

## Usage

| Command | What it does |
|---|---|
| `.\Invoke-MailStoreArchive.ps1` | Run all profiles now, with the progress window |
| `.\Invoke-MailStoreArchive.ps1 -NoUi` | Run all profiles now, with no window |
| `.\Invoke-MailStoreArchive.ps1 -Install` | Register the daily scheduled task (default 07:30) |
| `.\Invoke-MailStoreArchive.ps1 -Install -RunAt 'HH:mm'` | Register the task at a specific time |
| `.\Invoke-MailStoreArchive.ps1 -Uninstall` | Remove the scheduled task |

If you change the script's settings later, you don't need to reinstall. The task always runs the current version of the file. Reinstall only if you **move** the file or want a different time.

---

## Configuration reference

| Setting | Default | Description |
|---|---|---|
| `$Exe` | `D:\Mailstore\Application\MailStoreHome.exe` | Full path to `MailStoreHome.exe` |
| `$WorkDir` | `D:\Mailstore\Application` | Working directory ("Start in" from the shortcut) |
| `$PreArgs` | `/portable` | Extra arguments before `/c`. Use `''` for an installed copy |
| `$DataDir` | `D:\Mailstore\Data` | MailStore data folder, used to clear stale `.lock` files. `''` to skip |
| `$Profiles` | one example | List of profiles to run, each with `Id` and `Label` |
| `$TimeoutMinutes` | `30` | Hard stop per profile. Increase for very large mailboxes |
| `$IdleSeconds` | `90` | How long CPU must stay near zero before a profile counts as finished |
| `$MinRunSeconds` | `45` | Startup grace period before idle detection begins |
| `$ShowMailStore` | `$false` | `$true` shows MailStore's own window (it will steal focus) |
| `$KeepWindowSecs` | `20` | How long the summary stays on screen (120 s minimum after a failure) |
| `$WindowTopMost` | `$false` | `$true` keeps the progress window above other apps |
| `$LogDir` | `%LOCALAPPDATA%\MailStoreAuto\logs` | Where log files are written |
| `$KeepLogDays` | `60` | Logs older than this are deleted |
| `$TaskName` | `MailStore Daily Archive` | Name of the scheduled task |

---

## Logs

One log file per day is written to:

```
%LOCALAPPDATA%\MailStoreAuto\logs\mailstore-<COMPUTERNAME>-<yyyy-MM-dd>.log
```

Paste `%LOCALAPPDATA%\MailStoreAuto\logs` into the Explorer address bar to open the folder.

The script exits with code `0` when every profile succeeded, and `1` if any profile failed or timed out. Task Scheduler shows this as the task's **Last Run Result**.

---

## How it works

For each profile, the script:

1. Closes any running MailStore and removes stale `.lock` files.
2. Starts MailStore with the same arguments its desktop shortcut uses:
   `MailStoreHome.exe /portable /c archive --id="<Id>"` in the shortcut's working directory.
3. Checks MailStore's CPU usage every 10 seconds. Once usage stays near zero for `$IdleSeconds`, archiving is considered done and MailStore is closed (gracefully first, forcefully if needed).
4. If a profile runs longer than `$TimeoutMinutes`, it is force-closed and logged as an error.

Profiles are run **one at a time** on purpose. Passing several IDs at once (`--id="1,2,3"`) has been reported to skip profiles.

---

## Troubleshooting

**MailStore opens on the home screen and just sits there.**
One of the three launch details is wrong. Check that `$Exe` is `MailStoreHome.exe` (not another exe in that folder), that `$WorkDir` matches the shortcut's **Start in** folder, and that `$PreArgs` matches the shortcut (`/portable` must come **before** `/c`).

**The scheduled task shows "Running" but nothing happens / no window appears.**
The task runs in your interactive session. Make sure you are logged in (locked is fine). It will not run while you are signed out.

**"Executable not found" in the log.**
`$Exe` points to the wrong place. Copy the path from the shortcut's Target field.

**A profile times out every time.**
Your mailbox may need more time on the first run. Raise `$TimeoutMinutes`.

**MailStore gets closed before it has finished.**
Raise `$IdleSeconds` (e.g. to `180`). Some servers have long pauses with almost no CPU activity.

**"running scripts is disabled on this system".**
See [step 2](#2-unblock-the-file).

---

## Uninstall

```powershell
.\Invoke-MailStoreArchive.ps1 -Uninstall
```

Then delete the script file and, if you want, the log folder `%LOCALAPPDATA%\MailStoreAuto`.

---

## Contributing

Issues and pull requests are welcome. If you report a problem, please include the relevant lines from your log file. **Remove any email addresses or server names first.**

## License

[MIT](LICENSE)
