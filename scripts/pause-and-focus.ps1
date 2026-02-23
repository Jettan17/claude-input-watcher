# pause-and-focus.ps1 - Pause media, save state, focus & maximize Antigravity
# Called when Claude requires input (question prompts, confirmations, etc.)

param(
    [switch]$NoMaximize  # Skip maximizing the window
)

$ErrorActionPreference = "SilentlyContinue"

# Check if watcher is enabled via flag file
$flagFile = Join-Path $env:USERPROFILE ".claude-watcher-enabled"
if (Test-Path $flagFile) {
    $flagContent = Get-Content $flagFile -Raw
    if ($flagContent.Trim() -eq "false") {
        Write-Host "[Claude Watcher] Disabled - skipping pause-and-focus"
        exit 0
    }
}

$statePath = Join-Path $PSScriptRoot "state.json"

# Load Visual Basic assembly for AppActivate
Add-Type -AssemblyName Microsoft.VisualBasic

# Add Win32 API for window management
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

public class Win32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    // For simulating keystrokes
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    public const int SW_RESTORE = 9;
    public const int SW_SHOW = 5;
    public const int SW_MAXIMIZE = 3;
    public const int SW_MINIMIZE = 6;

    public const byte VK_MENU = 0x12;    // Alt key
    public const byte VK_TAB = 0x09;     // Tab key
    public const byte VK_ESCAPE = 0x1B;  // Escape key
    public const uint KEYEVENTF_KEYUP = 0x0002;

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_SHOWWINDOW = 0x0040;

    // Simulate Alt+Escape to cycle windows (less intrusive than Alt+Tab)
    public static void SendAltEscape() {
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        Thread.Sleep(10);
        keybd_event(VK_ESCAPE, 0, 0, UIntPtr.Zero);
        keybd_event(VK_ESCAPE, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
"@

# Get current foreground window
$currentWindow = [Win32]::GetForegroundWindow()
$currentProcessId = 0
[Win32]::GetWindowThreadProcessId($currentWindow, [ref]$currentProcessId) | Out-Null
$currentProcess = Get-Process -Id $currentProcessId -ErrorAction SilentlyContinue

# Check if current window is Antigravity - if so, find an alternative
$previousWindow = $currentWindow
$wasMaximized = [Win32]::IsZoomed($currentWindow)
$wasMinimized = [Win32]::IsIconic($currentWindow)
$alternativeFound = $false

if ($currentProcess -and $currentProcess.ProcessName -eq "Antigravity") {
    Write-Host "[Claude Watcher] Current window is Antigravity - finding alternative..."

    # Function to check if a process is likely a game
    function Test-IsGame {
        param([System.Diagnostics.Process]$proc)

        try {
            $path = $proc.Path
            if (-not $path) { return $false }

            # Check if running from game directories
            $gamePaths = @(
                "Steam\steamapps\common",
                "Epic Games",
                "GOG Galaxy\Games",
                "Riot Games",
                "Blizzard",
                "Origin Games",
                "Ubisoft Game Launcher",
                "Xbox Games",
                "EA Games",
                "Modrinth"
            )

            foreach ($gamePath in $gamePaths) {
                if ($path -match [regex]::Escape($gamePath)) {
                    return $true
                }
            }

            # Check file description/product name for game indicators
            $fileInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            $gameKeywords = @("game", "unity", "unreal", "godot", "cryengine")
            foreach ($keyword in $gameKeywords) {
                if ($fileInfo.FileDescription -match $keyword -or
                    $fileInfo.ProductName -match $keyword -or
                    $fileInfo.CompanyName -match $keyword) {
                    return $true
                }
            }
        } catch {
            # Ignore access errors
        }

        return $false
    }

    # Known game processes (your installed games + common ones)
    $gameProcesses = @(
        # Your Steam games
        "Celeste", "HollowKnight", "hollow_knight",
        "Inscryption", "NMS", "No Man's Sky",
        "OMORI", "OuterWilds", "portal", "portal2",
        "RainWorld", "Rain World", "Slay the Princess",
        "Talos", "TheWitness", "witness",
        # Minecraft (Modrinth/vanilla)
        "javaw", "java", "Minecraft",
        # Common launchers & games
        "steam", "steamwebhelper",
        "EpicGamesLauncher", "FortniteClient-Win64-Shipping",
        "RocketLeague", "csgo", "cs2",
        "valorant", "VALORANT-Win64-Shipping", "RiotClientServices",
        "GTA5", "RDR2", "Cyberpunk2077",
        "Overwatch", "Diablo IV", "WorldOfWarcraft", "Battle.net",
        "LeagueClient", "League of Legends",
        "destiny2", "Warframe.x64",
        "eldenring", "darksouls", "sekiro",
        "baldursgate3", "bg3",
        # Entertainment apps
        "Spotify", "Discord"
    )

    # Browser processes
    $browserProcesses = @(
        "chrome", "firefox", "msedge", "opera", "brave", "vivaldi", "arc"
    )

    # Exclude these from alternatives (IDEs, terminals, system)
    $excludeProcesses = @(
        "Antigravity", "Code", "cursor", "WindowsTerminal", "cmd", "powershell",
        "explorer", "SearchHost", "StartMenuExperienceHost", "ShellExperienceHost",
        "TextInputHost", "SystemSettings", "ApplicationFrameHost"
    )

    # Get all visible windows
    $allWindows = Get-Process | Where-Object {
        $_.MainWindowHandle -ne 0 -and
        $_.MainWindowTitle -ne "" -and
        $excludeProcesses -notcontains $_.ProcessName
    }

    # Method 1: Find by known game process names
    $gameWindow = $allWindows | Where-Object {
        $gameProcesses -contains $_.ProcessName
    } | Select-Object -First 1

    # Method 2: If not found, check by path (Steam/Epic/etc directories)
    if (-not $gameWindow) {
        $gameWindow = $allWindows | Where-Object {
            Test-IsGame $_
        } | Select-Object -First 1
    }

    if ($gameWindow) {
        $previousWindow = $gameWindow.MainWindowHandle
        $wasMaximized = [Win32]::IsZoomed($previousWindow)
        $wasMinimized = [Win32]::IsIconic($previousWindow)
        $alternativeFound = $true
        Write-Host "[Claude Watcher] Found game/entertainment: $($gameWindow.ProcessName) ($($gameWindow.MainWindowTitle))"
    }

    # If no game, try browser
    if (-not $alternativeFound) {
        $browserWindow = $allWindows | Where-Object {
            $browserProcesses -contains $_.ProcessName
        } | Select-Object -First 1

        if ($browserWindow) {
            $previousWindow = $browserWindow.MainWindowHandle
            $wasMaximized = [Win32]::IsZoomed($previousWindow)
            $wasMinimized = [Win32]::IsIconic($previousWindow)
            $alternativeFound = $true
            Write-Host "[Claude Watcher] Found browser: $($browserWindow.ProcessName) ($($browserWindow.MainWindowTitle))"
        }
    }

    # If nothing found, we'll minimize to desktop on resume
    if (-not $alternativeFound) {
        Write-Host "[Claude Watcher] No alternative window found - will minimize to desktop on resume"
        $previousWindow = [IntPtr]::Zero
    }
}

# Pause all media sessions and track which processes were playing
$mediaProcessNames = @()
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime

    $asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

    Function Await($WinRtTask, $ResultType) {
        $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
        $netTask = $asTask.Invoke($null, @($WinRtTask))
        $netTask.Wait(-1) | Out-Null
        $netTask.Result
    }

    [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime] | Out-Null
    $asyncOp = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()
    $manager = Await $asyncOp ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

    $sessions = $manager.GetSessions()
    $pausedCount = 0
    foreach ($session in $sessions) {
        $playbackInfo = $session.GetPlaybackInfo()
        if ($playbackInfo.PlaybackStatus -eq [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Playing) {
            $pauseOp = $session.TryPauseAsync()
            Await $pauseOp ([bool]) | Out-Null
            $pausedCount++

            # Extract process name from SourceAppUserModelId (e.g., "Spotify.exe" or "chrome.exe")
            $appId = $session.SourceAppUserModelId
            # Handle different formats: "AppName.exe", "Microsoft.ZuneMusic_...", "chrome.exe", etc.
            if ($appId -match '\.exe$') {
                $mediaProcessNames += ($appId -replace '\.exe$', '')
            } elseif ($appId -match '^([^_]+)_') {
                # UWP app format like "Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"
                $mediaProcessNames += $matches[1]
            } else {
                $mediaProcessNames += $appId
            }

            Write-Host "[Claude Watcher] Paused media session: $appId"
        }
    }

    if ($pausedCount -eq 0) {
        Write-Host "[Claude Watcher] No active media sessions to pause"
    }
} catch {
    Write-Host "[Claude Watcher] Could not pause media: $_"
}

# Check if the previous window's process was playing media
$previousProcessName = ""
if ($previousWindow -ne [IntPtr]::Zero) {
    $prevProcId = 0
    [Win32]::GetWindowThreadProcessId($previousWindow, [ref]$prevProcId) | Out-Null
    $prevProc = Get-Process -Id $prevProcId -ErrorAction SilentlyContinue
    if ($prevProc) {
        $previousProcessName = $prevProc.ProcessName
    }
}

# Determine if we should resume media on return
# Only resume if the previous window was from a media-playing process
$wasOnMediaWindow = $false
if ($previousProcessName -and $mediaProcessNames.Count -gt 0) {
    foreach ($mediaProc in $mediaProcessNames) {
        if ($previousProcessName -like "*$mediaProc*" -or $mediaProc -like "*$previousProcessName*") {
            $wasOnMediaWindow = $true
            Write-Host "[Claude Watcher] Previous window ($previousProcessName) matches media process ($mediaProc)"
            break
        }
    }
}

$stateData = @{
    previousWindowHandle = $previousWindow.ToInt64()
    wasMaximized = $wasMaximized
    wasMinimized = $wasMinimized
    useDesktop = (-not $alternativeFound -and $currentProcess.ProcessName -eq "Antigravity")
    wasOnMediaWindow = $wasOnMediaWindow
    mediaProcessNames = $mediaProcessNames
    previousProcessName = $previousProcessName
    timestamp = (Get-Date).ToString("o")
}
$stateData | ConvertTo-Json | Set-Content $statePath -Force

if ($alternativeFound) {
    Write-Host "[Claude Watcher] Saving alternative window: $($previousWindow.ToInt64()) (maximized: $wasMaximized, onMedia: $wasOnMediaWindow)"
} elseif ($stateData.useDesktop) {
    Write-Host "[Claude Watcher] Will show desktop on resume"
} else {
    Write-Host "[Claude Watcher] Saving previous window: $($previousWindow.ToInt64()) (maximized: $wasMaximized, onMedia: $wasOnMediaWindow)"
}

# Bring Antigravity to foreground and maximize
$antigravity = Get-Process -Name "Antigravity" -ErrorAction SilentlyContinue |
               Where-Object { $_.MainWindowHandle -ne 0 } |
               Select-Object -First 1

if ($antigravity) {
    $hwnd = $antigravity.MainWindowHandle
    $processId = $antigravity.Id

    Write-Host "[Claude Watcher] Found Antigravity (PID: $processId, HWND: $hwnd)"

    # Restore if minimized
    if ([Win32]::IsIconic($hwnd)) {
        [Win32]::ShowWindow($hwnd, [Win32]::SW_RESTORE) | Out-Null
        Start-Sleep -Milliseconds 100
    }

    # Method 1: Try AppActivate by process ID (most reliable)
    try {
        [Microsoft.VisualBasic.Interaction]::AppActivate($processId)
        Write-Host "[Claude Watcher] AppActivate by PID succeeded"
        $focused = $true
    } catch {
        Write-Host "[Claude Watcher] AppActivate by PID failed: $_"
        $focused = $false
    }

    # Method 2: If AppActivate failed, try by window title
    if (-not $focused -or [Win32]::GetForegroundWindow() -ne $hwnd) {
        try {
            [Microsoft.VisualBasic.Interaction]::AppActivate("Antigravity")
            Write-Host "[Claude Watcher] AppActivate by title succeeded"
            $focused = $true
        } catch {
            Write-Host "[Claude Watcher] AppActivate by title failed: $_"
        }
    }

    # Method 3: Make topmost and use SetForegroundWindow
    if ([Win32]::GetForegroundWindow() -ne $hwnd) {
        [Win32]::SetWindowPos($hwnd, [Win32]::HWND_TOPMOST, 0, 0, 0, 0, [Win32]::SWP_NOMOVE -bor [Win32]::SWP_NOSIZE -bor [Win32]::SWP_SHOWWINDOW)
        Start-Sleep -Milliseconds 50
        [Win32]::SetForegroundWindow($hwnd)
        [Win32]::SetWindowPos($hwnd, [Win32]::HWND_NOTOPMOST, 0, 0, 0, 0, [Win32]::SWP_NOMOVE -bor [Win32]::SWP_NOSIZE -bor [Win32]::SWP_SHOWWINDOW)
        Write-Host "[Claude Watcher] Used TOPMOST + SetForegroundWindow"
    }

    # Maximize window unless -NoMaximize specified
    if (-not $NoMaximize) {
        [Win32]::ShowWindow($hwnd, [Win32]::SW_MAXIMIZE) | Out-Null
        Write-Host "[Claude Watcher] Maximized Antigravity window"
    }

    # Final check
    if ([Win32]::GetForegroundWindow() -eq $hwnd) {
        Write-Host "[Claude Watcher] SUCCESS: Antigravity is now focused"
    } else {
        Write-Host "[Claude Watcher] WARNING: Focus may not have switched completely"
    }
} else {
    Write-Host "[Claude Watcher] Antigravity process not found"
}

# Play notification sound
try {
    [System.Media.SystemSounds]::Asterisk.Play()
    Write-Host "[Claude Watcher] Played notification sound"
} catch {
    Write-Host "[Claude Watcher] Could not play sound: $_"
}

Write-Host "[Claude Watcher] Pause and focus complete"
