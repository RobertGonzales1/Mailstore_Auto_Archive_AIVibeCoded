# Changelog

## 1.0.0 - 2026-10-08

First public release.

- Runs each MailStore Home archiving profile one at a time.
- Detects when archiving is finished by watching CPU usage, then closes MailStore.
- Progress window (WinForms) with a live log; `-NoUi` to run without it.
- `-Install` / `-Uninstall` to manage a daily Windows Scheduled Task (`-RunAt` sets the time).
- Per-profile timeout, stale `.lock` file cleanup, and daily log files with automatic cleanup.
