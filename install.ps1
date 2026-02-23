# install.ps1 - One-click installer for Claude Input Watcher
# Run this script to build and install the extension in Antigravity IDE

param(
    [switch]$SkipBuild,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
$extensionPath = Join-Path $scriptRoot "extension"
$vsixPattern = "claude-input-watcher-*.vsix"

Write-Host "=== Claude Input Watcher Installer ===" -ForegroundColor Cyan
Write-Host ""

# Check for Antigravity
$antigravityCmd = Get-Command "antigravity" -ErrorAction SilentlyContinue
if (-not $antigravityCmd) {
    Write-Host "ERROR: 'antigravity' command not found in PATH" -ForegroundColor Red
    Write-Host "Please ensure Antigravity IDE is installed and 'antigravity' is in your PATH"
    exit 1
}

Write-Host "Found Antigravity at: $($antigravityCmd.Source)" -ForegroundColor Green

# Handle uninstall
if ($Uninstall) {
    Write-Host ""
    Write-Host "Uninstalling Claude Input Watcher..." -ForegroundColor Yellow
    & antigravity --uninstall-extension jethro.claude-input-watcher 2>$null
    Write-Host "Uninstall complete" -ForegroundColor Green
    exit 0
}

# Check for npm
$npmCmd = Get-Command "npm" -ErrorAction SilentlyContinue
if (-not $npmCmd) {
    Write-Host "ERROR: 'npm' command not found in PATH" -ForegroundColor Red
    Write-Host "Please install Node.js from https://nodejs.org/"
    exit 1
}

# Navigate to extension directory
Push-Location $extensionPath

try {
    if (-not $SkipBuild) {
        # Install dependencies
        Write-Host ""
        Write-Host "Installing dependencies..." -ForegroundColor Yellow
        npm install
        if ($LASTEXITCODE -ne 0) {
            throw "npm install failed"
        }

        # Compile TypeScript
        Write-Host ""
        Write-Host "Compiling TypeScript..." -ForegroundColor Yellow
        npm run compile
        if ($LASTEXITCODE -ne 0) {
            throw "TypeScript compilation failed"
        }

        # Package extension
        Write-Host ""
        Write-Host "Packaging extension..." -ForegroundColor Yellow

        # Install vsce if not available
        $vsceCmd = Get-Command "vsce" -ErrorAction SilentlyContinue
        if (-not $vsceCmd) {
            Write-Host "Installing vsce globally..." -ForegroundColor Yellow
            npm install -g @vscode/vsce
        }

        # Remove old vsix files
        Remove-Item $vsixPattern -ErrorAction SilentlyContinue

        # Package
        npx vsce package --allow-missing-repository
        if ($LASTEXITCODE -ne 0) {
            throw "Extension packaging failed"
        }
    }

    # Find the vsix file
    $vsixFile = Get-ChildItem -Path $extensionPath -Filter $vsixPattern | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $vsixFile) {
        throw "No .vsix file found. Run without -SkipBuild to build the extension."
    }

    Write-Host ""
    Write-Host "Installing extension: $($vsixFile.Name)" -ForegroundColor Yellow

    # Install extension in Antigravity
    & antigravity --install-extension $vsixFile.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "Extension installation failed"
    }

    Write-Host ""
    Write-Host "=== Installation Complete! ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "The Claude Input Watcher extension has been installed in Antigravity."
    Write-Host ""
    Write-Host "Features:" -ForegroundColor Cyan
    Write-Host "  - Pauses media when Claude requires input"
    Write-Host "  - Brings Antigravity to foreground"
    Write-Host "  - Plays notification sound"
    Write-Host "  - Resumes media when you respond"
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Cyan
    Write-Host "  - Claude Watcher: Toggle    - Enable/disable the watcher"
    Write-Host "  - Claude Watcher: Test Pause - Test the pause functionality"
    Write-Host "  - Claude Watcher: Test Resume - Test the resume functionality"
    Write-Host ""
    Write-Host "Settings (File > Preferences > Settings > Claude Watcher):" -ForegroundColor Cyan
    Write-Host "  - claudeWatcher.enabled     - Enable/disable"
    Write-Host "  - claudeWatcher.pauseMedia  - Pause media playback"
    Write-Host "  - claudeWatcher.playSound   - Play notification sound"
    Write-Host "  - claudeWatcher.debounceMs  - Debounce time (ms)"
    Write-Host ""
    Write-Host "Please restart Antigravity IDE to activate the extension." -ForegroundColor Yellow

} finally {
    Pop-Location
}
