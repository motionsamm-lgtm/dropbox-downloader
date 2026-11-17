DROPBOX DOWNLOADER FOR WINDOWS 2.0.4

1. Extract this ZIP. Keep your existing downloader and any active transfer
   open until it finishes.
2. If needed, download the Windows 64-bit aria2 ZIP from
   https://github.com/aria2/aria2/releases/latest and copy aria2c.exe into
   this downloader folder.
3. Open Start-Downloader-GUI.cmd. Start-Downloader.cmd still opens the
   original command-line prompts for single files.
4. Paste the Dropbox link, choose a save folder, and click Start / Resume.
   The history row shows progress, speed, and ETA. If live readings
   are unavailable, it can estimate from saved aria2 checkpoints.

The GUI launcher may briefly flash a command window while starting.
The GUI and its background worker are started without a console.

WINDOWS INTERFACE
The native Windows window keeps download setup, history and progress
together. Paste a recognized Dropbox file or whole-folder link to detect
the type automatically. The close prompt applies while a job is starting,
downloading or verifying.

Brutal is enabled for new GUI jobs. Folder ZIPs still use one stream.
Create filename subfolder is off by default. If enabled, a download named
Podcast.mp4 goes in the Podcast subfolder under the selected destination.
Any partial files are saved there too. Desktop notifications
can be switched off per job. When enabled, desktop notifications report
start, completion and failure, including while the GUI is closed.

COMPLETION RECOVERY
A late connection error can coexist with a completed transfer. The app
checks aria2's final result and saved pieces before deciding to retry.
In History, File found means the final path exists but needs confirmation.
Resume can use a saved completion record. If you already checked the file
yourself, choose Mark complete to record your confirmation.

DOWNLOAD HISTORY
The Windows GUI saves every new download before starting it. Links are
protected by your Windows user account. Select an interrupted or failed
entry and choose Resume selected to reuse its exact link and settings.
One-pass and folder ZIP entries ask before restarting from zero.
If you close the GUI while downloading, you can keep the download
running in the background and reopen the GUI to follow its progress.
Older downloads only appear in history after you add them once with
the original link, output filename, and save folder. Keep their partials.

SINGLE FILE
Use a file share link or open the MP4 in its shared folder and paste the
MP4's URL. The default is four connections and no configured speed limit.
If parallel transfers fail, try one connection. The optional limit is in
MiB/s. To stop, press Ctrl+C in the download window. Leave the .part and
.aria2 files together with the .resume.json file, and use the same link,
filename and save folder to resume. Existing partials from older versions
can be resumed with the exact same link, filename and folder. A renewed
share link can reuse a v1.6 checkpoint when only its session parameter
changes and Dropbox provides the same strong ETag, size and file prefix.
A new direct address still needs a separate download.

RECOVERY
Single files retry transient HTTP and network failures automatically.
After a transfer failure, the downloader rechecks the same URL, waits
between attempts and reduces parallel connections. After the first
retryable error in Brutal, the same run switches to one connection and
normal retry settings, keeping the checkpoint and applying any configured
normal speed cap. The switch appears in the status and text log. Retries
are bounded. Dropbox must
accept byte-range requests to resume. The downloader stops if its source
checks show the file has changed, keeping the partial and checkpoint.
Ctrl+C stops the download without scheduling another attempt.

If a folder-contained MP4 link fails, the worker also accepts the direct
dl.dropboxusercontent.com address from a browser or download manager.
Direct addresses can expire. Share error text without the private URL.

PLAIN-ENGLISH DOWNLOAD LOG
Select a download in History and click Open text log. Each history
entry has one log. Automatic retries and Resume selected add to that
same log. Start download creates a separate history entry and log.
Command-line downloads keep a log in the save folder and append when
the same source and output filename are used again.

Each attempt has a timestamped heading and records settings, progress,
errors, retry steps, verification, the result and elapsed time. If the
worker is stopped suddenly, its section may end at the last recorded
step. Older logs are kept separately. The text log omits URLs and paths
and can be shared manually. Normal cleanup removes the temporary raw
engine log.

RECOVER A COMPLETED DOWNLOAD
The download window reports transfer, verification and final saving
separately. If Windows locks the completed file, the downloader retries
the rename. If it still cannot save, keep the .part and .ready.json files.
Run Start / Resume with the same link, filename and folder to finish
saving without contacting Dropbox. If the app is interrupted before the
completion record is written, it keeps the partial for inspection.

ONE PASS AND VERIFICATION
If Dropbox ignores byte-range requests, One pass can start a separate
single-connection download from zero, leaving existing checkpoints alone.
One pass requires a known file size and cannot continue after interruption.
Files are checked for size and, when sampled, for a matching prefix.
For end-to-end verification, paste an expected SHA-256 from the sender.
Computing the hash reads the whole file after transfer.

BRUTAL MODE
Check Brutal in the GUI before starting or resuming. For single files it
uses up to 16 connections and ignores the speed cap. For folder ZIPs it
removes the cap and uses one connection. Dropbox and your internet line
determine actual throughput. Automatic recovery applies to resumable
files after a retryable error. New jobs still start with Brutal enabled.

SHARED FOLDER
Select Shared folder as ZIP and paste the link to the whole folder.
Dropbox supplies the ZIP and controls its limits. This mode uses one
connection. Restart from the beginning if it is interrupted. Incomplete
folder ZIPs stay as .part files. The worker checks that the completed ZIP
opens before it gives the file its final name. Extract the ZIP in Windows.

The launcher requires Windows PowerShell, curl.exe, and aria2c.exe.
No administrator rights are required. The launchers set PowerShell's
execution policy only for their own PowerShell process.
