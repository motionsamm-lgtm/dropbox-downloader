# GOB 1.2.4

- Drive folder downloads use one connection per file to reduce request pressure.
- Recovery keeps progress backed by a saved checkpoint and reports HTTP status and retry details when reopening a file fails.
- Folder summaries show the provider error once. Google can still temporarily block media requests.
