# Claude Input Watcher

An Antigravity IDE extension that pauses your media and brings the IDE to the foreground when Claude Code requires input.

## Features

When Claude asks a question or requires input:
1. **Pauses all media** (YouTube, Spotify, etc.) using Windows Media API
2. **Brings Antigravity to foreground** so you can respond
3. **Plays a notification sound** to get your attention
4. **Flashes taskbar** if focus change is blocked

When you respond:
1. **Resumes media playback** automatically
2. **Restores focus** to your previous window (game, browser, etc.)

When Claude finishes processing:
1. **Pauses media again** (ready for your next prompt)
2. **Brings Antigravity back** to the foreground

## Installation

### Prerequisites
- [Antigravity IDE](https://antigravity.dev) installed with `antigravity` in PATH
- [Node.js](https://nodejs.org/) installed with `npm` in PATH
- Windows 10/11 (uses Windows-specific APIs)

### One-Click Install

```powershell
# Navigate to the extension folder
cd \claude-input-watcher

# Run the installer
.\install.ps1
```

### Manual Install

```powershell
cd \claude-input-watcher\extension

# Install dependencies
npm install

# Compile TypeScript
npm run compile

# Package extension
npx vsce package --allow-missing-repository

# Install in Antigravity
antigravity --install-extension claude-input-watcher-1.0.0.vsix
```

## Usage

The extension activates automatically when Antigravity starts.

### Commands

Open Command Palette (`Ctrl+Shift+P`) and type:

| Command | Description |
|---------|-------------|
| `Claude Watcher: Toggle` | Enable/disable the watcher |
| `Claude Watcher: Enable` | Enable the watcher |
| `Claude Watcher: Disable` | Disable the watcher |
| `Claude Watcher: Test Pause` | Test pause & focus functionality |
| `Claude Watcher: Test Resume` | Test resume functionality |

### Status Bar

The status bar shows the current state:
- `$(eye) Claude: idle` - Waiting for Claude prompts
- `$(eye) Claude: waiting_input` - Claude is asking for input
- `$(eye) Claude: processing` - Claude is processing your response
- `$(eye-closed) Claude: OFF` - Watcher is disabled

Click the status bar item to toggle the watcher.

### Settings

Go to **File > Preferences > Settings** and search for "Claude Watcher":

| Setting | Default | Description |
|---------|---------|-------------|
| `claudeWatcher.enabled` | `true` | Enable/disable the watcher |
| `claudeWatcher.pauseMedia` | `true` | Pause media when input required |
| `claudeWatcher.playSound` | `true` | Play notification sound |
| `claudeWatcher.debounceMs` | `500` | Debounce time in ms |
| `claudeWatcher.scriptsPath` | `""` | Path to scripts folder (auto-detected) |

## How It Works

### State Machine

```
┌─────────────────────────────────────────┐
│              idle                       │
│  (watching for Claude prompts)          │
└──────────────┬──────────────────────────┘
               │ Question detected
               ▼
┌─────────────────────────────────────────┐
│         waiting_input                   │
│  (media paused, IDE focused)            │
│                                         │
│  Actions: pause-and-focus.ps1           │
└──────────────┬──────────────────────────┘
               │ User submits response
               ▼
┌─────────────────────────────────────────┐
│           processing                    │
│  (media resumed, Claude working)        │
│                                         │
│  Actions: resume.ps1                    │
└──────────────┬──────────────────────────┘
               │ Claude ready for next prompt
               ▼
┌─────────────────────────────────────────┐
│              idle                       │
│  (media paused again for next input)    │
│                                         │
│  Actions: pause-and-focus.ps1           │
└─────────────────────────────────────────┘
```

### Detection Patterns

The extension watches terminal output for these patterns:

**Input Required:**
- `? ` at line start (AskUserQuestion)
- `(y/n)` or `[Y/n]` confirmations
- `Permission required` prompts
- `Enter...:` input fields
- `Choose an option` selections

**Prompt Ready:**
- `> ` at line start (Claude ready for next command)

### PowerShell Scripts

Located in `scripts/`:

- **pause-and-focus.ps1**: Saves current window, pauses media, focuses Antigravity, plays sound
- **resume.ps1**: Resumes media, restores previous window focus
- **state.json**: Temporarily stores previous window handle (auto-cleaned)

## Troubleshooting

### Extension not activating
1. Restart Antigravity after installation
2. Check Output panel (View > Output > Claude Watcher)
3. Verify scripts path in settings

### Media not pausing
1. Check if browser supports Media Session API (Chrome, Edge, Firefox do)
2. Some players may not register with Windows media controls
3. Run `Claude Watcher: Test Pause` command to test manually

### Focus not restoring
1. Windows may block focus changes from background apps
2. Check if the previous window still exists
3. Games in exclusive fullscreen may not respond to focus changes

### Notification sound not playing
1. Check Windows sound settings
2. Verify system sounds are not muted
3. Sound uses Windows system "Asterisk" sound

## Uninstall

```powershell
# Using installer
.\install.ps1 -Uninstall

# Or manually
antigravity --uninstall-extension claude-input-watcher
```

## Development

```powershell
cd \claude-input-watcher\extension

# Watch mode for development
npm run watch

# In another terminal, press F5 in Antigravity to launch Extension Development Host
```

## Limitations

- **Windows only**: Uses Windows-specific APIs (user32.dll, Windows.Media.Control)
- **Antigravity only**: Extension is specific to Antigravity IDE (VS Code fork)
- **Games**: No universal pause API - relies on games auto-pausing on focus loss
- **Fullscreen apps**: Some fullscreen apps may block focus changes

## License

MIT
