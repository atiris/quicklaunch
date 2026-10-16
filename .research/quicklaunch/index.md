# QuickLaunch - proposals

Audit from 2026-10-16. Priorities, as the user set them: 1. how fast the popup opens, 2. stability,
3. the features users of launchers ask for most often.

| Priority | Proposal | Effort |
| --- | --- | --- |
| 1 | [Speed and stability](speed-and-stability.md) - hook on its own thread, popup shown before the work, error handler, faster start | small to medium |
| 2 | [System commands](system-commands.md) - lock, sleep, restart, shut down, Windows settings pages | small |
| 3 | [Entry actions](entry-actions.md) - run as administrator, open the containing folder, copy the path | small |
| 4 | [Web search keywords](web-search-keywords.md) - `g text`, `yt text`, `wiki text` | small |
| 5 | [Window switcher](window-switcher.md) - type to jump to an open window | medium |
| 6 | [Unit conversion](unit-conversion.md) - `10 km in mi` in the calculator | medium |

Left out on purpose: clipboard history (a separate tool, needs a clipboard listener and a store),
settings export (the config is already one JSON file), start with Windows (already there),
rebindable hotkey (already there).

## Sources

The list of requested features comes from the issue trackers and docs of Flow Launcher,
PowerToys Run / Command Palette, Wox and Keypirinha. The most common complaints are hotkey
conflicts and slow results:

- https://www.flowlauncher.com/plugins
- https://github.com/Flow-Launcher/Flow.Launcher/issues/4136
- https://www.thewindowsclub.com/powertoys-not-working-in-windows
- https://www.neowin.net/news/microsoft-powertoys-0572-fixes-fancyzones-rounded-corners-always-on-top-lost-focus-and-more/
- https://alternativeto.net/software/keypirinha
