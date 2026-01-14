- This is a macOS program for counting how many keystrokes I make per day.

## Repo specs
- Written in Swift using SwiftUI for the user interface.
- No xcode garbage. I want to build from CLI
- **Build:**
  - `./build.sh` - dev build (yellow keyboard icon, "-dev" version suffix)
  - `./build.sh --release` - production build
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