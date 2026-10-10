//go:build cgo

package main

/*
#cgo darwin CFLAGS: -I/opt/homebrew/include -I/usr/local/include
#cgo darwin LDFLAGS: -L/opt/homebrew/lib -L/usr/local/lib -lavcodec -lavutil -lswscale -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation
#cgo windows LDFLAGS: -lavcodec -lavutil -lswscale
#cgo linux LDFLAGS: -lavcodec -lavutil -lswscale
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libswscale/swscale.h>

typedef struct HWDecoderWrapper {
    AVCodecContext* codec_ctx;
    AVFrame* frame;
    AVFrame* hw_frame;
    AVPacket* pkt;
    struct SwsContext* sws_ctx;
    int width;
    int height;
    uint8_t* bgra_buf;
    int bgra_cap;
    char hw_device_name[64];
} HWDecoderWrapper;

static HWDecoderWrapper* create_hw_decoder(int is_h264) {
    HWDecoderWrapper* dec = (HWDecoderWrapper*)calloc(1, sizeof(HWDecoderWrapper));
    if (!dec) return NULL;

    enum AVCodecID codec_id = is_h264 ? AV_CODEC_ID_H264 : AV_CODEC_ID_VP8;
    const AVCodec* codec = avcodec_find_decoder(codec_id);
    if (!codec) {
        free(dec);
        return NULL;
    }

    dec->codec_ctx = avcodec_alloc_context3(codec);
    if (!dec->codec_ctx) {
        free(dec);
        return NULL;
    }

    AVBufferRef* hw_device_ctx = NULL;

    snprintf(dec->hw_device_name, sizeof(dec->hw_device_name), "software");

#if defined(__APPLE__)
    enum AVHWDeviceType hw_candidates[1] = { AV_HWDEVICE_TYPE_VIDEOTOOLBOX };
    const int hw_candidate_count = 1;
#elif defined(_WIN32)
    enum AVHWDeviceType hw_candidates[3] = { AV_HWDEVICE_TYPE_D3D11VA, AV_HWDEVICE_TYPE_DXVA2, AV_HWDEVICE_TYPE_CUDA };
    const int hw_candidate_count = 3;
#else
    enum AVHWDeviceType hw_candidates[1] = { AV_HWDEVICE_TYPE_VAAPI };
    const int hw_candidate_count = 1;
#endif

    for (int i = 0; i < hw_candidate_count; i++) {
        enum AVHWDeviceType t = hw_candidates[i];
        const char* tname = av_hwdevice_get_type_name(t);
        if (!tname) continue;
        if (av_hwdevice_ctx_create(&hw_device_ctx, t, NULL, NULL, 0) == 0) {
            dec->codec_ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
            av_buffer_unref(&hw_device_ctx);
            snprintf(dec->hw_device_name, sizeof(dec->hw_device_name), "%s", tname);
            break;
        }
    }

    if (avcodec_open2(dec->codec_ctx, codec, NULL) < 0) {
        avcodec_free_context(&dec->codec_ctx);
        free(dec);
        return NULL;
    }

    dec->frame = av_frame_alloc();
    dec->hw_frame = av_frame_alloc();
    dec->pkt = av_packet_alloc();
    return dec;
}

static void destroy_hw_decoder(HWDecoderWrapper* dec) {
    if (dec) {
        if (dec->sws_ctx) sws_freeContext(dec->sws_ctx);
        if (dec->frame) av_frame_free(&dec->frame);
        if (dec->hw_frame) av_frame_free(&dec->hw_frame);
        if (dec->pkt) av_packet_free(&dec->pkt);
        if (dec->codec_ctx) avcodec_free_context(&dec->codec_ctx);
        if (dec->bgra_buf) free(dec->bgra_buf);
        free(dec);
    }
}

static const char* get_hw_device_name(HWDecoderWrapper* dec) {
    if (!dec) return "uninitialized";
    return dec->hw_device_name;
}

typedef struct HWFrameOutput {
    int width;
    int height;
    uint8_t* bgra;
    int stride;
} HWFrameOutput;

static bool decode_hw_frame(HWDecoderWrapper* dec, const uint8_t* data, int data_len, HWFrameOutput* out) {
    if (!dec || !data || data_len <= 0 || !out) return false;

    dec->pkt->data = (uint8_t*)data;
    dec->pkt->size = data_len;

    if (avcodec_send_packet(dec->codec_ctx, dec->pkt) < 0) {
        return false;
    }

    if (avcodec_receive_frame(dec->codec_ctx, dec->hw_frame) < 0) {
        return false;
    }

    AVFrame* src_frame = dec->hw_frame;
    if (dec->hw_frame->format == AV_PIX_FMT_VIDEOTOOLBOX ||
        dec->hw_frame->format == AV_PIX_FMT_D3D11 ||
        dec->hw_frame->format == AV_PIX_FMT_DXVA2_VLD ||
        dec->hw_frame->format == AV_PIX_FMT_CUDA) {
        if (av_hwframe_transfer_data(dec->frame, dec->hw_frame, 0) < 0) {
            return false;
        }
        src_frame = dec->frame;
    }

    int w = src_frame->width;
    int h = src_frame->height;
    if (w <= 0 || h <= 0) return false;

    int needed = w * h * 4;
    if (dec->bgra_cap < needed) {
        if (dec->bgra_buf) free(dec->bgra_buf);
        dec->bgra_buf = (uint8_t*)malloc(needed);
        dec->bgra_cap = needed;
    }

    dec->sws_ctx = sws_getCachedContext(
        dec->sws_ctx,
        w, h, (enum AVPixelFormat)src_frame->format,
        w, h, AV_PIX_FMT_BGRA,
        SWS_FAST_BILINEAR, NULL, NULL, NULL
    );
    if (!dec->sws_ctx) return false;

    uint8_t* dst_data[1] = { dec->bgra_buf };
    int dst_stride[1] = { w * 4 };

    sws_scale(
        dec->sws_ctx,
        (const uint8_t* const*)src_frame->data, src_frame->linesize,
        0, h,
        dst_data, dst_stride
    );

    out->width = w;
    out->height = h;
    out->bgra = dec->bgra_buf;
    out->stride = w * 4;
    return true;
}

typedef struct AudioDecoderWrapper {
    AVCodecContext* codec_ctx;
    AVFrame* frame;
    AVPacket* pkt;
    float* float_buf;
    int float_cap;
} AudioDecoderWrapper;

static AudioDecoderWrapper* create_audio_decoder() {
    AudioDecoderWrapper* dec = (AudioDecoderWrapper*)calloc(1, sizeof(AudioDecoderWrapper));
    if (!dec) return NULL;

    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_OPUS);
    if (!codec) {
        free(dec);
        return NULL;
    }

    dec->codec_ctx = avcodec_alloc_context3(codec);
    if (!dec->codec_ctx) {
        free(dec);
        return NULL;
    }

    if (avcodec_open2(dec->codec_ctx, codec, NULL) < 0) {
        avcodec_free_context(&dec->codec_ctx);
        free(dec);
        return NULL;
    }

    dec->frame = av_frame_alloc();
    dec->pkt = av_packet_alloc();
    return dec;
}

static void destroy_audio_decoder(AudioDecoderWrapper* dec) {
    if (dec) {
        if (dec->frame) av_frame_free(&dec->frame);
        if (dec->pkt) av_packet_free(&dec->pkt);
        if (dec->codec_ctx) avcodec_free_context(&dec->codec_ctx);
        if (dec->float_buf) free(dec->float_buf);
        free(dec);
    }
}

typedef struct AudioFrameOutput {
    int sample_rate;
    int channels;
    int num_samples;
    float* data;
} AudioFrameOutput;

static bool decode_audio_frame(AudioDecoderWrapper* dec, const uint8_t* data, int data_len, AudioFrameOutput* out) {
    if (!dec || !data || data_len <= 0 || !out) return false;

    dec->pkt->data = (uint8_t*)data;
    dec->pkt->size = data_len;

    if (avcodec_send_packet(dec->codec_ctx, dec->pkt) < 0) {
        return false;
    }

    if (avcodec_receive_frame(dec->codec_ctx, dec->frame) < 0) {
        return false;
    }

    int sample_rate = dec->frame->sample_rate;
#if LIBAVUTIL_VERSION_INT >= AV_VERSION_INT(57, 28, 100)
    int channels = dec->frame->ch_layout.nb_channels;
#else
    int channels = dec->frame->channels;
#endif
    if (channels <= 0) channels = 2;
    int num_samples = dec->frame->nb_samples;

    if (sample_rate <= 0 || num_samples <= 0) return false;

    int total_floats = num_samples * channels;
    if (dec->float_cap < total_floats) {
        if (dec->float_buf) free(dec->float_buf);
        dec->float_buf = (float*)malloc(total_floats * sizeof(float));
        dec->float_cap = total_floats;
    }

    if (dec->frame->format == AV_SAMPLE_FMT_FLTP) {
        for (int ch = 0; ch < channels; ch++) {
            float* src_ch = (float*)dec->frame->extended_data[ch];
            float* dst_ch = dec->float_buf + (ch * num_samples);
            memcpy(dst_ch, src_ch, num_samples * sizeof(float));
        }
    } else if (dec->frame->format == AV_SAMPLE_FMT_FLT) {
        float* src = (float*)dec->frame->data[0];
        for (int i = 0; i < num_samples; i++) {
            for (int ch = 0; ch < channels; ch++) {
                dec->float_buf[ch * num_samples + i] = src[i * channels + ch];
            }
        }
    } else if (dec->frame->format == AV_SAMPLE_FMT_S16P) {
        for (int ch = 0; ch < channels; ch++) {
            int16_t* src_ch = (int16_t*)dec->frame->extended_data[ch];
            float* dst_ch = dec->float_buf + (ch * num_samples);
            for (int i = 0; i < num_samples; i++) {
                dst_ch[i] = (float)src_ch[i] / 32768.0f;
            }
        }
    } else if (dec->frame->format == AV_SAMPLE_FMT_S16) {
        int16_t* src = (int16_t*)dec->frame->data[0];
        for (int i = 0; i < num_samples; i++) {
            for (int ch = 0; ch < channels; ch++) {
                dec->float_buf[ch * num_samples + i] = (float)src[i * channels + ch] / 32768.0f;
            }
        }
    } else {
        return false;
    }

    out->sample_rate = sample_rate;
    out->channels = channels;
    out->num_samples = num_samples;
    out->data = dec->float_buf;

    return true;
}
*/
import "C"
import (
	"errors"
	"strings"
	"unsafe"
)

