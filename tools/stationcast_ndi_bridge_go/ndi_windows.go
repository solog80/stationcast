//go:build windows && !cgo

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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

func findNDIDLL() (*syscall.LazyDLL, string) {
	var candidates []string

	dllFileNames := []string{
		"Processing.NDI.Lib.dll",
		"Processing.NDI.Lib.x64.dll",
		"Processing.NDI.Lib.x86.dll",
	}

	// 1. Environment variables set by NDI SDK / Runtime installers
	envVars := []string{
		"NDI_RUNTIME_DIR_V6",
		"NDI_RUNTIME_DIR_V5",
		"NDI_RUNTIME_DIR_V4",
		"NDI_RUNTIME_DIR_V3",
		"NDI_RUNTIME_DIR_V2",
	}
	for _, env := range envVars {
		if dir := os.Getenv(env); dir != "" {
			for _, fn := range dllFileNames {
				candidates = append(candidates, filepath.Join(dir, fn))
			}
		}
	}

	// 2. Query Windows Registry for vMix installation directory
	regKeys := []string{
		`HKLM\SOFTWARE\vMix`,
		`HKLM\SOFTWARE\WOW6432Node\vMix`,
		`HKCU\Software\vMix`,
	}
	for _, regKey := range regKeys {
		out, err := exec.Command("reg", "query", regKey, "/v", "InstallPath").Output()
		if err == nil {
			lines := strings.Split(string(out), "\r\n")
			for _, line := range lines {
				if strings.Contains(line, "REG_SZ") {
					parts := strings.Split(line, "REG_SZ")
					if len(parts) > 1 {
						dir := strings.TrimSpace(parts[1])
						for _, fn := range dllFileNames {
							candidates = append(candidates, filepath.Join(dir, `ndi\x64`, fn))
							candidates = append(candidates, filepath.Join(dir, `ndi\x86`, fn))
							candidates = append(candidates, filepath.Join(dir, `ndi`, fn))
							candidates = append(candidates, filepath.Join(dir, fn))
						}
					}
				}
			}
		}
	}

	// 3. Known installation directories (vMix, NDI Tools, NDI Runtime, OBS)
	programFilesDirs := []string{
		os.Getenv("ProgramFiles"),
		os.Getenv("ProgramFiles(x86)"),
		`C:\Program Files`,
		`C:\Program Files (x86)`,
	}

	subPaths := []string{
		// Exact vMix NDI location (with Processing.NDI.Lib.dll and Processing.NDI.Lib.x64.dll)
		`vMix\ndi\x64\Processing.NDI.Lib.dll`,
		`vMix\ndi\x64\Processing.NDI.Lib.x64.dll`,
		`vMix\ndi\x86\Processing.NDI.Lib.dll`,
		`vMix\ndi\x86\Processing.NDI.Lib.x86.dll`,
		`vMix\ndi\Processing.NDI.Lib.dll`,
		`vMix\ndi\Processing.NDI.Lib.x64.dll`,
		`vMix\Processing.NDI.Lib.dll`,
		`vMix\Processing.NDI.Lib.x64.dll`,
		`vMix\NDI\Processing.NDI.Lib.dll`,
		`vMix\NDI\Processing.NDI.Lib.x64.dll`,

		// Official NDI Tools / Runtime locations
		`NDI\NDI 6 Tools\Runtime\Processing.NDI.Lib.x64.dll`,
		`NDI\NDI 5 Tools\Runtime\Processing.NDI.Lib.x64.dll`,
		`NDI\NDI 4 Tools\Runtime\Processing.NDI.Lib.x64.dll`,
		`NDI\NDI Tools\Runtime\Processing.NDI.Lib.x64.dll`,

		`NDI\NDI 6 Tools\Runtime\Processing.NDI.Lib.dll`,
		`NDI\NDI 5 Tools\Runtime\Processing.NDI.Lib.dll`,
		`NDI\NDI 4 Tools\Runtime\Processing.NDI.Lib.dll`,
		`NDI\NDI Tools\Runtime\Processing.NDI.Lib.dll`,

		`NDI\NDI 6 Runtime\v6\Processing.NDI.Lib.x64.dll`,
		`NDI\NDI 5 Runtime\v5\Processing.NDI.Lib.x64.dll`,
		`NDI\NDI 4 Runtime\v4\Processing.NDI.Lib.x64.dll`,
		`NDI\NDI Runtime\Processing.NDI.Lib.x64.dll`,

		`NDI\NDI 6 Runtime\v6\Processing.NDI.Lib.dll`,
		`NDI\NDI 5 Runtime\v5\Processing.NDI.Lib.dll`,
		`NDI\NDI 4 Runtime\v4\Processing.NDI.Lib.dll`,
		`NDI\NDI Runtime\Processing.NDI.Lib.dll`,

		`NDI\NDI Tools\v6\Processing.NDI.Lib.x64.dll`,
		`NDI\NDI Tools\v5\Processing.NDI.Lib.x64.dll`,
		`NDI\NDI SDK for Windows\bin\x64\Processing.NDI.Lib.x64.dll`,
		`NDI\NDI SDK for Windows\bin\x64\Processing.NDI.Lib.dll`,

		// OBS Studio NDI plugin locations
		`obs-studio\data\obs-plugins\obs-ndi\Processing.NDI.Lib.x64.dll`,
		`obs-studio\data\obs-plugins\obs-ndi\Processing.NDI.Lib.dll`,
		`obs-studio\obs-plugins\64bit\Processing.NDI.Lib.x64.dll`,
		`obs-studio\obs-plugins\64bit\Processing.NDI.Lib.dll`,
	}

	for _, pf := range programFilesDirs {
		if pf == "" {
			continue
		}
		for _, sp := range subPaths {
			candidates = append(candidates, filepath.Join(pf, sp))
		}
	}

	// 4. Direct system/PATH fallbacks
	candidates = append(candidates, "Processing.NDI.Lib.dll")
	candidates = append(candidates, "Processing.NDI.Lib.x64.dll")
	candidates = append(candidates, "Processing.NDI.Lib.x86.dll")

	// Set DLL search directory so dependency resolution (other DLLs in same dir) succeeds
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	setDllDirProc := kernel32.NewProc("SetDllDirectoryW")

	for _, path := range candidates {
		dir := filepath.Dir(path)
		if dir != "." && dir != "" {
			if dirPtr, err := syscall.UTF16PtrFromString(dir); err == nil {
				_, _, _ = setDllDirProc.Call(uintptr(unsafe.Pointer(dirPtr)))
			}
		}

		dll := syscall.NewLazyDLL(path)
		if err := dll.Load(); err == nil {
			return dll, path
		}
	}

	return nil, ""
}

func NewNDISender(ndiName string) (*NDISender, error) {
	dll, loadedPath := findNDIDLL()
	if dll == nil {
		return nil, errors.New("failed to load NDI DLL (Processing.NDI.Lib.dll / Processing.NDI.Lib.x64.dll not found in System, vMix, or NDI Runtime paths)")
	}

	addLog(fmt.Sprintf("✅ NDI Windows DLL loaded from: %s", loadedPath))

	sender := &NDISender{
		dll:       dll,
		pInit:     dll.NewProc("NDIlib_initialize"),
		pDestroy:  dll.NewProc("NDIlib_destroy"),
		pCreate:   dll.NewProc("NDIlib_send_create"),
		pSDestroy: dll.NewProc("NDIlib_send_destroy"),
		pSend:     dll.NewProc("NDIlib_send_send_video_v2"),
	}

	if err := sender.pInit.Find(); err != nil {
		return nil, fmt.Errorf("NDIlib_initialize procedure not found in DLL: %v", err)
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
			if timeSinceLive > 1500*time.Millisecond && len(b.standbyFrame) > 0 && b.sender != nil {
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
