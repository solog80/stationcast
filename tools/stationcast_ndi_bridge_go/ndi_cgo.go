//go:build cgo && !windows

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

typedef struct NDIlib_audio_frame_v2_t {
    int sample_rate;
    int no_channels;
    int no_samples;
    long long timecode;
    float* p_data;
    int channel_stride_in_bytes;
    const char* p_metadata;
    long long timestamp;
} NDIlib_audio_frame_v2_t;

typedef void* NDIlib_send_instance_t;

typedef bool (*fn_NDIlib_initialize)(void);
typedef void (*fn_NDIlib_destroy)(void);
typedef NDIlib_send_instance_t (*fn_NDIlib_send_create)(const NDIlib_send_create_t* p_create_settings);
typedef void (*fn_NDIlib_send_destroy)(NDIlib_send_instance_t p_instance);
typedef void (*fn_NDIlib_send_send_video_v2)(NDIlib_send_instance_t p_instance, const NDIlib_video_frame_v2_t* p_video_data);
typedef void (*fn_NDIlib_send_send_audio_v2)(NDIlib_send_instance_t p_instance, const NDIlib_audio_frame_v2_t* p_audio_data);

static fn_NDIlib_initialize p_initialize = NULL;
static fn_NDIlib_destroy p_destroy = NULL;
static fn_NDIlib_send_create p_send_create = NULL;
static fn_NDIlib_send_destroy p_send_destroy = NULL;
static fn_NDIlib_send_send_video_v2 p_send_send_video_v2 = NULL;
static fn_NDIlib_send_send_audio_v2 p_send_send_audio_v2 = NULL;

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
    p_send_send_audio_v2 = (fn_NDIlib_send_send_audio_v2)dlsym(handle, "NDIlib_send_send_audio_v2");

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
    settings.clock_video = false;
    settings.clock_audio = false;
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

static void send_ndi_audio(NDIlib_send_instance_t instance, int sample_rate, int channels, int num_samples, float* p_data) {
    if (!p_send_send_audio_v2 || !instance || !p_data) return;
    NDIlib_audio_frame_v2_t frame;
    frame.sample_rate = sample_rate;
    frame.no_channels = channels;
    frame.no_samples = num_samples;
    frame.timecode = 0;
    frame.p_data = p_data;
    frame.channel_stride_in_bytes = num_samples * sizeof(float);
    frame.p_metadata = NULL;
    frame.timestamp = 0;

    p_send_send_audio_v2(instance, &frame);
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
	"sync"
	"time"
	"unsafe"
)

// Playout buffer: decoded frames are queued and emitted in order at a steady rate,
// so network stalls (e.g. TCP head-of-line blocking) and bursts render as smooth
// motion instead of judder / ghosting.
type playoutFrame struct {
	bgra   []byte
	width  int
	height int
	stride int
}

const playoutMaxFrames = 32 // hard cap, bounds latency and memory

type NDIBridge struct {
	sync.Mutex
	instance          C.NDIlib_send_instance_t
	standbyCData      *C.uint8_t
	standbyWidth      int
	standbyHeight     int
	liveCData         *C.uint8_t
	liveCDataCap      int
	liveWidth         int
	liveHeight        int
	liveStride        int
	lastLiveFrameTime time.Time
	stopStandby       chan struct{}
	standbyImagePath  string
	isLiveState       bool
	playout           []playoutFrame
	playoutStarted    bool
	lastSent          playoutFrame
	outFrames         int64
}

// OutFrames is the number of frames actually emitted to NDI (i.e. the real output rate source).
func (b *NDIBridge) OutFrames() int64 {
	b.Lock()
	defer b.Unlock()
	return b.outFrames
}

func NewNDIBridge(ndiName string, standbyPath string) (*NDIBridge, error) {
	libPaths := []string{
		"/usr/local/lib/libndi.dylib",
		"/opt/homebrew/lib/libndi.dylib",
		"libndi.dylib",
		"libndi.so",
	}

	loaded := false
	for _, path := range libPaths {
		cPath := C.CString(path)
		ok := C.load_ndi_lib(cPath)
		C.free(unsafe.Pointer(cPath))
		if ok {
			addLog(fmt.Sprintf("✅ NDI Library successfully loaded from: %s", path))
			loaded = true
			break
		}
	}

	if !loaded {
		return nil, errors.New("failed to load libndi dynamic library")
	}

	cName := C.CString(ndiName)
	defer C.free(unsafe.Pointer(cName))

	inst := C.create_ndi_send(cName)
	if inst == nil {
		return nil, errors.New("failed to create NDI send instance")
	}

	b := &NDIBridge{
		instance:         inst,
		stopStandby:      make(chan struct{}),
		standbyImagePath: standbyPath,
	}

	b.UpdateStandbyFrame(standbyPath, 1280, 720)
	go b.runStandbyLoop()

	return b, nil
}

