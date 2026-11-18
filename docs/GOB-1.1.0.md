# GOB 1.1.0 — Folder downloads and download controls

Paste a shared-folder link to download its files separately into one local folder. GOB lists every page and subfolder before starting transfers. History shows one folder job with combined progress, speed, ETA and file counts. Expand its file list to see individual states.

- **Pause:** stops active transfers and automatic retry delays, then acknowledges Paused after checkpoints are saved.
- **Resume:** reopens the same saved job and checkpoints. Completed folder files stay in place; unfinished files are retried individually.
- **Remove from list:** removes the History entry while keeping downloaded files and partial progress on disk. Job records and logs are archived under History/Removed.
- **Delete files…:** asks first, then sends the job's tracked files and partials to Recycle Bin or Trash. Unrelated files in the save folder are excluded. Windows may display its own confirmation when recycling is unavailable; cancel that prompt to keep the file.
- **Brutal:** starts enabled, shares up to 16 connections across up to three files, and backs down after recoverable errors. Actual throughput still depends on Dropbox, your connection and storage.
- **Logs:** one evolving log per download, with timestamped attempts, transfer errors, recovery, completion and elapsed time. Folder logs record the combined outcome; Windows also keeps each child file's diagnostic log.

The existing interface, matte-black goblin icon, native Windows host, saved history and in-app updater are retained. The Windows window scrolls/resizes so the new controls remain reachable on smaller displays. Mac actions run through the native app's message bridge.

## Existing downloads

Single-file checkpoints continue using the existing recovery checks. Old folder-ZIP jobs remain legacy ZIP jobs; their downloaded bytes cannot be converted into separate per-file checkpoints. A new shared-folder job uses the file-by-file approach.

A pause arriving at the final byte keeps completion proof so Resume can finish local verification/publication without downloading the file again. A received-byte count alone never marks a transfer complete.

## Folder access and limits

This release keeps paste-only operation. Public shared-folder listing uses Dropbox's unversioned website interface, with anonymous session cookies created by GOB itself. It does not read browser cookies, require a connected Dropbox account, embed app secrets, or send links to a GOB server.

Password-protected, sign-in-only or download-disabled folders are not supported by this anonymous listing path. If Dropbox changes the response, returns an incomplete page, or does not supply a usable continuation, GOB reports the issue and keeps saved files. It does not silently substitute a non-resumable ZIP or call a partial listing complete.

File lists are capped at 100,000 entries and 128 directory levels. The UI displays the first 500 child rows for large jobs while totals and transfers include all listed files. Filename collisions and characters unsupported by Windows receive deterministic local names; the original relative names remain in the manifest.

Resume requires server byte-range support and matching source checks. A server that refuses resume can still require a fresh stream. Changed or missing completed files require attention before a folder can resume safely.

Expected SHA-256 is optional and applies to individual files. Leave it blank unless the sender supplied a checksum.

## Validation

Release only after the native Windows build, actual-engine transfer tests, folder queue/recovery tests, public listing checks, native Mac host/runtime tests, platform packaging and updater checks pass. Apple Silicon remains cross-compiled and architecture/signature checked on an Intel builder; native Apple Silicon device testing is still needed.
