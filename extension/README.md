# Claude Input Watcher Extension

VS Code extension for Antigravity IDE that monitors Claude Code terminal output and triggers media pause/focus when input is required.

## Development

```bash
# Install dependencies
npm install

# Compile
npm run compile

# Watch mode
npm run watch

# Package
npm run package
```

## Extension Points

### Commands
- `claudeWatcher.enable` - Enable the watcher
- `claudeWatcher.disable` - Disable the watcher
- `claudeWatcher.toggle` - Toggle watcher state
- `claudeWatcher.testPause` - Test pause & focus script
- `claudeWatcher.testResume` - Test resume script

### Settings
- `claudeWatcher.enabled` - Master enable/disable
- `claudeWatcher.pauseMedia` - Pause media on input
- `claudeWatcher.playSound` - Play notification sound
- `claudeWatcher.debounceMs` - Debounce time
- `claudeWatcher.scriptsPath` - Scripts folder path

## Architecture

The extension uses `vscode.window.onDidWriteTerminalData` to watch all terminal output.

State machine:
- `idle` - Watching for Claude prompts
- `waiting_input` - Claude asked a question, media paused
- `processing` - User responded, media resumed

## Output Channel

Debug logs available in Output panel: **Claude Watcher**
