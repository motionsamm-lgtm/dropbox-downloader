# GOB 1.2.3

- Added a persistent queue for independent Dropbox and Google Drive links. Accepted entries clear the form and keep the save folder. Waiting jobs start in order.
- Queue rows show provider and size where available. Folder rows show child sizes, progress, and failure details.
- Refined Brick controls and card outlines on Windows and queue styling on macOS.
- Folder jobs now use the saved snapshot index for each file. Windows reads the final worker record after exit, and Resume keeps verified files. Drive permission and provider-wide errors are reported without exposing keys or links.
