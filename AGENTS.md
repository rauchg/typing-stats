- This is a macOS program for counting how many keystrokes I make per day.

## Repo specs
- Written in Swift using SwiftUI for the user interface.
- No xcode garbage. I want to build from CLI
- **Build:**
  - `./build.sh` - dev build (yellow keyboard icon, "-dev" version suffix)
  - `./build.sh --release` - production build
- **Test auto-update:** `./test-update.sh` builds a release-named copy labeled one version below the latest tag and launches it with an overdue update check. It should silently download the latest release and show "Restart to Update (vX)" in the menu. Quit the installed app first. A dev build can't be used: Sparkle looks for an app with the host's name ("Typing Stats (Dev).app") in the update zip and rejects it.
- **Build, deploy, and restart:**
  ```
  ./build.sh && cp -r "Typing Stats.app" /Applications/ && killall "Typing Stats" 2>/dev/null; open "/Applications/Typing Stats.app"
  ```

## Product specs
- It should show the number of keystrokes in the menubar.
- It should aggregate in "k"s if it's over 1k.
- I want it to sit in my menubar. No dock. Simple menu to quit and Start at login.
- When it's first launched it should try to register itself as login
- It should persist the keystroke count between launches and across devices, including with reconciling after offline periods, summing counts from multiple devices.
- There's a keyboard icon left of the count using this: https://www.svgrepo.com/svg/507754/keyboard
- If it doesn't have the right accessibility permission, it should render a warning icon next to the count and the irst item in the menu should be a CTA to open system preferences to the right place. The warning icon replaces the keyboard icon
- We want to very soundly and reliably reconcile across devices. It should handle race conditions like a new device coming online and thinking there's no state yet and starting a brand new file in iCloud
- We want to keep daily counts for at least 30 days, so we can show a history later. In the menubar we only show today's count, but when you open it in a section of the menu we should render:
    - Today's count
    - Yesterday's count
    - Average over the last 7 days
    - Average over the last 30 days
    - Record day count and date in mm/dd format
    - A link to open a more detailed history view
- When the menu is open from the menubar, remove the compression, show full number
- Sync every 5 minutes, and make sure to sync on app launch and app quit
- Render 2 decimal points in the menu
- In menubar, make the width the 'widest digit' times the number of digits (plus consideration for the dot), to avoid jumping when the number increases in digits
- When I hold the option key and the menu is open, render a special debug section that shows last sync, and a button to 'reset today'
- View History dialog should show a scrollable list of dates and counts. And a chart at the top with a dropdown for the number of days
- In the view history dialog, give me a button to open the iCloud Drive folder where the data is stored
- Track which apps keystrokes are made in. Show per-app breakdown in the History view with color-coded stacked bars
- Show top 5 apps individually, group the rest as "Others". Calculate top 5 based on the selected time period (7/30/60 days)
- Horizontal legend below the chart shows app colors. Legend items act as toggles to filter apps from the stats
- History view auto-refreshes every 5 minutes (matching menu bar sync) and on window focus
- Count text inserted by dictation apps (Aqua Voice, Willow, Wispr Flow, …). They paste via the clipboard plus a synthetic Cmd+V: detect it in the event tap (source PID ≠ 0, owning app on the allowlist in `DictationSources`), count the clipboard text's characters, and never store the text. Dictated characters are included in the total and also labeled (`dictatedCount`, `dictatedAppCounts`) so the History view can filter All / Typed / Dictated. Other synthetic keys from dictation apps are ignored.
- Show typing and speaking WPM (5 chars = 1 word). Typing time = gaps ≤ 2s between hardware keystrokes. Speaking time = how long the dictation app's process held the mic open (CoreAudio per-process input, macOS 14.2+), paired with the paste that follows. Utterances that can't be timed still count as dictated but are excluded from speaking WPM.
- Apple's built-in Dictation inserts text without key events or the clipboard, so it isn't counted.
- Coding agent stats (`AgentStats.swift`): read-only parsing of local logs from Claude Code (`~/.claude/projects`), Codex (`~/.codex/sessions`), opencode (`~/.local/share/opencode/opencode.db`) and fx (`~/.fx/sessions/v2`). Per device, day and agent: tokens (input/output/cache), characters and lines written through edit tools, prompts and prompt characters, tool calls, active time, characters written per project, and cost where the agent records it (opencode). Only counts, never prompt or code text. Edits made through shell commands can't be seen. fx input tokens are estimates in its logs, so they're skipped.
- Agent stats are rebuilt from the logs on each scan (launch and every 5 minutes, then sync), never incremented. They're stored in `DeviceData.agentDays`, separate from keystroke counts, and merged field-wise by max, so a smaller recount after an agent deletes old logs can't erase recorded days. They're also kept locally. Device entries with the same `agentSourceID` (hashed hardware UUID + user) read the same logs, so they're merged instead of summed, e.g. dev and release builds on one Mac.
- Menu shows an Agents section (today's chars written with a per-agent submenu, leverage = chars written / prompt chars, lines, active time, tokens, 7-day average). The History view's Agents filter charts agent-written characters stacked by project. A "Show Agent Stats" menu toggle (on by default) hides both and stops reading agent logs; days already synced are kept.
- Updates: Sparkle downloads silently. Once an update is staged, the menu shows "Restart to Update (vX)", and clicking it installs and relaunches immediately with no Sparkle dialog (`willInstallUpdateOnQuit` + `immediateInstallationBlock`). Ignored updates install on the next quit.