//go:build darwin && cgo

package main

/*
#cgo CFLAGS: -I/opt/homebrew/include -I/usr/local/include
#cgo LDFLAGS: -L/opt/homebrew/lib -L/usr/local/lib -lavcodec -lavutil -lswscale -framework VideoToolbox -framework CoreVideo -framework CoreMedia -framework CoreFoundation
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
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
} HWDecoderWrapper;

static HWDecoderWrapper* create_hw_decoder() {
    HWDecoderWrapper* dec = (HWDecoderWrapper*)calloc(1, sizeof(HWDecoderWrapper));
    if (!dec) return NULL;

    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_VP8);
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
    if (av_hwdevice_ctx_create(&hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) == 0) {
        dec->codec_ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
        av_buffer_unref(&hw_device_ctx);
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
    if (dec->hw_frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
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
*/
import "C"
import (
	"errors"
	"unsafe"
)

type CgoVideoDecoder struct {
	dec *C.HWDecoderWrapper
}

func NewVideoDecoder() (VideoDecoder, error) {
	dec := C.create_hw_decoder()
	if dec == nil {
		return nil, errors.New("failed to initialize Cgo VideoToolbox decoder")
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
