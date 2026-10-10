package main

type VideoDecoder interface {
	Decode(payload []byte) (width int, height int, bgra []byte, stride int, err error)
	HWDeviceName() string
	Close()
}

type AudioDecoder interface {
	Decode(payload []byte) (sampleRate int, channels int, numSamples int, pcmFloat []float32, err error)
	Close()
}