type CgoVideoDecoder struct {
	dec *C.HWDecoderWrapper
}

func NewVideoDecoder(mimeType string) (VideoDecoder, error) {
	isH264 := 0
	if strings.Contains(strings.ToLower(mimeType), "h264") {
		isH264 = 1
	}
	dec := C.create_hw_decoder(C.int(isH264))
	if dec == nil {
		return nil, errors.New("failed to initialize Cgo GPU hardware decoder")
	}
	return &CgoVideoDecoder{dec: dec}, nil
}

func (d *CgoVideoDecoder) Decode(payload []byte) (int, int, []byte, int, error) {
	if d.dec == nil || len(payload) == 0 {
		return 0, 0, nil, 0, errors.New("invalid decoder state or empty payload")
	}

	var out C.HWFrameOutput
	ok := C.decode_hw_frame(d.dec, (*C.uint8_t)(unsafe.Pointer(&payload[0])), C.int(len(payload)), &out)
	if !bool(ok) {
		return 0, 0, nil, 0, errors.New("decoding frame failed")
	}

	w := int(out.width)
	h := int(out.height)
	stride := int(out.stride)
	bgra := C.GoBytes(unsafe.Pointer(out.bgra), C.int(w*h*4))
	return w, h, bgra, stride, nil
}

func (d *CgoVideoDecoder) Close() {
	if d.dec != nil {
		C.destroy_hw_decoder(d.dec)
		d.dec = nil
	}
}

