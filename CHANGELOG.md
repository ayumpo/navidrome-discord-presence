# Changelog

## 1.0.1

- Fix: the status could stay empty when your Navidrome username was typed with different capitalization than your account (Navidrome accepts either at login, but reports playback under the stored spelling). Usernames and player names now match regardless of case, and setup saves the server's spelling.
- Windows: the background copy now writes a log file (`%APPDATA%\navidrome-presence\navidrome-presence.log`); new `troubleshoot.bat` and `show-log.bat`; re-running `setup.bat` restarts it instead of starting a second copy.
- `--check` gives a hint when nothing is playing for your user.

## 1.0.0 — first public release

- Shows your Navidrome "now playing" as a Discord "Listening to" status over Discord's local Rich Presence connection. No Discord token involved.
- Song, artist, album cover, progress bar; pause badge with a "paused for" timer; playback-speed aware.
- Clickable song/artist/cover (Spotify via ListenBrainz, or YouTube Music / Deezer / Apple Music search).
- Album art from your own Navidrome (via uguu.se), the Cover Art Archive, Deezer or iTunes.
- Customisable "Listening to …" name.
- One-command Proxmox setup that runs the official Discord app on a virtual screen (24/7), with in-place updates.
- One-line installers for macOS and Linux; Windows setup script (beta).
