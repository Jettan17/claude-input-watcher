import * as vscode from 'vscode';
import { exec, ExecException } from 'child_process';
import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';

type WatcherState = 'idle' | 'waiting_input' | 'processing';

// Interface for terminal data write event (VS Code 1.93+)
interface TerminalDataWriteEvent {
    readonly terminal: vscode.Terminal;
    readonly data: string;
}

// Patterns that indicate Claude is asking for input
const INPUT_REQUIRED_PATTERNS = [
    /^\? /m,                           // Question prompts (AskUserQuestion)
    /\(y\/n\)/i,                       // Yes/no confirmations
    /\(Y\/n\)/,                        // Case-sensitive yes/no
    /\[y\/N\]/i,                       // Bracketed confirmations
    /Permission required/i,            // Permission prompts
    /Waiting for.*input/i,             // Input waiting states
    /Press Enter/i,                    // Enter prompts
    /Choose an option/i,               // Selection prompts
    /Select.*:/i,                      // Selection prompts
    /Enter.*:/i,                       // Input field prompts
    /\? .*\[.*\]/,                     // Question with options
    /Would you like to/i,              // Confirmation questions
    /Do you want to/i,                 // Confirmation questions
    /Please confirm/i,                 // Confirmation requests
    /\(press enter to continue\)/i,    // Continue prompts
];

// Pattern that indicates Claude is ready for the next prompt
const PROMPT_READY_PATTERN = /^>\s*$/m;

