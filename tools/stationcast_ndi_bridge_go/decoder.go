package main

type VideoDecoder interface {
	Decode(payload []byte) (width int, height int, bgra []byte, stride int, err error)
	Close()
}
