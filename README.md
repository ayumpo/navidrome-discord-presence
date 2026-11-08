# Navidrome Discord Presence

Show what you're playing on [Navidrome](https://www.navidrome.org) as your Discord status: **"Listening to Navidrome"** with the song, artist, album cover and a progress bar. It does this **without breaking Discord's rules**.

[![CI](https://github.com/ayumpo/navidrome-discord-presence/actions/workflows/ci.yml/badge.svg)](https://github.com/ayumpo/navidrome-discord-presence/actions/workflows/ci.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

It works with **any** Navidrome app (the web player, Feishin, Narjo, Symfonium, Amperfy…) because it reads what your Navidrome server says is playing.

## Why this exists

The [official Navidrome Discord plugin](https://github.com/navidrome/discord-rich-presence-plugin) is great, but it needs your **Discord user token**, the secret key to your account. Using it to automate your account goes against Discord's Terms of Service and can get the account flagged, and anyone who gets hold of that token can take over your account.

This project never touches a token. It uses the same official, local "Rich Presence" connection that games and music players use to tell your Discord app what you're doing:

```
Navidrome ──"now playing"──▶ navidrome-presence ──local connection──▶ the Discord app (logged in normally)
```

The only catch is that a Discord app has to be running on the same machine. There are two ways to handle that:

| Setup | Best for | What it needs |
|---|---|---|
| **[Proxmox](#setup-proxmox-recommended)** ⭐ | Your status works 24/7, even with your computers off | A Proxmox VE server |
| **[Mac](#setup-mac)** | Simple, nothing extra to run | The Discord app open (it can stay in the background) |
| **[Linux desktop](#setup-linux-desktop)** | Same, on Linux | The Discord app open |
| **[Windows](#setup-windows-beta)** (beta) | Same, on Windows | The Discord app open |

## Before you start: two things in Discord (about 3 minutes)

**1. Create your Discord "application".** It's free and is really just the name shown after "Listening to".

1. Go to **<https://discord.com/developers/applications>** and log in with your normal Discord account.
2. Click **New Application** (top right).
3. Type a name, for example **Navidrome**. Your status will read "Listening to *Navidrome*".
4. Tick the box to accept the terms, then click **Create**.
5. On the page that opens, find **Application ID** and click **Copy**. The installer will ask for it.

*Optional:* upload an App Icon on that page (for example the Navidrome logo). It shows in some places in Discord.

**2. Allow Discord to show your activity.** In the Discord app go to **Settings → Activity Privacy** and turn on **Share my activity**. If this is off, nothing shows up at all, not even to you.

## Setup: Proxmox (recommended)

This runs a small container on your Proxmox server with the **official Discord app** on a virtual screen. You log in to Discord once through your browser, and from then on your status updates 24/7.

1. In the Proxmox web interface, click your node (under *Datacenter*), then click **Shell**.
2. Paste this and press Enter:

   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main/proxmox/create-lxc.sh)"
   ```

3. Answer the questions. Each answer is checked right away:
   - your **Navidrome address** (what you type in a browser at home, e.g. `http://192.168.1.10:4533`)
   - your **Navidrome username and password**
   - the **Discord Application ID** you copied
   - whether to show **your Navidrome's own album covers** (see [privacy](#privacy))
4. When it's done it shows a **link and a one-time password**. Open the link in your browser, enter the password, and log in to Discord. The easiest way is **scanning the QR code** with the Discord app on your phone (Profile → Scan QR Code).

That's it. Play a song and your status updates within a few seconds.

- **Update:** run the same command again. Your settings and Discord login are kept.
- **Resources:** 2 CPU cores, 2 GB RAM, 8 GB disk. The container starts automatically with Proxmox.
- **Router:** nothing to open. Everything connects outward.

<details>
<summary>Handy commands inside the container (Proxmox → the <code>discord-presence</code> container → Console)</summary>

| Command | What it does |
|---|---|
| `navidrome-presence-check` | Tests Navidrome and Discord, and shows a test status for 15 seconds |
| `navidrome-presence-logs` | Shows what it's doing, live |
| `navidrome-presence-config` | Edits the settings, then restarts |
| `navidrome-presence-login` | Reopens the Discord screen in your browser (new password, closes after 30 min) |
| `bash /root/setup-proxmox.sh --uninstall` | Removes it (`--purge` also logs Discord out and deletes everything) |

The official Discord app updates itself weekly. To change the container size or name before creating it, set e.g. `NDP_MEMORY=3072 NDP_HOSTNAME=music-presence` in front of the command.
</details>

## Setup: Mac

1. Make sure the **Discord app** is installed and you're logged in.
2. Open the **Terminal** app (press ⌘ Space, type *Terminal*, press Enter).
3. Paste this and press Enter:

   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main/install-macos.sh)"
   ```

4. Answer the questions. A test status appears on your Discord profile for 15 seconds, and then it keeps running in the background and starts when you log in.

If macOS asks to install the **Command Line Tools**, click Install, wait for it to finish, and paste the command again.

Discord needs to be **open**, but it can sit in the background with no window. Tip: add Discord under **System Settings → General → Login Items**. To update, paste the command again. To remove it, paste it with `-- --uninstall` added at the very end.

## Setup: Linux desktop

On the computer where you use Discord, open a terminal and run (as your normal user, not with sudo):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ayumpo/navidrome-discord-presence/main/install-linux.sh)"
```

You need Python 3, which almost every distro already has. Flatpak, Snap and Vesktop versions of Discord are detected automatically. To update, run it again. To remove it, add `-- --uninstall` at the end.

## Setup: Windows (beta)

1. Install **Python** from <https://www.python.org/downloads/>. On the first installer screen, tick **"Add python.exe to PATH"**.
2. Download this project: green **Code** button → **Download ZIP**. Unzip it somewhere permanent, for example `Documents\navidrome-discord-presence`.
3. Open the `windows` folder and double-click **`setup.bat`**. Answer the questions.

It then runs in the background and starts when you log in to Windows. To remove it, double-click **`windows\remove.bat`**. Windows support is new, so please [open an issue](https://github.com/ayumpo/navidrome-discord-presence/issues) if anything goes wrong.

## What you'll see

Click your name in Discord to see the full card:

- **Listening to Navidrome**, plus the **song**, **artist**, **album cover** (hover over it for the album name) and a **progress bar**
- **Paused:** a pause badge on the cover and a "paused for" timer
- **Clickable** song, artist and cover: they open the track on Spotify (an exact match when [ListenBrainz](https://listenbrainz.org) knows it, otherwise a search)
- The short line under your name shows the **song title**
- It clears when you stop playing

All of this can be changed in the settings file. Every option is explained in [`config.example.ini`](config.example.ini): what follows "Listening to" (the track, artist, album or a template like `{artist} - {track}`), YouTube Music, Deezer or Apple Music links instead of Spotify, which players or users to show, and more.

## FAQ

**Is this really allowed by Discord?**
It uses Discord's official local Rich Presence connection, the same one games and apps like Spotify use, together with the official Discord app that you log in to yourself. It never reads, stores or sends your Discord token. The Proxmox setup simply runs that official app on your server instead of your desk. (We're not lawyers, and Discord can change its rules, but this is the method Discord built for exactly this purpose.)

**Nothing shows on my profile.**
Turn on **Settings → Activity Privacy → Share my activity** in Discord. Then check that your Navidrome app is actually reporting what's playing: the "now playing" icon at the top of the Navidrome web interface should show your song.

**My status disappears after I pause and resume, or appears only when a new song starts.**
That depends on your music app. Some apps tell Navidrome only once per song. Apps that support the newer OpenSubsonic "playback report" keep pause, resume and seeking accurate.

**With the Proxmox setup I always appear online.**
Yes. The container runs a real Discord session, so Discord sees you as online, or idle when you're away. You can set your status to Idle or Do Not Disturb as usual.

**Discord emailed me about a new login from Linux.**
That's the Proxmox container logging in. It's expected.

**The album cover is wrong or missing.**
Turn on "use your Navidrome covers" by re-running the installer with `RECONFIGURE=1` in front of the command, or set `sources = upload, caa, deezer, itunes` in the settings. If a cover can't be found, the Navidrome logo is shown.

**Do I need to open ports on my router?** No.

## Privacy

- Your **Navidrome password** stays on your machine or server, in a settings file only that user can read. It's sent only to your Navidrome server, as a salted hash (standard Subsonic login).
- **Album covers:** if you choose "use your Navidrome covers", the cover image of what you're playing is uploaded to [uguu.se](https://uguu.se), a temporary host that deletes files after 3 hours, because Discord needs a public link to show it. Otherwise only the artist and album **names** are sent to Deezer/iTunes to look up a cover.
- **Spotify links:** the artist, song and album names are sent to ListenBrainz to find the matching track.
- Nothing listens on your network, except the Discord login page on Proxmox, which needs a password and switches itself off after 30 minutes.

## For developers

- `navidrome_presence.py` is the whole companion: a single file with only the Python standard library (3.7+).
- `python3 -m unittest discover -s tests -v` runs the tests, using a fake Discord socket and a fake Navidrome server.
- `proxmox/setup-proxmox.sh` is generated: edit `proxmox/setup-proxmox.template.sh`, then run `bash proxmox/build.sh`. CI checks that the committed file is up to date.
- Useful flags: `--setup` (the questions), `--check`, `--dry-run`, `--once`, `-v`.

Pull requests are welcome.

## Credits

- Inspired by the [Navidrome Discord Rich Presence plugin](https://github.com/navidrome/discord-rich-presence-plugin) (GPL-3.0) and [Navicord](https://github.com/logixism/navicord). The pause badge (`assets/pause.png`) comes from the plugin.
- The Navidrome logo belongs to the [Navidrome](https://github.com/navidrome/navidrome) project.
- Not affiliated with Navidrome or Discord.

## License

[GPL-3.0](LICENSE). You can use, change and share this freely. If you share a modified version, it must stay open source under the same license.
