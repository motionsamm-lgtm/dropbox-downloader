# Dropbox Downloader for Mac 0.1.0

This is a build-on-Mac preview. It uses an AppKit window, a responsive local WebKit interface, and aria2 for transfers. A Mac with macOS 14 or newer builds the app for its own architecture (Apple Silicon or Intel). The built app uses your installed Node.js and aria2.

## Build and open

1. Extract the ZIP. Open Terminal and change into the extracted `Dropbox-Downloader-Mac` folder.
2. If the Apple Command Line Tools are missing, run `xcode-select --install` and finish the installer.
3. With Homebrew installed, run `brew install node aria2`. The app looks in the standard Apple Silicon and Intel Homebrew locations. Node.js 22 or newer is required.
4. Run `bash Build-Mac.command`. This creates and locally ad hoc signs `build/Dropbox Downloader.app`.
5. Open that app from Finder. Subsequent launches are through Finder or Spotlight. To rebuild, first move the previous app out of the build folder.

Homebrew installation and platform support: <https://brew.sh/> and <https://formulae.brew.sh/formula/aria2>.

## Download and resume

Paste a Dropbox file link or a whole shared-folder link and select a save folder. A shared folder downloads as the ZIP Dropbox returns. **Brutal** starts on for new downloads and requests up to 16 connections on resumable files. After a retryable transfer failure, it automatically moves to one connection and reapplies the normal speed cap if configured. Transfer speed depends on Dropbox, the disk and the connection.

Use **Pause** to save progress and **Resume** in History to continue. **Update link** can reuse saved progress if the replacement matches the source. If Dropbox keeps refusing requests, retries end and the files stay available for a later attempt. Folder ZIPs and **One pass** use one connection and require a fresh start after interruption. Confirming a restart keeps the interrupted files separately. Closing the window leaves the app and transfer running. Before quitting, pause the transfer and wait for the checkpoint.

**Open text log** opens the same plain-text log after retries or resumes. Each attempt records the time, mode changes, failures and result. The app saves history and the original links in your private local Application Support folder. Links are excluded from text logs, but the local history records contain them. Transfer checkpoints stay beside the output as hidden working files. Mac History is separate from Windows History and does not import Windows partials.

The app holds progress below 100% until verification and final naming finish. A completed partial can be verified and saved locally after an interrupted finalization. Add the sender's SHA-256 if you need end-to-end integrity verification for a single file.

## Mac acceptance check

- Resize the window, then download a small shared file and a folder ZIP. Check Finder reveal, text log and optional notifications.
- Pause a large resumable file, quit, reopen and resume. Check that the same History entry and log are reused.
- Try an expired or changed link. Check that saved progress stays available.
- Test a destination on any external drive you plan to use. The preview builds locally and is not a notarized installer.

The portable worker tests run with `node --test Tests/engine.test.mjs`. They use a local HTTP fixture and simulated aria2 outcomes, plus the system ZIP verifier. The native macOS build, WebKit bridge, permissions and live Dropbox transfers require a Mac test.
