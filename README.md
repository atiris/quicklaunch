# QuickLaunch

A tray launcher for Windows, written as a single PowerShell 7 script. It puts a small
black square in the notification area; a click on it - or a global hotkey - opens a
search popup listing everything found in the configured folders. Typing filters the
list, Enter starts the selected entry.

There is no installer and no build step: the script is the program.

## Requirements

- Windows 10 / 11
- PowerShell 7 (`pwsh.exe`) - `start.bat` offers to install it when it is missing

Windows PowerShell 5.1 cannot even parse `quicklaunch.ps1`, so it is always started
through one of the launchers below.

## Start

| Way | What it does |
| --- | --- |
| `start.bat` | double-click; checks for PowerShell 7, installs it if you agree, then starts hidden |
| `quicklaunch.vbs` | starts with no console window at all (used by the logon task) |
| `quicklaunch-run.ps1` | "Run with PowerShell" from Explorer; re-launches the real script under `pwsh` |
| `pwsh -File quicklaunch.ps1` | direct start |

Only one instance runs at a time (a global mutex); starting it again just exits.

On the very first start the settings window opens by itself, because nothing is
configured yet.

### Start at logon

```powershell
pwsh -File .\quicklaunch.ps1 -Install     # register the "QuickLaunch" logon task
pwsh -File .\quicklaunch.ps1 -Uninstall   # remove it
```

The task runs `wscript.exe quicklaunch.vbs` 15 seconds after logon, so nothing flashes
up. The same switch is available as a checkbox in the settings window.

Other parameters: `-ShowConsole` keeps the console visible for debugging.

## Using the popup

- **hotkey** - default `Ctrl+Alt+R`, opens and closes the popup
- **typing** - filters the list; several words all have to match
- **Up / Down** - move the selection, **Enter** - run it (the first entry when nothing was moved)
- **Shift+Enter** - run the selected entry *with parameters*: the search box turns into an
  argument box, pre-filled with the arguments used last time for that entry
- **Escape** - hide the popup (also hides itself when it loses focus)

Subdirectories of a source become groups. The script's own commands (open source folder,
settings, reload, exit) sit at the bottom of the list and are searchable like any other
entry.

### Prefixes

| Typed | Result |
| --- | --- |
| `run <cmd>`, `!<cmd>` | hands the text to the shell, exactly like the Win+R box |
| `web <url>`, `//<url>` | opens the text as a URL (`//google.com` -> `https://google.com`) |
| `dir <text>`, `cd <text>`, `..<text>` | searches folders instead of entries, opens the chosen one in Explorer |
| `=<expression>` | calculator, e.g. `=(2+3)*4`; Enter copies the result to the clipboard |
| `<letter> <text>` | limits the list to the source owning that shortcut letter |

Run and web entries are remembered and offered again the next time. The calculator knows
`+ - * / % ^`, brackets, `pi`, `e` and `sqrt`, `abs`, `round`, `floor`, `ceiling`,
`truncate`, `sign`, `min`, `max`, `pow`, `log`, `log10`, `exp`, `sin`, `cos`, `tan`.

Each of the four prefixes can be turned off in the settings.

### Alternative names

Extra names live in the file name, in a trailing bracket group:

```
pwsh [powershell, ps].lnk
```

The entry is shown as `pwsh` and is found by `powershell` and `ps` as well.

### Ranking

Every launch is recorded: how often an entry was started **and** which search text was
typed to reach it. Both feed the ranking, so the entry you usually start by typing `cc`
ends up first the next time you type `cc`.

## Tray menu

Right-clicking the tray icon opens *Open launcher*, *Open settings*, *Reload settings and
lists* and *Exit launcher*.

Set a **Custom menu folder** in the settings and that folder is put on top of the menu:

- subfolders become submenus, as deep as the folder tree goes
- files matching the global include and exclude filters become entries; clicking one
  starts it just like the popup does (and it counts towards the ranking)
- `[1]` anywhere in a folder or file name sets the order: numbered names come first in
  that order, everything else follows alphabetically
- alternative names in brackets are stripped from what is shown, same as in the popup

With `D:\start` as the menu folder:

