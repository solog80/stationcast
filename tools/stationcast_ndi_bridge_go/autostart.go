package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
)

const launchAgentID = "tv.stationcast.ndi_bridge"

func isAutoStartEnabled() bool {
	if runtime.GOOS == "windows" {
		cmd := exec.Command("reg", "query", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", "StationCastNDIBridge")
		return cmd.Run() == nil
	} else if runtime.GOOS == "darwin" {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			return false
		}
		plistPath := filepath.Join(homeDir, "Library", "LaunchAgents", launchAgentID+".plist")
		_, err = os.Stat(plistPath)
		return err == nil
	}
	return false
}

func setAutoStart(enable bool) error {
	exePath, err := os.Executable()
	if err != nil {
		return fmt.Errorf("failed to get executable path: %w", err)
	}
	exePath, err = filepath.EvalSymlinks(exePath)
	if err != nil {
		return fmt.Errorf("failed to resolve symlink: %w", err)
	}

	if runtime.GOOS == "windows" {
		if enable {
			cmd := exec.Command("reg", "add", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", "StationCastNDIBridge", "/t", "REG_SZ", "/d", fmt.Sprintf(`"%s"`, exePath), "/f")
			if err := cmd.Run(); err != nil {
				return fmt.Errorf("failed to enable Windows auto-start reg key: %w", err)
			}
			addLog("✅ Windows Auto-Start enabled (HKCU Run registry)")
		} else {
			cmd := exec.Command("reg", "delete", `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, "/v", "StationCastNDIBridge", "/f")
			_ = cmd.Run()
			addLog("Disabled Windows Auto-Start")
		}
	} else if runtime.GOOS == "darwin" {
		homeDir, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		launchAgentsDir := filepath.Join(homeDir, "Library", "LaunchAgents")
		_ = os.MkdirAll(launchAgentsDir, 0755)
		plistPath := filepath.Join(launchAgentsDir, launchAgentID+".plist")

		if enable {
			plistContent := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>%s</string>
    <key>ProgramArguments</key>
    <array>
        <string>%s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>%s</string>
</dict>
</plist>`, launchAgentID, exePath, filepath.Dir(exePath))

			if err := os.WriteFile(plistPath, []byte(plistContent), 0644); err != nil {
				return fmt.Errorf("failed to write LaunchAgent plist: %w", err)
			}
			addLog(fmt.Sprintf("✅ macOS Auto-Start enabled LaunchAgent (%s)", plistPath))
		} else {
			_ = os.Remove(plistPath)
			addLog("Disabled macOS Auto-Start LaunchAgent")
		}
	}
	return nil
}
