# Typing Stats

A macOS menu bar app that tracks your daily keystroke statistics across devices via iCloud.

## Install

```bash
brew tap rauchg/typing-stats https://github.com/rauchg/typing-stats
brew install --cask rauchg/typing-stats/typing-stats
```

## Features

- Live keystroke counter in menu bar
- Counts dictated text from dictation apps (Aqua Voice, Willow, …), labeled so History can filter All / Typed / Dictated
- Typing and speaking WPM
- Daily, weekly, and monthly statistics
- Multi-device sync via iCloud
- History view with charts
- Start at login option
- Automatic update checking

## Permissions

The app requires Accessibility permission to count keystrokes. You'll be prompted on first launch, or grant it manually in:

**System Settings → Privacy & Security → Accessibility**

## Contributors

- [Ghoshan Jaganathamani](https://github.com/ghostyfreak) — Better analytics

## Uninstall

```bash
brew uninstall typing-stats
```
