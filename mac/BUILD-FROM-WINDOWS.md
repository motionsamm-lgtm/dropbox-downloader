# Produce a Mac app from Windows

This ZIP contains the source and a GitHub Actions build. Give your friend
the ZIP produced by the build. It contains a Finder-launchable app with its
transfer tools included.

1. Put the extracted project files, including the `.github` folder, at the
   root of a GitHub repository you control. A private repository works.
2. Open **Actions → Build ready-to-open Mac app → Run workflow** on the
   repository's default branch. GitHub Actions must be enabled.
3. When a job is green, download its artifact. Open the downloaded artifact
   ZIP and send your friend the Mac ZIP inside it. Choose **Apple Silicon**
   for an M-series chip or **Intel** for an Intel processor.
4. Your friend extracts the Mac ZIP and opens the app in Finder. The test
   build is ad hoc signed. See OPEN-MAC-APP.txt if macOS prompts.

The workflow compiles the native app, builds aria2 with macOS system TLS,
bundles Node, checks for external library dependencies, tests the worker,
and verifies a real HTTPS transfer. The artifact uses the repository's
access settings. A friend should still test the window and real Dropbox
transfers on a Mac before relying on the app for important downloads.

GitHub documentation:
- https://docs.github.com/en/actions/managing-workflow-runs/manually-running-a-workflow
- https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts
