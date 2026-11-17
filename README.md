# Dropbox Downloader

Download large Dropbox files on Windows and macOS, with saved progress, automatic recovery and one log per download.

## Downloads

| Platform | Download | Open |
| --- | --- | --- |
| Windows 64-bit | [Windows EXE](https://github.com/motionsamm-lgtm/dropbox-downloader-mac/actions/runs/44045837593/artifacts/14310743660) | Extract the artifact ZIP and run DropboxDownloader.exe |
| Mac Apple Silicon | [M-series Mac](https://github.com/motionsamm-lgtm/dropbox-downloader-mac/actions/runs/44045837593/artifacts/14310804942) | Extract both ZIP layers and move the app to Applications |
| Mac Intel | [Intel Mac](https://github.com/motionsamm-lgtm/dropbox-downloader-mac/actions/runs/44045837593/artifacts/14312121200) | Extract both ZIP layers and move the app to Applications |

GitHub downloads require repository access. To share with teammates, send the extracted EXE or inner Mac ZIP. macOS 14 or newer is required. Mac builds are ad hoc signed and have not been notarized by Apple.

## Use

Paste a Dropbox link, choose the destination, and start. Select a History entry to resume or open its log. Folder ZIPs and servers that refuse byte ranges require a fresh transfer after interruption. Saved data folder and Clear partials help manage disk usage. Clearing saved progress requires a new download.

## Project layout

| Folder | Contents |
| --- | --- |
| [windows](windows/) | Windows GUI, worker, EXE launcher and build script |
| [mac](mac/) | Native Mac host, interface, transfer engine, tests and packaging |
| [.github/workflows](.github/workflows/) | Build both platforms from the checked-in sources |
| [docs/archive](docs/archive/) | Previous embedded build workflows retained for reference |

## Build

Open Actions, select Build Windows and Mac updates, and Run workflow. Download each completed platform artifact. Sources are organized by platform so future changes can be reviewed directly.

## Verification

The November 17 builds passed Windows script parsing and EXE extraction checks, Mac compilation, eight transfer regression tests, ZIP checks and an HTTPS download. Desktop interaction and real Dropbox links still require testing on the destination computer.
