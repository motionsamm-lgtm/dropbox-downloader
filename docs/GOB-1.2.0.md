# GOB 1.2.0 — Dropbox + Google Drive, redesigned controls

## What's new

- Paste Dropbox or Google Drive links. GOB identifies the provider and whether the link points to a file or folder.
- Public Google Drive binary files download through the resumable transfer engine. Public folders are listed before transfers start, then downloaded as separate tracked files while appearing as one History job.
- Folder output defaults to a normal folder. A ZIP is optional and is assembled only after each included file has completed verification.
- Google Drive permission failures explain that the link must allow “Anyone with the link” and downloading. GOB does not request Google sign-in or access private client files.
- Settings provides System, Light and Dark themes, color customization, scale/density preferences on Mac, and transfer defaults including folder output, subfolder, Brutal, connections and notifications.
- Windows uses the resizable two-panel layout, themed dialogs, and custom caption controls. Mac has the corresponding Settings sections and follows the OS appearance when System is selected.
- Dropbox's existing file/folder detection, retry fallback, pause/resume, history, logs, notifications, cleanup controls and in-app update path remain available.

## Supported links and limits

- Google Drive: public binary file and folder share links only. Viewers must be allowed to download. Google Docs, Sheets and Slides export and sign-in-only links are not supported.
- Drive shortcuts are followed when the target can be read. Unsupported items are reported before a folder begins transferring.
- Folder downloads are planned from a complete listing. A listing or permission error prevents child downloads from starting.
- A Google Drive API key restricted to the Drive API is bundled in the public desktop apps to support anonymous public-link metadata and listing requests. Desktop app users can extract that key; API restriction and project quota controls limit its use. Keep quota alerts and caps enabled.
- Google API quotas or provider throttling can slow or pause transfers. GOB retries retryable API responses and keeps completed files/checkpoints for resume.
- An older ZIP-style Dropbox folder checkpoint cannot be converted into separate file checkpoints.

## Updates

Use **Check for updates** inside GOB. The release workflow publishes the Windows installer, Windows portable app, Intel Mac app and Apple Silicon Mac app with one verified update manifest. Active transfers must be paused or finished before replacing the app.

## Validation

The Mac JavaScript regression suite covers Drive public file and folder transfers, resource keys, retries, folder ZIP assembly, safe output paths and existing Dropbox recovery. Release workflow gates additionally compile the Windows EXE/installer, run Windows transfer/updater checks, build and sign both Mac architectures, run Mac folder/update checks, scan Windows artifacts, and verify the public update feed and downloaded asset hashes.

The release remains subject to the Windows and Mac hosted-runner checks. Apple Silicon is cross-compiled on an Intel runner; native Apple Silicon device testing is not part of the hosted release gate. Mac apps are ad hoc signed and not notarized by Apple.