func (b *NDIBridge) SetLiveState(isLive bool) {
	b.Lock()
	defer b.Unlock()
	b.isLiveState = isLive
	if !isLive {
		b.playout = nil
		b.playoutStarted = false
	}
}

func (b *NDIBridge) UpdateStandbyFrame(path string, w, h int) {
	b.Lock()
	defer b.Unlock()

	bgra := loadOrGenerateStandbyBGRA(path, w, h)
	if len(bgra) == 0 {
		return
	}

	if b.standbyCData != nil {
		C.free(unsafe.Pointer(b.standbyCData))
	}

	b.standbyWidth = w
	b.standbyHeight = h
	b.standbyCData = (*C.uint8_t)(C.CBytes(bgra))
	b.standbyImagePath = path
}

func (b *NDIBridge) SetStandbyImage(path string) {
	b.UpdateStandbyFrame(path, 1280, 720)
}

func (b *NDIBridge) SendVideo(w, h int, bgra []byte, stride int) {
	b.SendFrame(w, h, bgra, stride)
}

func (b *NDIBridge) SendAudio(sampleRate, channels, numSamples int, data []float32) {
	if len(data) == 0 {
		return
	}
	b.Lock()
	inst := b.instance
	b.Unlock()

	if inst != nil {
		C.send_ndi_audio(inst, C.int(sampleRate), C.int(channels), C.int(numSamples), (*C.float)(unsafe.Pointer(&data[0])))
	}
}

func (b *NDIBridge) SendFrame(w, h int, bgra []byte, stride int) {
	b.Lock()
	defer b.Unlock()

	if b.instance == nil || len(bgra) == 0 {
		return
	}
	b.isLiveState = true
	// The decoder hands us a freshly-allocated frame, so queue it without copying.
	b.playout = append(b.playout, playoutFrame{bgra: bgra, width: w, height: h, stride: stride})
	if len(b.playout) > playoutMaxFrames {
		b.playout = b.playout[1:] // drop oldest to bound latency
	}
	b.lastLiveFrameTime = time.Now()
}

func (b *NDIBridge) runStandbyLoop() {
	ticker := time.NewTicker(33 * time.Millisecond) // ~30 FPS steady output
	defer ticker.Stop()

	for {
		select {
		case <-b.stopStandby:
			return
		case <-ticker.C:
			b.Lock()
			if b.instance != nil {
				if b.isLiveState {
					if (b.playoutStarted || len(b.playout) >= currentPlayoutFrames()) && len(b.playout) > 0 {
						b.playoutStarted = true
						f := b.playout[0]
						b.playout = b.playout[1:]
						b.lastSent = f
						C.send_ndi_video(b.instance, C.int(f.width), C.int(f.height), (*C.uint8_t)(unsafe.Pointer(&f.bgra[0])), C.int(f.stride))
						b.outFrames++
						b.lastLiveFrameTime = time.Now()
					} else if len(b.lastSent.bgra) > 0 {
						// Buffer underrun: hold the last frame (never color bars mid-broadcast)
						C.send_ndi_video(b.instance, C.int(b.lastSent.width), C.int(b.lastSent.height), (*C.uint8_t)(unsafe.Pointer(&b.lastSent.bgra[0])), C.int(b.lastSent.stride))
					}
				} else if b.standbyCData != nil {
					// Idle / broadcast ended: SMPTE color bars
					C.send_ndi_video(b.instance, C.int(b.standbyWidth), C.int(b.standbyHeight), b.standbyCData, C.int(b.standbyWidth*4))
				}
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

	if b.standbyCData != nil {
		C.free(unsafe.Pointer(b.standbyCData))
		b.standbyCData = nil
	}

	if b.liveCData != nil {
		C.free(unsafe.Pointer(b.liveCData))
		b.liveCData = nil
	}

	if b.instance != nil {
		C.destroy_ndi_send(b.instance)
		b.instance = nil
	}
}
