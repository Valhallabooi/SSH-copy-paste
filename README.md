# clipboard-ssh-setup

Copy file contents from a remote Linux server directly to your local clipboard over SSH — type `copy file.txt` on the remote and paste immediately on your local machine.

Uses **OSC 52** as the primary method (terminal escape sequence, zero overhead) with a **socat tunnel on port 2224** as fallback for terminals that don't support it.

---

## Requirements

| Side   | Requirement                          |
|--------|--------------------------------------|
| Remote | bash or zsh, socat (auto-installed)  |
| Local  | A modern terminal (see table below)  |

---

## Installation

Run the same script on **both** machines — it asks you what to set up:

```bash
chmod +x clipboard-ssh-setup.sh
./clipboard-ssh-setup.sh
```

You'll be prompted for:
1. **Local or remote?** — run on the remote server first, then on each local machine
2. **OS** — macOS / Ubuntu / Arch / WSL2 / Windows native

---

## Usage (on the remote server)

```bash
# Copy a file
copy file.txt

# Pipe into copy
cat file.txt | copy
echo "some text" | copy
```

---

## Terminal compatibility

| Terminal              | OS             | Method        | Extra setup needed?                              |
|-----------------------|----------------|---------------|--------------------------------------------------|
| iTerm2                | macOS          | OSC 52        | Enable "Allow clipboard access" in Preferences   |
| WezTerm               | macOS / Linux  | OSC 52        | Nothing                                          |
| Windows Terminal      | Windows 11     | OSC 52        | Nothing                                          |
| kitty / Alacritty     | Linux          | OSC 52        | Nothing                                          |
| GNOME Terminal        | Ubuntu         | Tunnel        | Script sets up socat listener automatically      |
| Terminal.app          | macOS          | Tunnel        | Script installs a LaunchAgent for the listener   |
| WSL2 (any terminal)   | Windows        | Tunnel        | Script uses `clip.exe` as the clipboard sink     |
| PuTTY / older clients | Windows        | Tunnel        | See Windows native instructions in script output |

---

## How it works

### OSC 52
A terminal escape sequence (`\033]52;c;<base64 data>\a`) that instructs the terminal emulator to write directly to the system clipboard. Works transparently over SSH with no ports or daemons.

### Tunnel fallback (port 2224)
If OSC 52 is unavailable, the `copy` function checks whether port 2224 is reachable locally (via `RemoteForward` in `~/.ssh/config`) and pipes the content through socat to a clipboard listener running on your local machine.

Both methods are attempted silently on every `copy` call — whichever works wins.

---

## What the script configures

### Remote
- Adds a `copy()` function to `~/.bashrc` / `~/.zshrc`
- Installs `socat` if missing

### Local (macOS)
- Adds `SetEnv TERM=xterm-256color` to `~/.ssh/config`
- Optionally installs a LaunchAgent (persistent tunnel listener via `pbcopy`)
- Optionally adds `RemoteForward 2224 localhost:2224` for a specific host

### Local (Ubuntu / Arch)
- Installs `socat` + `xclip` / `wl-clipboard`
- Adds an `ssh-clipboard-listen` function to your rc file that auto-starts on shell login
- Adds SSH config entries

### Local (WSL2)
- Installs `socat`, routes tunnel through `clip.exe`
- Adds auto-start listener to rc file

### Local (Windows native)
- Prints a ready-to-paste PowerShell block for the listener and SSH config

---

## Persistence

| Platform | Method                          |
|----------|---------------------------------|
| macOS    | LaunchAgent (loads at login)    |
| Linux    | rc file function (loads on shell start) |
| WSL2     | rc file function (loads on shell start) |
| Windows  | Add the PowerShell block to `$PROFILE` for persistence |

---

## Troubleshooting

**`copy` command not found after setup**
```bash
source ~/.bashrc  # or ~/.zshrc
```

**OSC 52 does nothing**
Your terminal doesn't support it. Run the script again on your local machine and opt into the tunnel fallback.

**Tunnel fallback not working**
Make sure `RemoteForward 2224 localhost:2224` is in your local `~/.ssh/config` for the relevant host, and that the local listener is running (`ssh-clipboard-listen` on Linux, LaunchAgent on macOS).

**Port 2224 already in use**
Edit the port number in both the remote `copy()` function and your local listener/SSH config — they just need to match.