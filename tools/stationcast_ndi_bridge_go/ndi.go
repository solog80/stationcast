package main

/*
#cgo LDFLAGS: -ldl
#include <stdbool.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef enum NDIlib_FourCC_video_type_e {
    NDIlib_FourCC_video_type_UYVY = 0x59565955,
    NDIlib_FourCC_video_type_BGRA = 0x41524742,
    NDIlib_FourCC_video_type_BGRX = 0x58524742,
    NDIlib_FourCC_video_type_RGBA = 0x41474252,
    NDIlib_FourCC_video_type_RGBX = 0x58474252,
} NDIlib_FourCC_video_type_e;

typedef struct NDIlib_send_create_t {
    const char* p_ndi_name;
    const char* p_groups;
    bool clock_video;
    bool clock_audio;
} NDIlib_send_create_t;

typedef struct NDIlib_video_frame_v2_t {
    int xres;
    int yres;
    NDIlib_FourCC_video_type_e FourCC;
    int frame_rate_N;
    int frame_rate_D;
    float picture_aspect_ratio;
    int frame_format_type;
    long long timecode;
    uint8_t* p_data;
    int line_stride_in_bytes;
    const char* p_metadata;
    long long timestamp;
} NDIlib_video_frame_v2_t;

typedef void* NDIlib_send_instance_t;

typedef bool (*fn_NDIlib_initialize)(void);
typedef void (*fn_NDIlib_destroy)(void);
typedef NDIlib_send_instance_t (*fn_NDIlib_send_create)(const NDIlib_send_create_t* p_create_settings);
typedef void (*fn_NDIlib_send_destroy)(NDIlib_send_instance_t p_instance);
typedef void (*fn_NDIlib_send_send_video_v2)(NDIlib_send_instance_t p_instance, const NDIlib_video_frame_v2_t* p_video_data);

static fn_NDIlib_initialize p_initialize = NULL;
static fn_NDIlib_destroy p_destroy = NULL;
static fn_NDIlib_send_create p_send_create = NULL;
static fn_NDIlib_send_destroy p_send_destroy = NULL;
static fn_NDIlib_send_send_video_v2 p_send_send_video_v2 = NULL;

static bool load_ndi_lib(const char* lib_path) {
    void* handle = dlopen(lib_path, RTLD_LAZY | RTLD_GLOBAL);
    if (!handle) {
        printf("[Cgo NDI] dlopen(%s) failed: %s\n", lib_path, dlerror());
        return false;
    }

    p_initialize = (fn_NDIlib_initialize)dlsym(handle, "NDIlib_initialize");
    p_destroy = (fn_NDIlib_destroy)dlsym(handle, "NDIlib_destroy");
    p_send_create = (fn_NDIlib_send_create)dlsym(handle, "NDIlib_send_create");
    p_send_destroy = (fn_NDIlib_send_destroy)dlsym(handle, "NDIlib_send_destroy");
    p_send_send_video_v2 = (fn_NDIlib_send_send_video_v2)dlsym(handle, "NDIlib_send_send_video_v2");

    if (!p_initialize || !p_send_create || !p_send_send_video_v2) {
        printf("[Cgo NDI] Could not resolve NDI direct symbols in %s\n", lib_path);
        return false;
    }

    return p_initialize();
}

static NDIlib_send_instance_t create_ndi_send(const char* name) {
    if (!p_send_create) return NULL;
    NDIlib_send_create_t settings;
    settings.p_ndi_name = name;
    settings.p_groups = NULL;
    settings.clock_video = true;
    settings.clock_audio = true;
    return p_send_create(&settings);
}

static void send_ndi_video(NDIlib_send_instance_t instance, int w, int h, uint8_t* data, int stride) {
    if (!p_send_send_video_v2 || !instance || !data) return;
    NDIlib_video_frame_v2_t frame;
    frame.xres = w;
    frame.yres = h;
    frame.FourCC = NDIlib_FourCC_video_type_BGRA;
    frame.frame_rate_N = 30000;
    frame.frame_rate_D = 1000;
    frame.picture_aspect_ratio = (float)w / (float)h;
    frame.frame_format_type = 0;
    frame.timecode = 0;
    frame.p_data = data;
    frame.line_stride_in_bytes = stride;
    frame.p_metadata = NULL;
    frame.timestamp = 0;

    p_send_send_video_v2(instance, &frame);
}

static void destroy_ndi_send(NDIlib_send_instance_t instance) {
    if (p_send_destroy && instance) {
        p_send_destroy(instance);
    }
}
*/
import "C"
import (
	"errors"
	"fmt"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"os"
	"sync"
	"time"
	"unsafe"

	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"
)

