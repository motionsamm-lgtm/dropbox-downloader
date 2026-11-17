GOB 1.0.1 Windows test build

Install: run GOB-Setup.exe and choose Install. Open GOB from Start.
Portable: extract the entire GOB-Windows-Portable.zip, then open GOB.exe.
Keep aria2c.exe and GOB.ico beside the portable EXE.

The existing interface, download engine, checkpoints, history and logs are retained.
The Windows GUI and helpers now run as GOB.exe, using Windows' installed scripting
engine inside the app process. No powershell.exe child process or execution-policy
command-line override is used. Normal app launches do not extract or copy the app.
The standard Inno Setup installer owns installation and the Start menu shortcut.
No antivirus settings, exclusions, certificate stores or security services are changed.

This is a pre-release for Windows testing. It has not been cleared by Microsoft.
Do not disable Defender or add exclusions if a detection occurs. Report the detection
name and whether it happened during setup, launch, download or update.

Existing download data remains in LocalAppData\DropboxDownloader\History.
Uninstalling GOB does not delete saved downloads, checkpoints or history.
Use the app's saved-data and partial-cleanup buttons to manage download data.

Source: https://github.com/motionsamm-lgtm/dropbox-downloader
