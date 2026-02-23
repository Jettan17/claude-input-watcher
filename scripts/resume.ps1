# resume.ps1 - Resume media and restore previous window focus & state
# Called when user submits a response to Claude

param(
    [switch]$NoMaximize  # Skip maximizing the restored window
)

$ErrorActionPreference = "SilentlyContinue"

# Check if watcher is enabled via flag file
$flagFile = Join-Path $env:USERPROFILE ".claude-watcher-enabled"
if (Test-Path $flagFile) {
    $flagContent = Get-Content $flagFile -Raw
    if ($flagContent.Trim() -eq "false") {
        Write-Host "[Claude Watcher] Disabled - skipping resume"
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

public class Win32Resume {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public const int SW_RESTORE = 9;
    public const int SW_SHOW = 5;
    public const int SW_MAXIMIZE = 3;

    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_SHOWWINDOW = 0x0040;
}
"@

Write-Host "[Claude Watcher] Resuming previous state..."

# Check if we should resume media (only if user was on a media window)
$shouldResumeMedia = $false
if (Test-Path $statePath) {
    try {
        $statePreCheck = Get-Content $statePath -Raw | ConvertFrom-Json
        $shouldResumeMedia = $statePreCheck.wasOnMediaWindow -eq $true
        if ($shouldResumeMedia) {
            Write-Host "[Claude Watcher] User was on media window - will resume playback"
        } else {
            Write-Host "[Claude Watcher] User was NOT on media window ($($statePreCheck.previousProcessName)) - skipping media resume"
        }
    } catch {
        Write-Host "[Claude Watcher] Could not read state for media check: $_"
    }
}

# Resume media sessions only if user was on a media window
if ($shouldResumeMedia) {
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
        $resumedCount = 0
        foreach ($session in $sessions) {
            $playbackInfo = $session.GetPlaybackInfo()
            if ($playbackInfo.PlaybackStatus -eq [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionPlaybackStatus]::Paused) {
                $playOp = $session.TryPlayAsync()
                Await $playOp ([bool]) | Out-Null
                $resumedCount++
                Write-Host "[Claude Watcher] Resumed media session: $($session.SourceAppUserModelId)"
            }
        }

        if ($resumedCount -eq 0) {
            Write-Host "[Claude Watcher] No paused media sessions to resume"
        }
    } catch {
        Write-Host "[Claude Watcher] Could not resume media: $_"
    }
}

# Restore focus to previous window or show desktop
if (Test-Path $statePath) {
    try {
        $state = Get-Content $statePath -Raw | ConvertFrom-Json

        # Check if we should show desktop instead
        if ($state.useDesktop) {
            Write-Host "[Claude Watcher] Showing desktop..."
            # Use Shell.Application to minimize all windows (show desktop)
            $shell = New-Object -ComObject Shell.Application
            $shell.MinimizeAll()
            Write-Host "[Claude Watcher] SUCCESS: Minimized all windows to show desktop"
        }
        elseif ($state.previousWindowHandle -and $state.previousWindowHandle -ne 0) {
            $hwnd = [IntPtr]$state.previousWindowHandle

            # Check if the window still exists
            if ([Win32Resume]::IsWindow($hwnd)) {
                # Get process ID from window handle
                $processId = 0
                [Win32Resume]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null

                # Restore if minimized
                if ([Win32Resume]::IsIconic($hwnd)) {
                    [Win32Resume]::ShowWindow($hwnd, [Win32Resume]::SW_RESTORE) | Out-Null
                    Start-Sleep -Milliseconds 100
                }

                # Method 1: Try AppActivate by process ID
                $focused = $false
                if ($processId -ne 0) {
                    try {
                        [Microsoft.VisualBasic.Interaction]::AppActivate($processId)
                        Write-Host "[Claude Watcher] AppActivate by PID succeeded"
                        $focused = $true
                    } catch {
                        Write-Host "[Claude Watcher] AppActivate by PID failed: $_"
                    }
                }

                # Method 2: Make topmost and use SetForegroundWindow
                if (-not $focused -or [Win32Resume]::GetForegroundWindow() -ne $hwnd) {
                    [Win32Resume]::SetWindowPos($hwnd, [Win32Resume]::HWND_TOPMOST, 0, 0, 0, 0, [Win32Resume]::SWP_NOMOVE -bor [Win32Resume]::SWP_NOSIZE -bor [Win32Resume]::SWP_SHOWWINDOW)
                    Start-Sleep -Milliseconds 50
                    [Win32Resume]::SetForegroundWindow($hwnd)
                    [Win32Resume]::SetWindowPos($hwnd, [Win32Resume]::HWND_NOTOPMOST, 0, 0, 0, 0, [Win32Resume]::SWP_NOMOVE -bor [Win32Resume]::SWP_NOSIZE -bor [Win32Resume]::SWP_SHOWWINDOW)
                    Write-Host "[Claude Watcher] Used TOPMOST + SetForegroundWindow"
                }

                # Restore maximized state if it was maximized before
                if ($state.wasMaximized -and -not $NoMaximize) {
                    [Win32Resume]::ShowWindow($hwnd, [Win32Resume]::SW_MAXIMIZE) | Out-Null
                    Write-Host "[Claude Watcher] Restored maximized state"
                }

                # Final check
                if ([Win32Resume]::GetForegroundWindow() -eq $hwnd) {
                    Write-Host "[Claude Watcher] SUCCESS: Previous window is now focused"
                } else {
                    Write-Host "[Claude Watcher] Restored focus to previous window: $($state.previousWindowHandle)"
                }
            } else {
                Write-Host "[Claude Watcher] Previous window no longer exists - showing desktop"
                $shell = New-Object -ComObject Shell.Application
                $shell.MinimizeAll()
            }
        }

        # Clean up state file
        Remove-Item $statePath -Force

    } catch {
        Write-Host "[Claude Watcher] Could not restore state: $_"
    }
} else {
    Write-Host "[Claude Watcher] No saved state to restore"
}

Write-Host "[Claude Watcher] Resume complete"
