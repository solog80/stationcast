//go:build !cgo

package main

import (
	"bytes"
	"fmt"
	"image"
	"runtime"
	"sync"

	"golang.org/x/image/vp8"
)

var (
	rTable     [256]int
	gTableCb   [256]int
	gTableCr   [256]int
	bTable     [256]int
	clampTable [1024]byte
)

func init() {
	for i := 0; i < 256; i++ {
		rTable[i] = (91881 * (i - 128)) >> 16
		gTableCb[i] = (22554 * (i - 128)) >> 16
		gTableCr[i] = (46802 * (i - 128)) >> 16
		bTable[i] = (116130 * (i - 128)) >> 16
	}

	for i := 0; i < 1024; i++ {
		val := i - 256
		if val < 0 {
			clampTable[i] = 0
		} else if val > 255 {
			clampTable[i] = 255
		} else {
			clampTable[i] = byte(val)
		}
	}
}

type PureGoVP8Decoder struct {
	dec     *vp8.Decoder
	bgraBuf []byte
}

func NewVideoDecoder(mimeType string) (VideoDecoder, error) {
	_ = mimeType
	return &PureGoVP8Decoder{
		dec: vp8.NewDecoder(),
	}, nil
}

func (d *PureGoVP8Decoder) Decode(payload []byte) (int, int, []byte, int, error) {
	if len(payload) == 0 {
		return 0, 0, nil, 0, fmt.Errorf("empty payload")
	}

	d.dec.Init(bytes.NewReader(payload), len(payload))
	_, err := d.dec.DecodeFrameHeader()
	if err != nil {
		return 0, 0, nil, 0, err
	}

	img, err := d.dec.DecodeFrame()
	if err != nil {
		return 0, 0, nil, 0, err
	}

	w := img.Rect.Dx()
	h := img.Rect.Dy()
	if w <= 0 || h <= 0 {
		return 0, 0, nil, 0, fmt.Errorf("invalid frame dimensions %dx%d", w, h)
	}

	needed := w * h * 4
	if len(d.bgraBuf) < needed {
		d.bgraBuf = make([]byte, needed)
	}

	ycbcrToBGRAParallel(img, d.bgraBuf)
	return w, h, d.bgraBuf, w * 4, nil
}

func (d *PureGoVP8Decoder) Close() {}

func (d *PureGoVP8Decoder) HWDeviceName() string {
	return "software (pure-Go VP8)"
}

type PureGoAudioDecoder struct{}

func NewAudioDecoder() (AudioDecoder, error) {
	return &PureGoAudioDecoder{}, nil
}

func (d *PureGoAudioDecoder) Decode(payload []byte) (int, int, int, []float32, error) {
	return 0, 0, 0, nil, fmt.Errorf("purego audio decoding not implemented")
}

func (d *PureGoAudioDecoder) Close() {}

func ycbcrToBGRAParallel(img *image.YCbCr, bgraBuf []byte) {
	w := img.Rect.Dx()
	h := img.Rect.Dy()

	numWorkers := runtime.NumCPU()
	if numWorkers > 16 {
		numWorkers = 16
	}
	if numWorkers < 1 {
		numWorkers = 1
	}

	rowsPerWorker := (h + numWorkers - 1) / numWorkers

	var wg sync.WaitGroup
	wg.Add(numWorkers)

	yStride := img.YStride
	cStride := img.CStride

	for i := 0; i < numWorkers; i++ {
		startY := i * rowsPerWorker
		endY := startY + rowsPerWorker
		if endY > h {
			endY = h
		}

		go func(sY, eY int) {
			defer wg.Done()
			for y := sY; y < eY; y++ {
				yOff := y * yStride
				cOff := (y / 2) * cStride
				outOff := y * w * 4

				for x := 0; x < w; x++ {
					yy := int(img.Y[yOff+x])
					cbIdx := int(img.Cb[cOff+(x/2)])
					crIdx := int(img.Cr[cOff+(x/2)])

					r := yy + rTable[crIdx]
					g := yy - gTableCb[cbIdx] - gTableCr[crIdx]
					b := yy + bTable[cbIdx]

					bgraBuf[outOff] = clampTable[b+256]
					bgraBuf[outOff+1] = clampTable[g+256]
					bgraBuf[outOff+2] = clampTable[r+256]
					bgraBuf[outOff+3] = 255
					outOff += 4
				}
			}
		}(startY, endY)
	}

	wg.Wait()
}