// Patterns that indicate an AskUserQuestion answer was submitted
// These detect terminal clearing/rewriting and answer echoing
const ANSWER_SUBMITTED_PATTERNS = [
    /\x1b\[2K/,                    // ANSI: Clear entire line (question UI cleared)
    /\x1b\[\d*A/,                  // ANSI: Cursor up (redrawing after selection)
    /\x1b\[\d*J/,                  // ANSI: Clear screen/below (UI cleanup)
    /✓/,                           // Checkmark (selection confirmed)
    /›/,                           // Right chevron (selection indicator)
    /^[A-Z][a-z].*\(Recommended\)/m, // Selected recommended option echoed
];

// Pattern that indicates Claude is processing (spinner/output)
const PROCESSING_INDICATORS = [
    // Braille dot spinners (Claude Code uses these)
    /[\u2800-\u28FF]/,  // Any Braille pattern character (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ etc)
    // Standard spinners
    /\u25CF/,      // ● Bullet (spinner)
    /\u2022/,      // • Bullet point
    /\u00B7/,      // · Middle dot
    /\u2026/,      // … Ellipsis
    /\.{3,}/,      // Three or more dots
    // Status text
    /Thinking/i,
    /Processing/i,
    /Working/i,
    // Claude Code specific patterns
    /Reading/i,
    /Writing/i,
    /Running/i,
    /Searching/i,
    /Editing/i,
];

let state: WatcherState = 'idle';
let enabled = true;
let statusBarItem: vscode.StatusBarItem;
let lastTriggerTime = 0;
let outputChannel: vscode.OutputChannel;
let terminalDataListener: vscode.Disposable | undefined;

// Flag file path for hooks to check
const FLAG_FILE_PATH = path.join(os.homedir(), '.claude-watcher-enabled');

function writeEnabledFlag(isEnabled: boolean) {
    try {
        fs.writeFileSync(FLAG_FILE_PATH, isEnabled ? 'true' : 'false', 'utf8');
        log(`Wrote enabled flag: ${isEnabled} to ${FLAG_FILE_PATH}`);
    } catch (error) {
        log(`Error writing enabled flag: ${error}`);
    }
}

function readEnabledFlag(): boolean {
    try {
        if (fs.existsSync(FLAG_FILE_PATH)) {
            const content = fs.readFileSync(FLAG_FILE_PATH, 'utf8').trim();
            return content === 'true';
        }
    } catch (error) {
        log(`Error reading enabled flag: ${error}`);
    }
    return true; // Default to enabled if file doesn't exist
}

export function activate(context: vscode.ExtensionContext) {
    outputChannel = vscode.window.createOutputChannel('Claude Watcher');
    log('Extension activating...');

    // Create status bar item
    statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    statusBarItem.command = 'claudeWatcher.toggle';
    context.subscriptions.push(statusBarItem);

    // Load initial configuration
    loadConfiguration();

    // Register commands
    context.subscriptions.push(
        vscode.commands.registerCommand('claudeWatcher.enable', async () => {
            enabled = true;
            const config = vscode.workspace.getConfiguration('claudeWatcher');
            await config.update('enabled', true, vscode.ConfigurationTarget.Global);
            writeEnabledFlag(true);
            updateStatusBar();
            vscode.window.showInformationMessage('Claude Watcher enabled');
            log('Enabled by command');
        }),
        vscode.commands.registerCommand('claudeWatcher.disable', async () => {
            enabled = false;
            const config = vscode.workspace.getConfiguration('claudeWatcher');
            await config.update('enabled', false, vscode.ConfigurationTarget.Global);
            writeEnabledFlag(false);
            updateStatusBar();
            vscode.window.showInformationMessage('Claude Watcher disabled');
            log('Disabled by command');
        }),
        vscode.commands.registerCommand('claudeWatcher.toggle', async () => {
            enabled = !enabled;
            // Persist to VS Code settings so it survives reloads
            const config = vscode.workspace.getConfiguration('claudeWatcher');
            await config.update('enabled', enabled, vscode.ConfigurationTarget.Global);
            writeEnabledFlag(enabled);
            updateStatusBar();
            vscode.window.showInformationMessage(`Claude Watcher ${enabled ? 'enabled' : 'disabled'}`);
            log(`Toggled: ${enabled ? 'enabled' : 'disabled'}`);
        }),
        vscode.commands.registerCommand('claudeWatcher.testPause', () => {
            log('Testing pause-and-focus...');
            executePauseAndFocus();
        }),
        vscode.commands.registerCommand('claudeWatcher.testResume', () => {
            log('Testing resume...');
            executeResume();
        }),
        vscode.commands.registerCommand('claudeWatcher.showLogs', () => {
            outputChannel.show(true);
            log('Output channel opened');
        }),
        vscode.commands.registerCommand('claudeWatcher.debugState', () => {
            log(`=== DEBUG STATE ===`);
            log(`Current state: ${state}`);
            log(`Enabled: ${enabled}`);
            log(`Last trigger time: ${lastTriggerTime} (${Date.now() - lastTriggerTime}ms ago)`);
            log(`Terminal listener active: ${terminalDataListener !== undefined}`);
            log(`===================`);
            outputChannel.show(true);
        })
    );

    // Listen for configuration changes
    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration(e => {
            if (e.affectsConfiguration('claudeWatcher')) {
                loadConfiguration();
            }
        })
    );

    // Set up terminal data watcher
    setupTerminalWatcher(context);

    updateStatusBar();
    log('Extension activated successfully');
}

function setupTerminalWatcher(context: vscode.ExtensionContext) {
    // Clean up existing listener
    if (terminalDataListener) {
        terminalDataListener.dispose();
    }

    // Watch for terminal data using the VS Code API
    // Note: onDidWriteTerminalData is available in VS Code 1.93+
    // Cast to access the API which may not be in older type definitions
    const windowAny = vscode.window as any;
    log(`Checking for onDidWriteTerminalData API: ${typeof windowAny.onDidWriteTerminalData}`);

    if (typeof windowAny.onDidWriteTerminalData === 'function') {
        log('onDidWriteTerminalData API is available, setting up listener...');

        terminalDataListener = windowAny.onDidWriteTerminalData((event: TerminalDataWriteEvent) => {
            const terminalName = event.terminal?.name || 'unknown';

            // Always log that we received data (even before any checks)
            log(`[EVENT] Terminal "${terminalName}" data event fired (${event.data.length} chars)`);

            if (!enabled) {
                log('[EVENT] Skipping - watcher disabled');
                return;
            }

            const data = event.data;
            const config = vscode.workspace.getConfiguration('claudeWatcher');
            const debounceMs = config.get<number>('debounceMs', 500);

            // Check if we should process this event (debounce)
            const now = Date.now();
            const timeSinceLast = now - lastTriggerTime;

            // Log debounce check details
            log(`[EVENT] Debounce check: ${timeSinceLast}ms since last trigger (threshold: ${debounceMs}ms)`);

            if (timeSinceLast < debounceMs) {
                log(`[EVENT] Skipping - debounced`);
                return;
            }

            log(`[EVENT] Processing terminal data...`);
            processTerminalData(data, debounceMs);
        });

        if (terminalDataListener) {
            context.subscriptions.push(terminalDataListener);
        }
        log('Terminal watcher set up (using onDidWriteTerminalData)');
    } else {
        log('WARNING: onDidWriteTerminalData not available - terminal watching disabled');
        log('This API requires VS Code 1.93 or later');
    }
}

function processTerminalData(data: string, debounceMs: number) {
    const now = Date.now();

    // Debug: log all terminal data with hex representation for hidden chars
    const hexData = Buffer.from(data).toString('hex');
    log(`[PROCESS] Current state: ${state}`);
    log(`[PROCESS] Data (${data.length} chars): "${truncate(data, 100)}"`);
    log(`[PROCESS] Hex: ${hexData.substring(0, 100)}`);

    // Log pattern match results
    const inputMatch = matchesInputPattern(data);
    const processingMatch = matchesProcessingIndicator(data);
    const answerMatch = matchesAnswerSubmitted(data);
    log(`[MATCH] Input: ${inputMatch}, Processing: ${processingMatch}, Answer: ${answerMatch}`);

    switch (state) {
        case 'idle':
            // Check if Claude is asking for input
            if (matchesInputPattern(data)) {
                log(`State: idle -> waiting_input (matched input pattern in: "${truncate(data, 50)}")`);
                state = 'waiting_input';
                lastTriggerTime = now;
                executePauseAndFocus();
                updateStatusBar();
            }
            // Check if Claude started processing (user submitted a prompt)
            // Detect by looking for processing indicators in Claude's output
            else if (matchesProcessingIndicator(data)) {
                log(`State: idle -> processing (detected processing indicator: "${truncate(data, 50)}")`);
                state = 'processing';
                lastTriggerTime = now;
                executeResume();
                updateStatusBar();
            }
            break;

        case 'waiting_input':
            // Check if Claude started processing (user submitted a response)
            // Detect by looking for processing indicators in Claude's output
            if (matchesProcessingIndicator(data)) {
                log(`State: waiting_input -> processing (detected processing indicator: "${truncate(data, 50)}")`);
                state = 'processing';
                lastTriggerTime = now;
                executeResume();
                updateStatusBar();
            }
            // Check if an AskUserQuestion answer was submitted
            // (terminal clearing, checkmarks, or answer echoing)
            else if (matchesAnswerSubmitted(data)) {
                log(`State: waiting_input -> processing (detected answer submission: "${truncate(data, 50)}")`);
                state = 'processing';
                lastTriggerTime = now;
                executeResume();
                updateStatusBar();
            }
            // Also check if a different question appeared
            else if (matchesInputPattern(data)) {
                log(`State: waiting_input (new question: "${truncate(data, 50)}")`);
                lastTriggerTime = now;
                // Stay in waiting_input, but re-trigger pause in case focus was lost
                executePauseAndFocus();
            }
            break;

        case 'processing':
            // Check if Claude is ready for the next prompt
            if (PROMPT_READY_PATTERN.test(data)) {
                log(`State: processing -> idle (prompt ready)`);
                state = 'idle';
                lastTriggerTime = now;
                // Pause again - Claude is ready for next input
                executePauseAndFocus();
                updateStatusBar();
            } else if (matchesInputPattern(data)) {
                // Another question came up during processing
                log(`State: processing -> waiting_input (new question during processing)`);
                state = 'waiting_input';
                lastTriggerTime = now;
                executePauseAndFocus();
                updateStatusBar();
            }
            break;
    }
}

function matchesProcessingIndicator(data: string): boolean {
    return PROCESSING_INDICATORS.some(pattern => pattern.test(data));
}

function matchesInputPattern(data: string): boolean {
    return INPUT_REQUIRED_PATTERNS.some(pattern => pattern.test(data));
}

function matchesAnswerSubmitted(data: string): boolean {
    return ANSWER_SUBMITTED_PATTERNS.some(pattern => pattern.test(data));
}

function getScriptsPath(): string {
    const config = vscode.workspace.getConfiguration('claudeWatcher');
    let scriptsPath = config.get<string>('scriptsPath', '');

    if (!scriptsPath) {
        // Auto-detect based on extension location
        // The extension is in claude-input-watcher/extension/
        // Scripts are in claude-input-watcher/scripts/
        scriptsPath = path.resolve(__dirname, '..', '..', 'scripts');

        // Fallback to known location
        if (!scriptsPath.includes('claude-input-watcher')) {
            scriptsPath = 'C:\\Users\\Jethro\\Scripts\\claude-input-watcher\\scripts';
        }
    }

    return scriptsPath;
}

function executePauseAndFocus() {
    const config = vscode.workspace.getConfiguration('claudeWatcher');

    if (!config.get<boolean>('pauseMedia', true) && !config.get<boolean>('playSound', true)) {
        log('Both pauseMedia and playSound are disabled, skipping script');
        return;
    }

    const scriptsPath = getScriptsPath();
    const scriptFile = path.join(scriptsPath, 'pause-and-focus.ps1');

    log(`Executing: ${scriptFile}`);

    exec(
        `powershell -ExecutionPolicy Bypass -File "${scriptFile}"`,
        { windowsHide: true },
        (error: ExecException | null, stdout: string, stderr: string) => {
            if (error) {
                log(`Error executing pause-and-focus: ${error.message}`);
                if (stderr) {
                    log(`stderr: ${stderr}`);
                }
            } else if (stdout) {
                log(`pause-and-focus output: ${stdout.trim()}`);
            }
        }
    );
}

function executeResume() {
    const scriptsPath = getScriptsPath();
    const scriptFile = path.join(scriptsPath, 'resume.ps1');

    log(`Executing: ${scriptFile}`);

    exec(
        `powershell -ExecutionPolicy Bypass -File "${scriptFile}"`,
        { windowsHide: true },
        (error: ExecException | null, stdout: string, stderr: string) => {
            if (error) {
                log(`Error executing resume: ${error.message}`);
                if (stderr) {
                    log(`stderr: ${stderr}`);
                }
            } else if (stdout) {
                log(`resume output: ${stdout.trim()}`);
            }
        }
    );
}

function loadConfiguration() {
    const config = vscode.workspace.getConfiguration('claudeWatcher');
    enabled = config.get<boolean>('enabled', true);
    // Sync flag file with current state
    writeEnabledFlag(enabled);
    updateStatusBar();
    log(`Configuration loaded: enabled=${enabled}`);
}

function updateStatusBar() {
    if (enabled) {
        statusBarItem.text = `$(eye) Claude: ${state}`;
        statusBarItem.tooltip = `Claude Watcher: ${state}\nClick to toggle`;
        statusBarItem.backgroundColor = undefined;
    } else {
        statusBarItem.text = '$(eye-closed) Claude: OFF';
        statusBarItem.tooltip = 'Claude Watcher: Disabled\nClick to enable';
        statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
    }
    statusBarItem.show();
}

function log(message: string) {
    const timestamp = new Date().toISOString();
    outputChannel.appendLine(`[${timestamp}] ${message}`);
}

function truncate(str: string, maxLen: number): string {
    // Clean up control characters for logging
    const cleaned = str.replace(/[\r\n\t]/g, ' ').replace(/\s+/g, ' ').trim();
    if (cleaned.length <= maxLen) {
        return cleaned;
    }
    return cleaned.substring(0, maxLen) + '...';
}

export function deactivate() {
    if (terminalDataListener) {
        terminalDataListener.dispose();
    }
    log('Extension deactivated');
}
