package main

import (
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"os"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

func generateSMPTEColorBarsBGRA(w, h int) []byte {
	buf := make([]byte, w*h*4)

	topColors := [7][3]byte{
		{192, 192, 192}, // Gray/White 75%
		{192, 192, 0},   // Yellow
		{0, 192, 192},   // Cyan
		{0, 192, 0},     // Green
		{192, 0, 192},   // Magenta
		{192, 0, 0},     // Red
		{0, 0, 192},     // Blue
	}

	topH := int(float64(h) * 0.67)
	midH := int(float64(h) * 0.75)

	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			off := (y*w + x) * 4
			barIdx := (x * 7) / w
			if barIdx > 6 {
				barIdx = 6
			}

			var r, g, b byte
			if y < topH {
				c := topColors[barIdx]
				r, g, b = c[0], c[1], c[2]
			} else if y < midH {
				switch barIdx {
				case 0:
					r, g, b = 0, 0, 192
				case 1:
					r, g, b = 19, 19, 19
				case 2:
					r, g, b = 192, 0, 192
				case 3:
					r, g, b = 19, 19, 19
				case 4:
					r, g, b = 0, 192, 192
				case 5:
					r, g, b = 19, 19, 19
				case 6:
					r, g, b = 192, 192, 192
				}
			} else {
				subBarIdx := (x * 4) / w
				switch subBarIdx {
				case 0:
					r, g, b = 0, 33, 76
				case 1:
					r, g, b = 255, 255, 255
				case 2:
					r, g, b = 56, 0, 106
				case 3:
					plugeX := x - (3 * w / 4)
					plugeW := w / 4
					if plugeX < plugeW/3 {
						r, g, b = 7, 7, 7
					} else if plugeX < (plugeW * 2 / 3) {
						r, g, b = 19, 19, 19
					} else {
						r, g, b = 38, 38, 38
					}
				}
			}

			buf[off] = b
			buf[off+1] = g
			buf[off+2] = r
			buf[off+3] = 255
		}
	}

	return buf
}

func loadOrGenerateStandbyBGRA(path string, w, h int) []byte {
	pathsToTry := []string{
		path,
		"smpte_color_bars.webp",
	}

	var f *os.File
	var err error
	var loadedPath string

	for _, p := range pathsToTry {
		if p == "" {
			continue
		}
		f, err = os.Open(p)
		if err == nil {
			loadedPath = p
			break
		}
	}

	if f == nil {
		addLog("⚠️ Standby image file not found. Using procedural SMPTE Color Bars.")
		return generateSMPTEColorBarsBGRA(w, h)
	}
	defer f.Close()

	srcImg, fmtName, err := image.Decode(f)
	if err != nil {
		addLog(fmt.Sprintf("⚠️ Failed to decode standby image '%s': %v. Using procedural SMPTE Color Bars.", loadedPath, err))
		return generateSMPTEColorBarsBGRA(w, h)
	}

	addLog(fmt.Sprintf("Loaded standby image '%s' (%s, original size: %dx%d)", loadedPath, fmtName, srcImg.Bounds().Dx(), srcImg.Bounds().Dy()))

	dstImg := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.BiLinear.Scale(dstImg, dstImg.Bounds(), srcImg, srcImg.Bounds(), draw.Over, nil)

	bgra := make([]byte, w*h*4)
	for i := 0; i < len(dstImg.Pix); i += 4 {
		bgra[i] = dstImg.Pix[i+2]
		bgra[i+1] = dstImg.Pix[i+1]
		bgra[i+2] = dstImg.Pix[i]
		bgra[i+3] = 255
	}

	return bgra
}
