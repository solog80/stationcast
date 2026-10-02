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

	// Draw dark blue badge circle with "SC" broadcast symbol
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			dx := x - 16
			dy := y - 16
			if dx*dx+dy*dy <= 14*14 {
				img.Set(x, y, color.RGBA{R: 2, G: 132, B: 199, A: 255})
			} else {
				img.Set(x, y, color.RGBA{R: 0, G: 0, B: 0, A: 0})
			}
		}
	}

	// Inner live indicator dot
	for y := 12; y <= 20; y++ {
		for x := 12; x <= 20; x++ {
			dx := x - 16
			dy := y - 16
			if dx*dx+dy*dy <= 4*4 {
				img.Set(x, y, color.RGBA{R: 248, G: 250, B: 252, A: 255})
			}
		}
	}

	var buf bytes.Buffer
	_ = png.Encode(&buf, img)
	return buf.Bytes()
}

func setupSystray(engine *BridgeEngine, port int) {
	systray.Run(func() {
		iconData := generateTrayIconPNG()
		systray.SetTemplateIcon(iconData, iconData)
		systray.SetTitle("")
		systray.SetTooltip("StationCast OME to NDI Bridge")

		mStatus = systray.AddMenuItem("Status: Initializing...", "Current Stream Status")
		mStatus.Disable()

		mOpenDash = systray.AddMenuItem("🌐 Open Web Dashboard", "Open Dashboard in Browser")
		mForceKey = systray.AddMenuItem("⚡ Force Keyframe (PLI)", "Send Keyframe Request")
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
			engine.RequestPLI()
			addLog("⚡ Manual Keyframe (PLI) requested from system tray")
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
			engine.Stop()
			systray.Quit()
			os.Exit(0)
		})

		// Status update loop
		go func() {
			for {
				time.Sleep(1 * time.Second)
				state.Lock()
				statusText := fmt.Sprintf("Status: %s (%s)", state.Status, state.Mode)
				if state.FPS > 0 {
					statusText = fmt.Sprintf("Status: %s (%dx%d @ %d FPS)", state.Status, 1280, 720, state.FPS)
				}
				state.Unlock()

				mStatus.SetTitle(statusText)
			}
		}()

	}, func() {
		engine.Stop()
	})
}