```
D:\start\                          HeyPay        >
  HeyPay\                          Personalspace >
  Personalspace\                   System        >
  System\                 ->       Windows       >
  Windows\                         Workspace     >  ->  Terminal inkaska
  Workspace\                       -----------------
    Terminal inkaska.lnk           Open launcher
                                   ...
```

The menu is rebuilt every time it is opened, so changes in the folder show up at once.

## Settings

Everything is edited in the built-in settings window - tray menu *Open settings*, the gear
at the bottom right of the popup, or the *Settings* entry in the list. It covers sources,
hotkey, sizes, colours, the custom menu folder and the `dir` folder list; a button adds the
Start Menu folders as sources.

The popup draws its own scrollbar, so its track (`scrollBack`) and thumb (`scrollBar`) are
ordinary colours in the settings like every other one.

### Sources

A source is a folder plus an include filter (`*.lnk;*.exe`), an exclude filter
(`*protect*.*`) and an optional shortcut letter. A source without its own filters uses the
global ones. With more than one source the source name is shown in front of the group.

### Hotkey

The hotkey is put together from the Ctrl/Alt/Shift/Win checkboxes and a key list. The
settings window asks Windows straight away whether the combination is still free, so a
combination another program holds is spotted before saving.

Windows keeps a few combinations for itself (Win+R, Win+S, ...) and never hands them to an
ordinary hotkey. With **Use a keyboard hook** ticked, QuickLaunch answers those first with
a low-level keyboard hook - the key is swallowed before Explorer sees it, so Win+R opens
this launcher instead of the Windows Run box. The hook is only installed when the chosen
combination cannot be registered the normal way.

### Config file

Nothing is ever written next to the script.

| | |
| --- | --- |
| Config | `%LOCALAPPDATA%\QuickLaunch\quicklaunch.config.json` (created on first run) |
| Usage | `%LOCALAPPDATA%\QuickLaunch\quicklaunch.usage.json` |
| Icons | `%LOCALAPPDATA%\QuickLaunch\cache\icons` |
| Log | `<parent of the script folder>\logs\quicklaunch.log` |

The config can also be edited by hand; *Reload settings and list* in the tray menu picks
the changes up.

```json
{
  "sources": [
    { "path": "D:\\start", "include": "", "exclude": "", "shortcut": "" }
  ],
  "menuDir": "",
  "hotkey": "Ctrl+Alt+R",
  "hookReserved": false,
  "runAtLogon": false,
  "width": 700,
  "rows": 14,
  "fontSize": 12,
  "showGroup": true,
  "showIcons": true,
  "includeNames": "*.lnk;*.exe;*.url",
  "excludeNames": "desktop.ini;thumbs.db",
  "offerDirs": true,
  "offerRun": true,
  "offerWeb": true,
  "offerCalc": true,
  "colors": {
    "background": "#202020",
    "text": "#F0F0F0",
    "dim": "#969696",
    "selection": "#005A9E",
    "selText": "#D2E1F0",
    "searchBack": "#2D2D2D",
    "scrollBack": "#202020",
    "scrollBar": "#5A5A5A"
  },
  "dirs": ["D:\\", "D:\\workspace", "D:\\workspace\\*"]
}
```

In `dirs` an entry is either a folder or a folder with a trailing `\*`, which means every
immediate subfolder of it.

## Files

| File | Purpose |
| --- | --- |
| `quicklaunch.ps1` | the whole program: tray icon, popup, settings window, hotkey, ranking |
| `quicklaunch-run.ps1` | edition guard - parses under 5.1, restarts the script under `pwsh` |
| `quicklaunch.vbs` | flash-free start (hidden window, does not wait) |
| `start.bat` | first-time start; finds or installs PowerShell 7 |

## Troubleshooting

- **Nothing happens on the hotkey** - another program holds the combination. A balloon tip
  says so at start; change it in the settings, or tick the keyboard hook.
- **The window only blinks** - the script was started by Windows PowerShell 5.1. Use
  `start.bat` or `quicklaunch-run.ps1`.
- **Entries are missing** - check the source's include/exclude filter; by default only
  `*.lnk`, `*.exe` and `*.url` are listed.
- **Icons stay blank for a moment** - they are extracted in the background into the cache
  and appear on the next repaint. Icons from network shares take the longest.
- Anything unexpected is written to the log file listed above.
