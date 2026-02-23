# Debug Session Context - Claude Input Watcher

## Issue
Extension doesn't run the resume script after submitting answers from AskUserQuestion.
Execution stops at "configuration loaded" - no terminal events are being logged.

## Root Cause Identified
The `onDidWriteTerminalData` VS Code API doesn't work in Cursor/Antigravity (non-standard VS Code fork).

## Solution Implemented
Instead of relying on the VS Code extension to detect terminal output, we now use **Claude Code hooks directly**.

### Hook Configuration Added (2026-01-31)

Added `PostToolUse` hook for `AskUserQuestion` in `~/.claude/settings.json`:

```json
"PostToolUse": [
  {
    "matcher": "AskUserQuestion",
    "hooks": [
      {
        "type": "command",
        "command": "powershell -ExecutionPolicy Bypass -Command \"Add-Content -Path 'C:\\Users\\Jethro\\Scripts\\claude-input-watcher\\scripts\\hook-debug.log' -Value \\\"PostToolUse:AskUserQuestion fired at $(Get-Date)\\\"; & 'C:\\Users\\Jethro\\Scripts\\claude-input-watcher\\scripts\\resume.ps1'\"",
        "async": true
      }
    ]
  }
]
```

### Complete Hook Flow

| Event | Hook | Script | Action |
|-------|------|--------|--------|
| Claude asks question | `PreToolUse:AskUserQuestion` | `pause-and-focus.ps1` | Pause media, focus window |
| User answers question | `PostToolUse:AskUserQuestion` | `resume.ps1` | Resume media |
| User submits new prompt | `UserPromptSubmit` | `resume.ps1` | Resume media |
| Claude finishes responding | `Stop` | `pause-and-focus.ps1` | Pause for next prompt |

## Next Steps

1. **Restart Claude Code** to load the new hook configuration
2. **Test** by having Claude ask a question (trigger AskUserQuestion)
3. **Verify** by checking `hook-debug.log` for `PostToolUse:AskUserQuestion fired at...`

## Files Modified

- `~/.claude/settings.json` - Added PostToolUse hook for AskUserQuestion
- `extension/src/extension.ts` - Added flag file sync for enable/disable toggle
- `scripts/pause-and-focus.ps1` - Added flag file check at start
- `scripts/resume.ps1` - Added flag file check at start

## Unified Toggle System (2026-01-31)

Added a shared flag file mechanism so the VS Code extension toggle controls both the extension AND the Claude hooks:

**Flag File:** `~/.claude-watcher-enabled`
- Contains `true` or `false`
- Written by extension when toggled
- Read by PowerShell scripts before executing

**Flow:**
1. User toggles Claude Watcher in VS Code
2. Extension writes `true`/`false` to `~/.claude-watcher-enabled`
3. When hooks fire, scripts check this file
4. If `false`, scripts exit immediately without doing anything

## VS Code Extension Status

The extension (`extension/`) is still functional but may not be needed anymore since hooks handle the core functionality. The extension could be:
- Kept as a fallback/status indicator
- Removed entirely if hooks work reliably
- Simplified to just show status in the status bar

## Debug Log Location

`C:\Users\Jethro\Scripts\claude-input-watcher\scripts\hook-debug.log`
