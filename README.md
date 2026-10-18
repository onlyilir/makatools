# Makatools

A free, open-source maintenance toolkit for Windows 10 and Windows 11 (64-bit). No paid tiers, no ads, no telemetry. Built on the PowerShell 5.1 that comes with Windows, so there is nothing else to install.

## Install

**Easiest:** double-click `Makatools-Setup.exe` and answer **Yes**. It installs for your Windows account only, so it doesn't need administrator rights. It then adds Makatools to the Start menu and Desktop.

**From the zip:** extract the whole `Makatools.zip`, then double-click `Install Makatools.bat`. The result is the same.

**No install:** extract the zip and double-click `Start-Makatools.bat`.

To uninstall, go to **Settings > Apps > Makatools > Uninstall**.

To update, run a newer `Makatools-Setup.exe` over the top. Your log, settings and backups are kept. If automatic updates are set up in your copy, **Check for updates** on the Dashboard does this for you.

### Warnings you may see

Makatools is not code-signed, because a signing certificate costs money every year. So the first time you run it:

- **Windows SmartScreen** may say "Windows protected your PC". Click **More info**, then **Run anyway**.
- **Norton 360 / other antivirus** may warn about a new file that few people have downloaded yet. These reputation warnings are about how new and rare the file is, not about anything the file was found doing. If you trust where you got it from, allow it in Norton. The files are plain PowerShell scripts you can read in Notepad.

Gmail blocks `.exe` files, even inside a zip. To share it, use Google Drive, OneDrive or a USB stick.

## What it does

| Tab | What it does | Needs admin? |
|---|---|---|
| Dashboard | **Optimize now** (one-click cleanup), when you last cleaned, computer and Windows details, antivirus status, drive space and health, **Check for updates** | No |
| Cleanup | Scans junk files and pre-ticks the safe ones (see below). Optional privacy items. A weekly reminder. Windows component cleanup | Some items |
| Startup | Programs, Startup-folder shortcuts and sign-in tasks, each shown On or Off. **Switch off** / **Switch on** work like Task Manager, so nothing is deleted | All-users entries |
| Processes | Running programs by memory use, with an option to end one | No |
| Services | Starts and stops Windows services | Yes |
| Installed Programs | Lists installed programs and opens a program's own uninstaller | No |
| Duplicates | Finds identical files (same size, then same SHA-256) and moves extra copies to the Recycle Bin | No |
| Recover Deleted | Restores files from the Recycle Bin to where they came from | No |
| Secure Delete | Overwrites a file with random data, then deletes it | No |
| Disk Health | Disk health, read-only error scan, fragmentation analysis, optimize | Yes |
| Large Files | Lists the 200 biggest files in a folder (read-only) | No |
| Activity Log | Every change Makatools made | No |

### What Cleanup removes

These are caches and leftovers that Windows and your programs rebuild by themselves:

- Temporary files (your account and Windows)
- Browser caches: Edge, Chrome, Brave, Vivaldi, Opera, Opera GX, Firefox (every profile). Close the browser first.
- Thumbnail cache, the Internet cache used by Windows apps
- Error reports and crash dumps
- Graphics shader caches (DirectX, NVIDIA, AMD, Intel)
- Windows Update downloads that are already installed, the Delivery Optimization cache, and old setup/update logs
- App caches: Discord, Microsoft Teams, Spotify, Steam, Zoom logs

Listed but **never ticked for you**, because they can't be undone:

- The Recycle Bin.
- `Windows.old`, the previous Windows left after a big update (admin). Removing it takes away the option to go back. Windows' own Disk Cleanup does the removal.
- **Privacy items:**
  - browsing history and cookies for each browser (clearing cookies signs you out of websites);
  - the recently opened files list.
  
  Firefox history isn't offered, because Firefox keeps it in the same file as your bookmarks.

Also on the Cleanup tab:

- **Windows component cleanup** (separate button, admin). This is the same as Disk Cleanup's "Windows Update Cleanup". It can take 10+ minutes.
- **Weekly reminder:** when Makatools opens and it's been a week since the last cleanup, it offers to clean. This happens in the open, not as a hidden background task, because antivirus such as Norton treats hidden background scripts as malware.

If a browser or app whose cache you ticked is still open, Makatools warns you first, because its files are in use. **Optimize now** and the weekly reminder skip those items and tell you which ones.

Makatools **never** touches saved passwords, bookmarks, autofill, documents or the registry. Files that are in use are skipped.

## Works alongside Norton 360 and other antivirus

Makatools refuses to disable, stop or end anything that belongs to your antivirus. That includes Norton 360, Microsoft Defender, Avast, AVG, McAfee, Kaspersky, Bitdefender, ESET, Malwarebytes and others. Use the antivirus's own settings for those. The Dashboard shows which antivirus Windows reports as active.

## Safety

- Every deletion or change asks you to confirm first, and is written to the Activity Log.
- Switching a startup entry off only sets Windows' own on/off flag (the one Task Manager uses). Switch it back on in Makatools or in Task Manager.
- Updates are only installed after their SHA-256 checksum matches the one published with the release.
- Duplicates go to the Recycle Bin, so you can get them back.
- Large Files, Disk Health scan and analyze are read-only.

## Limits, honestly

- **Recover Deleted only covers the Recycle Bin.** Files deleted with Shift+Delete, emptied from the bin, or shredded can't be recovered here. True undelete needs low-level disk tools.
- **Secure Delete is not a guarantee on SSDs** or journaled file systems. Wear levelling can keep old copies of the data.
- **No registry cleaner, on purpose.** Removing "broken" registry entries rarely speeds Windows up and can break software.
- Some uninstallers use unusual command lines that may not start from the Installed Programs tab. Use Settings > Apps for those.
- Disk temperature and wear readings need admin rights; without them the table says "needs admin".
- Sharp display on screens scaled above 100% is switched on, but has only been checked at 100% so far.

## For developers

```
Makatools.ps1           entry point (relaunches in 64-bit PowerShell if needed)
src\Core.ps1            all logic, no UI
src\Ui.ps1              WinForms window; slow work runs in a background runspace with a progress bar
SHARING.md              antivirus warnings, code signing, setting up automatic updates
assets\                 logo.png and Makatools.ico
setup\                  Install.ps1, Uninstall.ps1, Bootstrap.ps1 (used inside Setup.exe)
build\Build-Bundle.ps1  makes dist\Makatools.ps1 (one file), dist\Makatools.zip, dist\Makatools-Setup.exe
build\Make-Logo.ps1     makes the logo and icon from a photo
tests\Run-Tests.ps1     unit + UI tests (temp folders, throwaway registry key)
tests\Test-Setup.ps1    install/uninstall tests; add -SetupExe dist\Makatools-Setup.exe to test the exe
```

Run the tests (run `Run-Tests.ps1` once more as administrator to include the admin-only tests):

```
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Setup.ps1
```

`Build-Bundle.ps1 -WithAppExe` also compiles `Makatools.exe` with the ps2exe module. That needs internet the first time, and antivirus often flags ps2exe output, so the installer doesn't use it.
