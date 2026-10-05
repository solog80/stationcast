package main

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"os/exec"
	"runtime"
	"time"

	"github.com/energye/systray"
)

var (
	mStatus    *systray.MenuItem
	mOpenDash  *systray.MenuItem
	mForceKey  *systray.MenuItem
	mAutoStart *systray.MenuItem
	mQuit      *systray.MenuItem
)

func generateTrayIconPNG() []byte {
	w, h := 32, 32
	img := image.NewRGBA(image.Rect(0, 0, w, h))

	// Draw vibrant red broadcast circle badge (#DC2626) with white contrast border
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			dx := x - 16
			dy := y - 16
			distSq := dx*dx + dy*dy
			if distSq <= 14*14 {
				if distSq >= 12*12 {
					// High-contrast white border ring
					img.Set(x, y, color.RGBA{R: 255, G: 255, B: 255, A: 255})
				} else {
					// Vibrant Live Broadcast Red
					img.Set(x, y, color.RGBA{R: 220, G: 38, B: 38, A: 255})
				}
			} else {
				img.Set(x, y, color.RGBA{R: 0, G: 0, B: 0, A: 0})
			}
		}
	}

	// Inner white live core dot
	for y := 10; y <= 22; y++ {
		for x := 10; x <= 22; x++ {
			dx := x - 16
			dy := y - 16
			if dx*dx+dy*dy <= 5*5 {
				img.Set(x, y, color.RGBA{R: 255, G: 255, B: 255, A: 255})
			}
		}
	}

	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

func setupSystray(manager *EngineManager, port int) {
	systray.Run(func() {
		iconData := generateTrayIconPNG()
		systray.SetIcon(iconData)
		systray.SetTemplateIcon(iconData, iconData)
		systray.SetTitle("SC")
		systray.SetTooltip("StationCast Multi-Stream NDI Bridge")
		systray.CreateMenu()

		mStatus = systray.AddMenuItem("Status: Initializing...", "Current Multi-Stream Status")
		mStatus.Disable()

		mOpenDash = systray.AddMenuItem("🌐 Open Web Dashboard", "Open Dashboard in Browser")
		mForceKey = systray.AddMenuItem("⚡ Force Keyframe All (PLI)", "Send Keyframe Request to All Streams")
		systray.AddSeparator()

		autoStartEnabled := isAutoStartEnabled()
		mAutoStart = systray.AddMenuItemCheckbox("🚀 Auto-Start at Login", "Toggle boot persistence", autoStartEnabled)
		systray.AddSeparator()

		mQuit = systray.AddMenuItem("❌ Quit StationCast NDI", "Stop and exit")

		mOpenDash.Click(func() {
			url := fmt.Sprintf("http://localhost:%d", port)
			if runtime.GOOS == "windows" {
				_ = exec.Command("cmd", "/c", "start", url).Run()
			} else if runtime.GOOS == "darwin" {
				_ = exec.Command("open", url).Run()
			}
		})

		mForceKey.Click(func() {
			manager.RequestPLI("")
			addLog("⚡ Manual Keyframe (PLI) requested for all streams from system tray")
		})

		mAutoStart.Click(func() {
			newVal := !mAutoStart.Checked()
			if err := setAutoStart(newVal); err == nil {
				if newVal {
					mAutoStart.Check()
				} else {
					mAutoStart.Uncheck()
				}
			}
		})

		mQuit.Click(func() {
			manager.StopAll()
			systray.Quit()
			os.Exit(0)
		})

		// Status update loop
		go func() {
			for {
				time.Sleep(1 * time.Second)
				appState.Lock()
				liveCount := 0
				totalCount := len(appState.Streams)
				for _, st := range appState.Streams {
					if st.StatusColor == "green" {
						liveCount++
					}
				}
				statusText := fmt.Sprintf("Status: %d/%d Streams Live", liveCount, totalCount)
				appState.Unlock()

				mStatus.SetTitle(statusText)
			}
		}()

	}, func() {
		manager.StopAll()
	})
}