func (d *CgoVideoDecoder) HWDeviceName() string {
	if d.dec == nil {
		return "uninitialized"
	}
	return C.GoString(C.get_hw_device_name(d.dec))
}

type CgoAudioDecoder struct {
	dec *C.AudioDecoderWrapper
}

func NewAudioDecoder() (AudioDecoder, error) {
	dec := C.create_audio_decoder()
	if dec == nil {
		return nil, errors.New("failed to initialize Cgo Opus Audio Decoder")
	}
	return &CgoAudioDecoder{dec: dec}, nil
}

func (d *CgoAudioDecoder) Decode(payload []byte) (int, int, int, []float32, error) {
	if d.dec == nil || len(payload) == 0 {
		return 0, 0, 0, nil, errors.New("invalid decoder state or empty payload")
	}

	var out C.AudioFrameOutput
	ok := C.decode_audio_frame(d.dec, (*C.uint8_t)(unsafe.Pointer(&payload[0])), C.int(len(payload)), &out)
	if !bool(ok) {
		return 0, 0, 0, nil, errors.New("decoding audio frame failed")
	}

	sr := int(out.sample_rate)
	ch := int(out.channels)
	ns := int(out.num_samples)
	total := ns * ch
	pcm := make([]float32, total)
	C.memcpy(unsafe.Pointer(&pcm[0]), unsafe.Pointer(out.data), C.size_t(total*4))

	return sr, ch, ns, pcm, nil
}

func (d *CgoAudioDecoder) Close() {
	if d.dec != nil {
		C.destroy_audio_decoder(d.dec)
		d.dec = nil
	}
}