type NDIBridge struct {
	sync.Mutex
	instance          C.NDIlib_send_instance_t
	standbyCData      *C.uint8_t
	standbyWidth      int
	standbyHeight     int
	liveCData         *C.uint8_t
	liveCDataCap      int
	lastLiveFrameTime time.Time
	stopStandby       chan struct{}
	standbyImagePath  string
}

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
		"/Users/solomacbookair/Downloads/SMPTE_Color_Bars.svg.webp",
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

	dstImg := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.BiLinear.Scale(dstImg, dstImg.Bounds(), srcImg, srcImg.Bounds(), draw.Over, nil)

	bgraBuf := make([]byte, w*h*4)
	pix := dstImg.Pix
	for i := 0; i < len(pix); i += 4 {
		bgraBuf[i] = pix[i+2]   // B
		bgraBuf[i+1] = pix[i+1] // G
		bgraBuf[i+2] = pix[i]   // R
		bgraBuf[i+3] = pix[i+3] // A
	}

	addLog(fmt.Sprintf("🎨 Loaded standby color bars image '%s' (%s format) resized to %dx%d NDI output.", loadedPath, fmtName, w, h))
	return bgraBuf
}

func NewNDIBridge(name string, standbyImagePath string) (*NDIBridge, error) {
	libPaths := []string{
		"/usr/local/lib/libndi.dylib",
		"/Library/NDI SDK for macOS/lib/macOS/libndi.dylib",
		"libndi.dylib",
	}

	loaded := false
	for _, p := range libPaths {
		cPath := C.CString(p)
		if C.load_ndi_lib(cPath) {
			loaded = true
			C.free(unsafe.Pointer(cPath))
			break
		}
		C.free(unsafe.Pointer(cPath))
	}

	if !loaded {
		return nil, errors.New("failed to load libndi.dylib. Ensure NDI runtime is installed")
	}

	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))

	inst := C.create_ndi_send(cName)
	if inst == nil {
		return nil, errors.New("failed to create NDI send instance")
	}

	bridge := &NDIBridge{
		instance:    inst,
		stopStandby: make(chan struct{}),
	}

	bridge.SetStandbyImage(standbyImagePath)
	go bridge.runStandbyLoop()

	return bridge, nil
}

func (n *NDIBridge) SetStandbyImage(path string) {
	n.Lock()
	defer n.Unlock()

	w, h := 1280, 720
	bgra := loadOrGenerateStandbyBGRA(path, w, h)
	n.standbyImagePath = path

	if n.standbyCData != nil {
		C.free(unsafe.Pointer(n.standbyCData))
	}
	n.standbyCData = (*C.uint8_t)(C.malloc(C.size_t(len(bgra))))
	C.memcpy(unsafe.Pointer(n.standbyCData), unsafe.Pointer(&bgra[0]), C.size_t(len(bgra)))
	n.standbyWidth = w
	n.standbyHeight = h
}

func (n *NDIBridge) runStandbyLoop() {
	ticker := time.NewTicker(33 * time.Millisecond) // ~30 FPS
	defer ticker.Stop()

	for {
		select {
		case <-n.stopStandby:
			return
		case <-ticker.C:
			n.Lock()
			if n.instance != nil && n.standbyCData != nil && time.Since(n.lastLiveFrameTime) > 500*time.Millisecond {
				C.send_ndi_video(n.instance, C.int(n.standbyWidth), C.int(n.standbyHeight), n.standbyCData, C.int(n.standbyWidth*4))
			}
			n.Unlock()
		}
	}
}

func (n *NDIBridge) SendVideo(width, height int, rgba []byte, stride int) {
	n.Lock()
	defer n.Unlock()

	if n.instance == nil || len(rgba) == 0 {
		return
	}

	needed := len(rgba)
	if n.liveCDataCap < needed {
		if n.liveCData != nil {
			C.free(unsafe.Pointer(n.liveCData))
		}
		n.liveCData = (*C.uint8_t)(C.malloc(C.size_t(needed)))
		n.liveCDataCap = needed
	}

	C.memcpy(unsafe.Pointer(n.liveCData), unsafe.Pointer(&rgba[0]), C.size_t(needed))

	n.lastLiveFrameTime = time.Now()
	C.send_ndi_video(n.instance, C.int(width), C.int(height), n.liveCData, C.int(stride))
}

func (n *NDIBridge) Close() {
	n.Lock()
	if n.stopStandby != nil {
		close(n.stopStandby)
		n.stopStandby = nil
	}
	inst := n.instance
	n.instance = nil

	if n.standbyCData != nil {
		C.free(unsafe.Pointer(n.standbyCData))
		n.standbyCData = nil
	}
	if n.liveCData != nil {
		C.free(unsafe.Pointer(n.liveCData))
		n.liveCData = nil
	}
	n.Unlock()

	if inst != nil {
		C.destroy_ndi_send(inst)
	}
}
