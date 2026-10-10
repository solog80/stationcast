package main

import (
	"bytes"
	"encoding/binary"
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

func generateTrayIconImage() *image.RGBA {
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

	return img
}

func generateTrayIconPNG() []byte {
	var buf bytes.Buffer
	_ = png.Encode(&buf, generateTrayIconImage())
	return buf.Bytes()
}

// generateTrayIconICO builds a Windows .ico (uncompressed 32-bit BMP payload).
// The Windows systray backend loads the icon via LoadImageW(..., IMAGE_ICON, ...),
// which only understands .ico files - a raw PNG is silently ignored, leaving an
// empty notification-area slot.
func generateTrayIconICO() []byte {
	img := generateTrayIconImage()
	w := img.Bounds().Dx()
	h := img.Bounds().Dy()

	// BITMAPINFOHEADER + XOR (BGRA) bitmap + AND mask
	xorSize := w * h * 4
	andRowBytes := ((w + 31) / 32) * 4
	andSize := andRowBytes * h
	imageSize := 40 + xorSize + andSize

	var buf bytes.Buffer

	// ICONDIR
	writeLE(&buf, uint16(0)) // reserved
	writeLE(&buf, uint16(1)) // type: icon
	writeLE(&buf, uint16(1)) // image count

	// ICONDIRENTRY
	buf.WriteByte(byte(w % 256)) // width  (0 means 256)
	buf.WriteByte(byte(h % 256)) // height (0 means 256)
	buf.WriteByte(0)             // color palette count
	buf.WriteByte(0)             // reserved
	writeLE(&buf, uint16(1))     // color planes
	writeLE(&buf, uint16(32))    // bits per pixel
	writeLE(&buf, uint32(imageSize))
	writeLE(&buf, uint32(22)) // offset to image data (6 + 16)

	// BITMAPINFOHEADER
	writeLE(&buf, uint32(40))       // header size
	writeLE(&buf, int32(w))         // width
	writeLE(&buf, int32(h*2))       // height (XOR + AND)
	writeLE(&buf, uint16(1))        // planes
	writeLE(&buf, uint16(32))       // bit count
	writeLE(&buf, uint32(0))        // BI_RGB (uncompressed)
	writeLE(&buf, uint32(xorSize))  // image size
	writeLE(&buf, int32(0))         // x pixels per meter
	writeLE(&buf, int32(0))         // y pixels per meter
	writeLE(&buf, uint32(0))        // colors used
	writeLE(&buf, uint32(0))        // important colors

	// XOR bitmap: 32-bit BGRA, bottom-up
	for y := h - 1; y >= 0; y-- {
		for x := 0; x < w; x++ {
			c := img.RGBAAt(x, y)
			buf.WriteByte(c.B)
			buf.WriteByte(c.G)
			buf.WriteByte(c.R)
			buf.WriteByte(c.A)
		}
	}

	// AND mask: 1bpp, bottom-up, row-aligned to 4 bytes (all zero -> use alpha)
	buf.Write(make([]byte, andSize))

	return buf.Bytes()
}

func writeLE(buf *bytes.Buffer, v any) {
	_ = binary.Write(buf, binary.LittleEndian, v)
}

func setupSystray(manager *EngineManager, port int) {
	systray.Run(func() {
		if runtime.GOOS == "windows" {
			// Windows LoadImageW requires a real .ico container.
			systray.SetIcon(generateTrayIconICO())
		} else {
			// macOS/Linux accept PNG directly; template icon enables dark-mode tinting.
			iconData := generateTrayIconPNG()
			systray.SetIcon(iconData)
			systray.SetTemplateIcon(iconData, iconData)
			systray.SetTitle("SC")
		}
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
