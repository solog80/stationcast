//go:build !cgo || windows

package main

import (
	"bytes"
	"fmt"
	"image"
	"golang.org/x/image/vp8"
)

type PureGoVP8Decoder struct {
	dec     *vp8.Decoder
	bgraBuf []byte
}

func NewVideoDecoder() (VideoDecoder, error) {
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

	ycbcrToBGRA(img, d.bgraBuf)
	return w, h, d.bgraBuf, w * 4, nil
}

func (d *PureGoVP8Decoder) Close() {}

func ycbcrToBGRA(img *image.YCbCr, bgraBuf []byte) {
	w := img.Rect.Dx()
	h := img.Rect.Dy()

	yStride := img.YStride
	cStride := img.CStride

	for y := 0; y < h; y++ {
		yOff := y * yStride
		cOff := (y / 2) * cStride
		outOff := y * w * 4

		for x := 0; x < w; x++ {
			yy := int(img.Y[yOff+x])
			cb := int(img.Cb[cOff+(x/2)]) - 128
			cr := int(img.Cr[cOff+(x/2)]) - 128

			r := yy + (91881*cr >> 16)
			g := yy - (22554*cb >> 16) - (46802*cr >> 16)
			b := yy + (116130*cb >> 16)

			if r < 0 {
				r = 0
			} else if r > 255 {
				r = 255
			}
			if g < 0 {
				g = 0
			} else if g > 255 {
				g = 255
			}
			if b < 0 {
				b = 0
			} else if b > 255 {
				b = 255
			}

			bgraBuf[outOff] = byte(b)
			bgraBuf[outOff+1] = byte(g)
			bgraBuf[outOff+2] = byte(r)
			bgraBuf[outOff+3] = 255
			outOff += 4
		}
	}
}
