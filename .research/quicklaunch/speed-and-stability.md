# Speed and stability

Measured on the author's machine on 2026-10-16: 4 sources, 209 entries, pwsh 7.

| Step | Time |
| --- | --- |
| folder signature check, on every popup open | 24 ms |
| list for the empty query, on every popup open | 57 ms |
| one keystroke, 1 letter / 4 letters | 41 ms / 10 ms |
| full rebuild of the entry list | 238 ms |
| C# helper compile, on every app start | 240-410 ms |

## 1. Keyboard hook on its own thread (stability, highest value)

What: the low-level keyboard hook behind Win+R runs on a dedicated thread with its own
message loop, not on the PowerShell UI thread.

Why: every key pressed anywhere in Windows passes through the hook, so it waits for
the UI thread. Windows silently removes a hook that does not answer within
LowLevelHooksTimeout (about 1 s) and does not tell the app. Any time the UI thread is busy for
a second, Win+R stops working until a restart. This can happen while a slow shortcut starts,
during a rebuild on a slow drive, or during a garbage collection pause. Input in every other
app also lags while the UI thread works. Win+R is the default hotkey, so this hits every user.

## 2. Popup first, work after (speed)

What: the popup appears at once with the list it had last time. The folder check and the
refreshed list follow right after it is visible.

Why: today about 80 ms of work run before the window is shown, more with a slow or
network source. A watcher on the source folders, or a check after showing, makes the
open feel instant. The list for the empty query only changes after a launch or a folder
change, so it can also be kept ready.

## 3. Global error handler (stability)

What: an exception that escapes any event handler is written to the log and the app keeps
running.

Why: there is no handler today. An unexpected error in a handler shows the WinForms
"Unhandled exception" dialog, or ends the tray app. Several handlers already carry their
own try/catch for this reason.

## 4. Cancelled UAC prompt is not asked twice (correctness)

What: when the user cancels the UAC prompt of an elevated shortcut, nothing else happens.

Why: today the cancel counts as a failure and the entry is retried through Explorer, so
the same UAC prompt appears a second time. The log shows this for "Dev1" and "BlockSleep".

## 5. Faster app start (speed, low priority)

What: the compiled C# helper is cached in the data folder and loaded from there while
its source is unchanged.

Why: the compile costs 240-410 ms on every start. The app starts once per logon, so this
matters less than the popup. The logon task also waits 15 s before starting. In that time
Win+R opens the old Run box.

## 6. Row painting without leaks (stability, low priority)

What: the fonts and brushes used to paint rows are created once per layout, not per row.

Why: every repaint creates new GDI+ objects and never frees them. They are released only
by the garbage collector. In a tray app that runs for weeks, this is needless memory and
handle churn.

## Done in this audit

Settings and usage files are written to a temporary file first and then swapped in. A crash
or power loss during a save no longer leaves a broken file. A broken usage file would reset
every learned ranking.
