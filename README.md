# GOB — Grab Our Bytes

A small Dropbox download manager for Windows and macOS, with automatic recovery, saved progress and a goblin appetite for large files.

## Windows detection investigation

Windows Defender reported `Behavior:Win32/DefenseEvasion.A!ml` for GOB 1.0.0 on an affected device. That build has not been cleared by Microsoft. Do not disable protection or add exclusions to run it.

[GOB 1.0.1 Windows test release](https://github.com/motionsamm-lgtm/dropbox-downloader/releases/tag/gob-v1.0.1-rc1) separates the installer from the app and gives the window a GOB process identity. It preserves the transfer engine and existing history. It remains a pre-release pending testing on affected devices, and is not distributed through automatic updates. Mac downloads are unchanged.

## Download GOB

| Your computer | Download |
| --- | --- |
| Windows 64-bit - test release | [GOB-Setup.exe](https://github.com/motionsamm-lgtm/dropbox-downloader/releases/download/gob-v1.0.1-rc1/GOB-Setup.exe) |
| Mac with an M-series chip | [GOB for Apple Silicon](https://github.com/motionsamm-lgtm/dropbox-downloader/releases/latest/download/GOB-Mac-Apple-Silicon.zip) |
| Mac with an Intel processor | [GOB for Intel](https://github.com/motionsamm-lgtm/dropbox-downloader/releases/latest/download/GOB-Mac-Intel.zip) |

[All releases and version notes](https://github.com/motionsamm-lgtm/dropbox-downloader/releases)

On Windows, run **GOB-Setup.exe**, choose Install, then open **GOB** from Start. A portable ZIP is also available in the Windows test release; extract the whole folder before opening its GOB.exe. On Mac, extract the ZIP, move **GOB.app** into Applications, and open it. Mac requires macOS 14 or newer. These builds have no commercial code-signing identity and the Mac app has not been notarized by Apple.

## Use

Paste a Dropbox link, choose where to save the file and start. Brutal starts enabled and falls back after retryable errors. History tracks downloads and one log per download. Folder ZIPs and servers that refuse ranges need a fresh transfer after interruption. Saved data folder and Clear partials help manage disk space.

## Updates

GOB checks for a release on startup and every hour. You can also click **Check for updates**. When a newer version is available, click **Update GOB** after pausing or finishing active downloads. GOB checks the downloaded build against the release's SHA-256 before installation and relaunches the app. The repository and release assets must be publicly accessible for updates without a GitHub login.

Older Dropbox Downloader builds need the first GOB installation manually. Subsequent GOB releases use the in-app updater.

## Project layout

| Folder | Contents |
| --- | --- |
| [windows](windows/) | GUI, transfer worker, updater, EXE launcher and build script |
| [mac](mac/) | Native app host, interface, worker, updater and regression tests |
| [assets](assets/) | GOB icon resources |
| [.github/workflows](.github/workflows/) | Build and release automation |
| [docs/archive](docs/archive/) | Earlier build workflows |

## Publish a new update

Open Actions, select **Release GOB for Windows and Mac**, and choose **Run workflow**. Enter a new three-part version such as **1.0.1**. Increase it for every release. The workflow stamps the version into both apps, builds all three downloads, runs the checks, and publishes the release with its update manifest only after the platform jobs pass. Existing release tags are kept and cannot be reused by this workflow.

Source changes should be committed before running a release. Apps learn about new versions when the release is published, rather than from source commits alone.

## Testing

Mac transfer and updater tests run with `node --test mac/Tests/*.test.mjs`. Native builds run on their corresponding GitHub runners. Windows builds parse the PowerShell scripts and test the packaged EXE extraction. Mac builds compile the native host, check code-signature structure, run the regression tests and test HTTPS through the bundled aria2. Interactive desktop behavior and real Dropbox links require device testing.
