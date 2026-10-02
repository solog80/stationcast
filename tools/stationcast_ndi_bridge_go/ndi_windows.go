//go:build windows && !cgo

package main

import (
	"errors"
	"fmt"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

type NDIlib_FourCC_video_type_e uint32

const (
	NDIlib_FourCC_video_type_BGRA NDIlib_FourCC_video_type_e = 0x41524742
)

type NDIlib_send_create_t struct {
	p_ndi_name  *byte
	p_groups    *byte
	clock_video bool
	clock_audio bool
}

type NDIlib_video_frame_v2_t struct {
	xres                 int32
	yres                 int32
	FourCC               NDIlib_FourCC_video_type_e
	frame_rate_N         int32
	frame_rate_D         int32
	picture_aspect_ratio float32
	frame_format_type    int32
	timecode             int64
	p_data               *byte
	line_stride_in_bytes int32
	p_metadata           *byte
	timestamp            int64
}

type NDISender struct {
	instance uintptr
	dll      *syscall.LazyDLL
	pInit    *syscall.LazyProc
	pDestroy *syscall.LazyProc
	pCreate  *syscall.LazyProc
	pSDestroy *syscall.LazyProc
	pSend    *syscall.LazyProc
	mu       sync.Mutex
}

func NewNDISender(ndiName string) (*NDISender, error) {
	dllName := "Processing.NDI.Lib.x64.dll"
	dll := syscall.NewLazyDLL(dllName)
	if err := dll.Load(); err != nil {
		dllName = "Processing.NDI.Lib.x86.dll"
		dll = syscall.NewLazyDLL(dllName)
		if err2 := dll.Load(); err2 != nil {
			return nil, fmt.Errorf("failed to load NDI DLL (%s): %v", dllName, err)
		}
	}

	sender := &NDISender{
		dll:       dll,
		pInit:     dll.NewProc("NDIlib_initialize"),
		pDestroy:  dll.NewProc("NDIlib_destroy"),
		pCreate:   dll.NewProc("NDIlib_send_create"),
		pSDestroy: dll.NewProc("NDIlib_send_destroy"),
		pSend:     dll.NewProc("NDIlib_send_send_video_v2"),
	}

	ret, _, err := sender.pInit.Call()
	if ret == 0 {
		return nil, fmt.Errorf("NDIlib_initialize failed: %v", err)
	}

	nameC, _ := syscall.BytePtrFromString(ndiName)
	createSettings := NDIlib_send_create_t{
		p_ndi_name:  nameC,
		p_groups:    nil,
		clock_video: true,
		clock_audio: true,
	}

	inst, _, _ := sender.pCreate.Call(uintptr(unsafe.Pointer(&createSettings)))
	if inst == 0 {
		return nil, errors.New("NDIlib_send_create returned null instance")
	}

	sender.instance = inst
	return sender, nil
}

func (s *NDISender) SendVideo(w, h int, data []byte, stride int) {
	if s == nil || s.instance == 0 || len(data) == 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	frame := NDIlib_video_frame_v2_t{
		xres:                 int32(w),
		yres:                 int32(h),
		FourCC:               NDIlib_FourCC_video_type_BGRA,
		frame_rate_N:         30000,
		frame_rate_D:         1000,
		picture_aspect_ratio: float32(w) / float32(h),
		p_data:               &data[0],
		line_stride_in_bytes: int32(stride),
	}

	s.pSend.Call(s.instance, uintptr(unsafe.Pointer(&frame)))
}

func (s *NDISender) Close() {
	if s != nil && s.instance != 0 {
		s.pSDestroy.Call(s.instance)
		s.instance = 0
	}
}

type NDIBridge struct {
	sync.Mutex
	sender            *NDISender
	standbyFrame      []byte
	standbyWidth      int
	standbyHeight     int
	lastLiveFrameTime time.Time
	stopStandby       chan struct{}
	standbyImagePath  string
}

func NewNDIBridge(ndiName string, standbyPath string) (*NDIBridge, error) {
	sender, err := NewNDISender(ndiName)
	if err != nil {
		return nil, err
	}

	b := &NDIBridge{
		sender:           sender,
		stopStandby:      make(chan struct{}),
		standbyImagePath: standbyPath,
	}

	b.UpdateStandbyFrame(standbyPath, 1280, 720)
	go b.runStandbyLoop()

	return b, nil
}

func (b *NDIBridge) UpdateStandbyFrame(path string, w, h int) {
	b.Lock()
	defer b.Unlock()

	b.standbyFrame = loadOrGenerateStandbyBGRA(path, w, h)
	b.standbyWidth = w
	b.standbyHeight = h
	b.standbyImagePath = path
}

func (b *NDIBridge) SetStandbyImage(path string) {
	b.UpdateStandbyFrame(path, 1280, 720)
}

func (b *NDIBridge) SendVideo(w, h int, bgra []byte, stride int) {
	b.SendFrame(w, h, bgra, stride)
}

func (b *NDIBridge) SendFrame(w, h int, bgra []byte, stride int) {
	b.Lock()
	defer b.Unlock()

	if b.sender != nil && len(bgra) > 0 {
		b.sender.SendVideo(w, h, bgra, stride)
		b.lastLiveFrameTime = time.Now()
	}
}

func (b *NDIBridge) runStandbyLoop() {
	ticker := time.NewTicker(33 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-b.stopStandby:
			return
		case <-ticker.C:
			b.Lock()
			timeSinceLive := time.Since(b.lastLiveFrameTime)
			if timeSinceLive > 500*time.Millisecond && len(b.standbyFrame) > 0 && b.sender != nil {
				b.sender.SendVideo(b.standbyWidth, b.standbyHeight, b.standbyFrame, b.standbyWidth*4)
			}
			b.Unlock()
		}
	}
}

func (b *NDIBridge) Close() {
	b.Lock()
	defer b.Unlock()

	select {
	case <-b.stopStandby:
	default:
		close(b.stopStandby)
	}

	if b.sender != nil {
		b.sender.Close()
		b.sender = nil
	}
}
