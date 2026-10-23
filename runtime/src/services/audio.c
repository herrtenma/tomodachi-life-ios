// audren:u — the audio renderer (the Switch's DSP mixer), done on the host.
// RequestUpdate parses the game's state blocks (layouts per Ryujinx.Audio, REV15) and keeps the
// renderer state; a renderer thread runs one 240-sample frame per 5 ms: voices (ADPCM / PCM) are
// decoded, resampled, filtered and ramped into mix buffers through splitters, submixes run their
// effects and mix into the final mix, and the device sink downmixes 5.1 to stereo for CoreAudio
// (audio_out.c). The thread signals the renderer event after each frame, so the game's audio
// thread runs on the output device's clock like on hardware.
// Effects: buffer mix, aux send/return (the game's own CPU effects), biquad, delay, reverb and 3D
// reverb, limiter and compressor are processed (algorithms from Ryujinx.Audio). Stopped
// voices are faded out by depop (their last mixed sample decays into the mix buffers).
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "audio_out.h"
#include "ipc.h"

extern const ServiceDef svc_audren;

typedef struct {
    uint32_t sample_rate, sample_count, mix_buffer_count, submix_count, voice_count, sink_count,
        effect_count, perf_frame_count;
    uint8_t voice_drop, pad, device, exec_mode;
    uint32_t splitter_count, splitter_dest_count, external_ctx_size, revision;
} RendererParams;   // 0x34

#define MIXBUF_MAX 24
#define UNUSED_MIX 0x7fffffff
#define UNUSED_SPLITTER 0xffffffffu
#define FINAL_MIX 0
enum { FMT_PCM8 = 1, FMT_PCM16 = 2, FMT_FLOAT = 5, FMT_ADPCM = 6 };
enum { PS_STARTED, PS_STOPPED, PS_STOPPING, PS_PAUSED };             // server play states
enum { FX_BUFMIX = 1, FX_AUX, FX_DELAY, FX_REVERB, FX_REVERB3D, FX_BIQUAD, FX_LIMITER, FX_CAPTURE, FX_COMPRESSOR };
enum { DEC_RESET_PLAYED_ON_LOOP = 1, DEC_SKIP_SRC = 2 };

typedef struct { uint8_t enable; float num[3], den[2]; } Biquad;
typedef struct { float s0, s1; } BqState;

typedef struct {
    uint64_t addr, size, ctx;
    uint32_t start, end, loop_start, loop_end;
    int32_t loop_count;
    uint8_t loop, eos, to_dsp;       // to_dsp: already handed to the DSP (Ryujinx IsSendToAudioProcessor)
} WaveBuf;

typedef struct {
    int in_use, is_new, was_playing, drop, ds_unmapped, buf_unmapped, index, starving;
    uint8_t fmt, play, prev_play, flush;
    uint16_t decoding;
    uint32_t rate, chans, wb_count, wb_index_param;
    float pitch, vol, prev_vol;
    Biquad bq[2];
    int bq_was_on[2];
    uint64_t ds_addr, ds_size;
    int32_t mix_id, res[6];
    uint32_t splitter_id;
    WaveBuf wb[4];
    // DSP progress (one copy for all channels: they advance together)
    int valid[4];
    uint32_t wb_index, consumed;
    int32_t offset, loop_count;
    uint64_t played;
    int16_t pred_scale, h0, h1;      // ADPCM decoder state
    float frac, hist[6][4];          // resampler position and history per channel
    BqState bqs[6][2];
} Voice;

typedef struct { float mix[MIXBUF_MAX], prev[MIXBUF_MAX]; int used; } ChanRes;

typedef struct {
    int used;
    float vol;
    uint32_t rate, buf_count, off;
    int32_t id, dest_mix;
    uint32_t dest_spl;
    float mat[MIXBUF_MAX * MIXBUF_MAX];   // [source buffer][destination buffer]
} Mix;

typedef struct {
    uint8_t type, enabled;
    int32_t mix_id;
    uint32_t order;
    uint64_t base, size;
    uint8_t p[0xA0];
    BqState bqs[6];
    float *line[6], lp[6];               // delay lines
    uint32_t line_len, line_pos;
    void *rv;                            // reverb / 3D reverb state
    uint8_t rv_p[0xA0];                  // parameters the reverb state was computed from
    double e_in, e_out;                  // NXRT_AUDIOLOG: signal energy into / out of the effect
} Effect;

typedef struct {
    int32_t dest;
    int used, need_update, bq_was_on[2];
    float vol[MIXBUF_MAX], prev[MIXBUF_MAX];
    Biquad bq[2];
    BqState bqs[6][2];
} SplDest;

typedef struct { int32_t *dests; int count; } Splitter;

typedef struct { uint8_t type, used, downmix_on; uint32_t inputs; uint8_t in[6]; float downmix[4]; } Sink;

typedef struct { uint64_t addr, size; int attached; } Pool;

typedef struct {
    RendererParams p;
    KEvent *ev;
    uint32_t ev_handle;
    int started, mix_count, pool_count, has_device;
    uint32_t n;                          // samples per frame (240)
    pthread_mutex_t lock;
    Voice *voices;
    ChanRes *res;
    Mix *mixes;
    Effect *effects;
    Splitter *spl;
    SplDest *dst;
    Sink *sinks;
    Pool *pools;
    float *buf;                          // mix buffers, then 6 voice channel buffers
    float *depop;                        // per mix buffer: decaying tail of stopped voices
    float *last;                         // [voice][channel][mix buffer]: last sample mixed there
    float *tmp, *out;
    uint64_t frames, updates, render_ns;
    float peak;
    uint32_t active_voices;
} Renderer;

static int g_alog, g_vlog;   // NXRT_AUDIOLOG stats, NXRT_VOICELOG per-voice events
#define VLOG(v, fmt, ...) do { if (g_vlog) nx_log("voice %d: " fmt, (v)->index, ##__VA_ARGS__); } while (0)
#define ALOG(...) do { if (g_alog) nx_log(__VA_ARGS__); } while (0)

static void ok(SvcObj *o, IpcReq *rq, IpcResp *rs) {}

// ---- guest memory checks: the DSP only reads memory inside attached pools ----------------------

static int pool_ok(Renderer *r, uint64_t addr, uint64_t size) {
    if (!addr) return 0;
    for (int i = 0; i < r->pool_count; i++) {
        Pool *p = &r->pools[i];
        if (p->attached && addr >= p->addr && addr + size <= p->addr + p->size) return 1;
    }
    return 0;
}

// ---- state update (RequestUpdate) ----------------------------------------------------------------

static void voice_reset_dsp(Voice *v) {
    memset(v->valid, 0, sizeof v->valid);
    v->wb_index = v->consumed = 0;
    v->offset = v->loop_count = 0;
    v->played = 0;
    v->pred_scale = v->h0 = v->h1 = 0;
    v->frac = 0;
    memset(v->hist, 0, sizeof v->hist);
    memset(v->bqs, 0, sizeof v->bqs);
}

static void voice_init(Voice *v) {
    memset(v, 0, sizeof *v);
    v->play = PS_STOPPED;
    v->mix_id = UNUSED_MIX;
    v->splitter_id = UNUSED_SPLITTER;
    for (int i = 0; i < 4; i++) v->wb[i].to_dsp = 1;
}

static uint64_t adpcm_size(uint64_t samples) {
    uint64_t frames = samples / 14, extra = samples % 14 ? (samples % 14) / 2 + 1 + (samples % 2) : 0;
    return frames * 8 + extra;
}

static int wb_offsets_ok(uint8_t fmt, uint32_t chans, uint64_t size, uint64_t s, uint64_t e) {
    uint64_t c = chans ? chans : 1;
    switch (fmt) {
    case FMT_PCM8: return s * c <= size && e * c <= size;
    case FMT_PCM16: return s * 2 * c <= size && e * 2 * c <= size;
    case FMT_FLOAT: return s * 4 * c <= size && e * 4 * c <= size;
    case FMT_ADPCM: return adpcm_size(s) <= size && adpcm_size(e) <= size;
    default: return 0;
    }
}

static void read_biquads(Biquad *b, const uint8_t *src) {   // 2 x BiquadFilterParameter2 (0x18)
    for (int i = 0; i < 2; i++, src += 0x18) {
        b[i].enable = src[0];
        memcpy(b[i].num, src + 4, 12);
        memcpy(b[i].den, src + 16, 8);
    }
}

// VoiceInParameter2 (0x188) -> state; writes VoiceOutStatus (0x10).
static void update_voice(Renderer *r, Voice *v, const uint8_t *in, uint8_t *out) {
    uint8_t is_new = in[8], play = in[0xA];
    int index = v->index;
    if (is_new) voice_init(v);
    v->index = index;
    if (is_new) VLOG(v, "new: fmt %u rate %u ch %u mix %d splitter %d", in[0xB], *(uint32_t *)(in + 0xC),
                     *(uint32_t *)(in + 0x18), *(int32_t *)(in + 0x70), *(int32_t *)(in + 0x74));
    v->in_use = 1;
    uint8_t old = v->play;
    v->prev_play = old;
    if (play == 0) v->play = PS_STARTED;
    else if (play == 1) { if (old != PS_STOPPED) v->play = PS_STOPPING; }
    else if (play == 2) v->play = PS_PAUSED;
    if (v->play != old) VLOG(v, "play %s -> %s (consumed %u, played %llu)", (const char *[]){"started", "stopped", "stopping", "paused"}[old],
                             (const char *[]){"started", "stopped", "stopping", "paused"}[v->play], v->consumed, (unsigned long long)v->played);
    v->fmt = in[0xB];
    memcpy(&v->rate, in + 0xC, 4);
    memcpy(&v->chans, in + 0x18, 4);
    if (v->chans > 6) v->chans = 6;
    memcpy(&v->pitch, in + 0x1C, 4);
    memcpy(&v->vol, in + 0x20, 4);
    read_biquads(v->bq, in + 0x24);
    memcpy(&v->wb_count, in + 0x54, 4);
    memcpy(&v->wb_index_param, in + 0x58, 4);
    v->flush += in[0x171];
    memcpy(&v->mix_id, in + 0x70, 4);
    memcpy(&v->splitter_id, in + 0x74, 4);
    memcpy(v->res, in + 0x158, 24);
    memcpy(&v->decoding, in + 0x174, 2);
    if (in[0x170]) v->drop = 0;
    uint64_t ds_addr, ds_size;
    memcpy(&ds_addr, in + 0x60, 8);
    memcpy(&ds_size, in + 0x68, 8);
    if (ds_addr != v->ds_addr || ds_size != v->ds_size || v->ds_unmapped) {
        v->ds_addr = ds_addr;
        v->ds_size = ds_size;
        v->ds_unmapped = ds_addr && !pool_ok(r, ds_addr, ds_size);
    }
    if (is_new) memset(v->valid, 0, sizeof v->valid);
    for (int i = 0; i < 4; i++) {
        const uint8_t *w = in + 0x78 + i * 0x38;
        WaveBuf *b = &v->wb[i];
        if (!v->valid[i] && b->to_dsp && b->addr) b->addr = 0;
        if (w[0x1A] && !v->buf_unmapped) continue;          // SentToServer: nothing new in this slot
        uint64_t addr, size;
        uint32_t s, e;
        memcpy(&addr, w, 8);
        memcpy(&size, w + 8, 8);
        memcpy(&s, w + 0x10, 4);
        memcpy(&e, w + 0x14, 4);
        if (!wb_offsets_ok(v->fmt, v->chans, size, s, e)) {
            VLOG(v, "wave buffer slot %d REJECTED (offsets %u-%u, size %#llx, fmt %u)", i, s, e, (unsigned long long)size, v->fmt);
            continue;
        }
        b->to_dsp = 0;
        b->addr = addr;
        b->size = size;
        b->start = s;
        b->end = e;
        b->loop = w[0x18];
        b->eos = w[0x19];
        memcpy(&b->loop_count, w + 0x1C, 4);
        memcpy(&b->ctx, w + 0x20, 8);
        memcpy(&b->loop_start, w + 0x30, 4);
        memcpy(&b->loop_end, w + 0x34, 4);
        v->buf_unmapped = !pool_ok(r, addr, size);
        if (v->fmt == FMT_ADPCM && b->ctx) {
            if (!pool_ok(r, b->ctx, 6)) v->buf_unmapped = 1;
        } else b->ctx = 0;
        if (v->buf_unmapped)
            ALOG("audren: wave buffer %#llx+%#llx outside attached pools", (unsigned long long)addr,
                 (unsigned long long)size);
        VLOG(v, "wave buffer slot %d: %#llx+%#llx samples %u-%u%s%s%s", i, (unsigned long long)addr, (unsigned long long)size, s, e,
             b->eos ? " END-OF-STREAM" : "", b->loop ? " loop" : "", v->buf_unmapped ? " OUTSIDE POOLS (voice skipped)" : "");
    }
    if (!v->rate) v->rate = 48000;
    memset(out, 0, 0x10);
    if (is_new || v->is_new) { v->is_new = 1; return; }
    memcpy(out, &v->played, 8);
    memcpy(out + 8, &v->consumed, 4);
    out[12] = (uint8_t)v->drop;
}

// MixParameter (0x930)
static void update_mix(Renderer *r, Mix *m, const uint8_t *in) {
    memcpy(&m->vol, in, 4);
    memcpy(&m->rate, in + 4, 4);
    memcpy(&m->buf_count, in + 8, 4);
    if (m->buf_count > MIXBUF_MAX) m->buf_count = MIXBUF_MAX;
    m->used = in[0xC];
    memcpy(&m->id, in + 0x10, 4);
    memcpy(m->mat, in + 0x24, sizeof m->mat);
    memcpy(&m->dest_mix, in + 0x924, 4);
    memcpy(&m->dest_spl, in + 0x928, 4);
}

static void reverb_free(Effect *e);

static void effect_free_lines(Effect *e) {
    for (int i = 0; i < 6; i++) { free(e->line[i]); e->line[i] = NULL; }
    e->line_len = e->line_pos = 0;
    reverb_free(e);
}

// EffectInParameterVersion2 (0xC0) -> state; writes EffectOutStatusVersion2 (0x90).
static void update_effect(Renderer *r, Effect *e, const uint8_t *in, uint8_t *out) {
    uint8_t type = in[0], is_new = in[1];
    if (type != e->type || is_new) {
        effect_free_lines(e);
        memset(e->bqs, 0, sizeof e->bqs);
        memset(e->lp, 0, sizeof e->lp);
    }
    e->type = type;
    e->enabled = in[2];
    memcpy(&e->mix_id, in + 4, 4);
    memcpy(&e->base, in + 8, 8);
    memcpy(&e->size, in + 0x10, 8);
    memcpy(&e->order, in + 0x18, 4);
    memcpy(e->p, in + 0x20, sizeof e->p);
    memset(out, 0, 0x90);
    out[0] = type ? (e->enabled || is_new ? 3 : 4) : 4;    // EffectState Enabled / Disabled
}

// Splitter block: SplitterInParameterHeader, states (SNDI), destinations (SNDD, version 2b).
static void update_splitters(Renderer *r, const uint8_t *in, uint32_t size) {
    if (size < 0x20 || memcmp(in, "SNDH", 4)) return;
    uint32_t nstate, ndest;
    memcpy(&nstate, in + 4, 4);
    memcpy(&ndest, in + 8, 4);
    const uint8_t *p = in + 0x20, *end = in + size;
    for (uint32_t i = 0; i < nstate && p + 0x10 <= end; i++) {
        if (memcmp(p, "SNDI", 4)) { ALOG("audren: bad splitter state magic"); return; }
        int32_t id, count;
        memcpy(&id, p + 4, 4);
        memcpy(&count, p + 12, 4);
        p += 0x10;
        if (count < 0 || p + count * 4 > end) return;
        if (id >= 0 && (uint32_t)id < r->p.splitter_count) {
            Splitter *s = &r->spl[id];
            free(s->dests);
            s->dests = count ? malloc(count * 4) : NULL;
            if (count) memcpy(s->dests, p, count * 4);
            s->count = count;
        }
        p += count * 4 + 0xC;
    }
    for (uint32_t i = 0; i < ndest && p + 0xA8 <= end; i++, p += 0xA8) {
        if (memcmp(p, "SNDD", 4)) { ALOG("audren: bad splitter destination magic"); return; }
        int32_t id;
        memcpy(&id, p + 4, 4);
        if (id < 0 || (uint32_t)id >= r->p.splitter_dest_count) continue;
        SplDest *d = &r->dst[id];
        memcpy(&d->dest, p + 0x68, 4);
        memcpy(d->vol, p + 8, sizeof d->vol);
        read_biquads(d->bq, p + 0x6C);
        uint8_t used = p[0x9C], reset_prev = p[0x9D];
        if (reset_prev) { memcpy(d->prev, d->vol, sizeof d->prev); d->need_update = 0; }
        d->used = used;
    }
}

// SinkInParameter (0x140); writes SinkOutStatus (0x20).
static void update_sink(Sink *s, const uint8_t *in, uint8_t *out) {
    s->type = in[0];
    s->used = in[1];
    if (s->type == 1) {
        memcpy(&s->inputs, in + 0x120, 4);
        if (s->inputs > 6) s->inputs = 6;
        memcpy(s->in, in + 0x124, 6);
        s->downmix_on = in[0x12B];
        memcpy(s->downmix, in + 0x12C, 16);
    }
    memset(out, 0, 0x20);
}

static void request_update(Renderer *r, const uint8_t *ib, uint64_t isize, uint8_t *ob, uint64_t osize) {
    uint32_t ih[16];
    memcpy(ih, ib, 0x40);
    uint32_t effect_out = 0x90, total = 0x40;
    uint32_t oh[16] = {0};
    oh[0] = ih[0];
    oh[1] = 0xB0;                                   // behaviour error info
    oh[2] = r->pool_count * 0x10;
    oh[3] = r->p.voice_count * 0x10;
    oh[5] = r->p.effect_count * effect_out;
    oh[7] = r->p.sink_count * 0x20;
    oh[8] = 0x10;                                   // performance
    oh[10] = 0x10;                                  // renderer info (elapsed frames)
    for (int i = 1; i < 11; i++) total += oh[i];
    oh[15] = total;
    if (osize < total || isize < ih[15]) {
        nx_log("audren: update buffers too small (in %#llx/%#x, out %#llx/%#x)", (unsigned long long)isize, ih[15],
               (unsigned long long)osize, total);
        return;
    }
    memset(ob, 0, total);
    memcpy(ob, oh, 0x40);
    uint8_t *o = ob + 0x40;
    const uint8_t *p = ib + 0x40 + ih[1];           // skip behaviour (revision + flags)

    pthread_mutex_lock(&r->lock);
    // memory pools (MemoryPoolInParameter 0x20 -> state)
    for (int i = 0; i < r->pool_count && (uint32_t)i * 0x20 < ih[2]; i++) {
        const uint8_t *q = p + i * 0x20;
        uint32_t st, ost = 0;
        memcpy(&st, q + 0x10, 4);
        Pool *pl = &r->pools[i];
        if (st == 4) {                              // RequestAttach -> Attached
            memcpy(&pl->addr, q, 8);
            memcpy(&pl->size, q + 8, 8);
            pl->attached = 1;
            ost = 5;
        } else if (st == 2) {                       // RequestDetach -> Detached
            pl->attached = 0;
            ost = 3;
        }
        memcpy(o + i * 0x10, &ost, 4);
    }
    p += ih[2];
    o += oh[2];
    // voice channel resources (0x70)
    for (uint32_t i = 0; i < r->p.voice_count && i * 0x70 < ih[4]; i++) {
        const uint8_t *q = p + i * 0x70;
        uint32_t id;
        memcpy(&id, q, 4);
        if (id >= r->p.voice_count) continue;
        ChanRes *c = &r->res[id];
        int used = q[0x64];
        memcpy(c->mix, q + 4, sizeof c->mix);
        if (used && !c->used) memcpy(c->prev, c->mix, sizeof c->prev);
        c->used = used;
    }
    p += ih[4];
    // voices
    uint32_t vsize = ih[3] / (r->p.voice_count ? r->p.voice_count : 1);
    if (vsize != 0x188) {
        static int once;
        if (!once++) nx_log("audren: voice parameter size %#x not supported (expected 0x188); silent", vsize);
    } else {
        for (uint32_t i = 0; i < r->p.voice_count; i++) {
            const uint8_t *q = p + i * 0x188;
            Voice *v = &r->voices[i];
            if (!q[9]) { v->in_use = 0; continue; }
            update_voice(r, v, q, o + i * 0x10);
        }
    }
    p += ih[3];
    o += oh[3];
    // effects
    if (ih[5] == r->p.effect_count * 0xC0)
        for (uint32_t i = 0; i < r->p.effect_count; i++) update_effect(r, &r->effects[i], p + i * 0xC0, o + i * effect_out);
    p += ih[5];
    o += oh[5];
    // splitters
    update_splitters(r, p, ih[9]);
    p += ih[9];
    // mixes (dirty-only update: 0x20 header with the count, parameters carry their mix id)
    if (ih[6] >= 0x20) {
        uint32_t count;
        memcpy(&count, p + 4, 4);
        for (uint32_t i = 0; i < count && 0x20 + (i + 1) * 0x930 <= ih[6]; i++) {
            const uint8_t *q = p + 0x20 + i * 0x930;
            int32_t id;
            memcpy(&id, q + 0x10, 4);
            if (id >= 0 && id < r->mix_count) update_mix(r, &r->mixes[id], q);
        }
        uint32_t off = 0;                           // buffer offsets: mixes in id order
        for (int i = 0; i < r->mix_count; i++) {
            r->mixes[i].off = off;
            off += r->mixes[i].buf_count;
        }
        if (off > r->p.mix_buffer_count) ALOG("audren: mixes use %u buffers of %u", off, r->p.mix_buffer_count);
    }
    p += ih[6];
    // sinks
    for (uint32_t i = 0; i < r->p.sink_count && (i + 1) * 0x140 <= ih[7]; i++)
        update_sink(&r->sinks[i], p + i * 0x140, o + i * 0x20);
    o += oh[7];
    o += oh[8];                                     // performance: no history
    o += oh[1];                                     // behaviour errors: none
    memcpy(o, &r->frames, 8);                       // renderer info
    r->updates++;
    pthread_mutex_unlock(&r->lock);
}

// ---- DSP ---------------------------------------------------------------------------------------

static inline float sat16(float x) { return x > 32767.f ? 32767.f : x < -32768.f ? -32768.f : x; }

static void biquad(const Biquad *b, BqState *s, float *x, uint32_t n) {
    float a0 = b->num[0], a1 = b->num[1], a2 = b->num[2], b1 = b->den[0], b2 = b->den[1];
    float s0 = s->s0, s1 = s->s1;
    for (uint32_t i = 0; i < n; i++) {
        float in = x[i], y = in * a0 + s0;
        s0 = in * a1 + y * b1 + s1;
        s1 = in * a2 + y * b2;
        x[i] = y;
    }
    s->s0 = s0;
    s->s1 = s1;
}

// Returns the last sample added (kept for depop when the voice stops).
static float mix_ramp(float *dst, const float *src, float from, float to, uint32_t n) {
    if (from == 0.f && to == 0.f) return 0.f;
    float d = (to - from) / n, g = from, y = 0.f;
    for (uint32_t i = 0; i < n; i++, g += d) dst[i] += y = src[i] * g;
    return y;
}

static void mix_const(float *dst, const float *src, float g, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) dst[i] += src[i] * g;
}

static void wb_end(Voice *v, WaveBuf *b) {      // MarkEndOfBufferWaveBufferProcessing
    VLOG(v, "wave buffer slot %u done (consumed %u, played %llu)%s", v->wb_index, v->consumed + 1, (unsigned long long)v->played,
         b->eos ? " end of stream" : "");
    v->valid[v->wb_index] = 0;
    v->wb_index = (v->wb_index + 1) & 3;
    v->loop_count = 0;
    v->consumed++;
    if (b->eos) v->played = 0;
}

static inline int16_t adpcm_sample(Voice *v, const uint8_t *data, uint64_t size, uint32_t pos, const int16_t *coef) {
    uint64_t nib = (uint64_t)(pos / 14) * 16 + pos % 14 + (pos % 14 ? 2 : 0);
    if (nib % 16 == 0) {
        if (nib / 2 >= size) return 0;
        v->pred_scale = data[nib / 2];
        nib += 2;
    }
    if (nib / 2 >= size) return 0;
    int byte = data[nib / 2];
    int s = nib & 1 ? (int8_t)(byte << 4) >> 4 : (int8_t)byte >> 4;
    int scale = v->pred_scale & 0xF, ci = (v->pred_scale >> 4) & 7;
    int c0 = coef ? coef[ci * 2] : 0, c1 = coef ? coef[ci * 2 + 1] : 0;
    int val = (s * (2048 << scale) + c0 * v->h0 + c1 * v->h1 + 1024) >> 11;
    val = val > 32767 ? 32767 : val < -32768 ? -32768 : val;
    v->h1 = v->h0;
    v->h0 = (int16_t)val;
    return (int16_t)val;
}

// Next source sample frame (all channels) from the wave buffer queue; 0 when starving.
static int pull(Renderer *r, Voice *v, float *out) {
    const int16_t *coef = v->fmt == FMT_ADPCM && v->ds_addr && v->ds_size >= 32 ? (const int16_t *)v->ds_addr : NULL;
    for (int guard = 0; guard < 8; guard++) {
        if (!v->valid[v->wb_index]) {
            if (!v->starving) VLOG(v, "starving (no queued buffer at slot %u, consumed %u)", v->wb_index, v->consumed);
            v->starving = 1;
            return 0;
        }
        v->starving = 0;
        WaveBuf *b = &v->wb[v->wb_index];
        if (v->offset == 0 && v->fmt == FMT_ADPCM && b->ctx) {
            const int16_t *ctx = (const int16_t *)b->ctx;
            v->pred_scale = ctx[0];
            v->h0 = ctx[1];
            v->h1 = ctx[2];
        }
        uint32_t s = b->start, e = b->end;
        if (v->loop_count > 0 && b->loop_start && b->loop_end && b->loop_start <= b->loop_end) {
            s = b->loop_start;
            e = b->loop_end;
        }
        int32_t count = (int32_t)(e - s);
        if (b->addr && count > 0 && v->offset < count) {
            uint32_t pos = s + v->offset;
            const uint8_t *d = (const uint8_t *)b->addr;
            switch (v->fmt) {
            case FMT_ADPCM: out[0] = adpcm_sample(v, d, b->size, pos, coef); break;
            case FMT_PCM16:
                for (uint32_t c = 0; c < v->chans; c++) out[c] = ((const int16_t *)d)[(uint64_t)pos * v->chans + c];
                break;
            case FMT_PCM8:
                for (uint32_t c = 0; c < v->chans; c++) out[c] = (float)((const int8_t *)d)[(uint64_t)pos * v->chans + c] * 256.f;
                break;
            case FMT_FLOAT:
                for (uint32_t c = 0; c < v->chans; c++) out[c] = sat16(((const float *)d)[(uint64_t)pos * v->chans + c] * 32768.f);
                break;
            default: for (uint32_t c = 0; c < v->chans; c++) out[c] = 0; break;
            }
            v->offset++;
            v->played++;
            if (v->offset >= count) {
                v->offset = 0;
                if (b->loop) {
                    v->loop_count++;
                    if (b->loop_count >= 0 && v->loop_count > b->loop_count) wb_end(v, b);
                    if (v->decoding & DEC_RESET_PLAYED_ON_LOOP) v->played = 0;
                } else wb_end(v, b);
            }
            return 1;
        }
        // nothing decodable in this buffer
        v->offset = 0;
        if (b->loop) {
            v->loop_count++;
            if (b->loop_count >= 0) wb_end(v, b);
            return 0;
        }
        wb_end(v, b);
    }
    return 0;
}

// Decode + resample one frame of a voice into r->buf channel slots (int16 scale).
static void voice_source(Renderer *r, Voice *v, float **chan) {
    uint32_t n = r->n, nc = v->chans ? v->chans : 1;
    float s[6];
    if (v->decoding & DEC_SKIP_SRC) {
        for (uint32_t i = 0; i < n; i++) {
            if (!pull(r, v, s)) { for (uint32_t c = 0; c < nc; c++) chan[c][i] = 0; continue; }
            for (uint32_t c = 0; c < nc; c++) chan[c][i] = s[c];
        }
        return;
    }
    float ratio = (float)v->rate / 48000.f * v->pitch;
    if (!(ratio > 0.f) || ratio > 16.f) ratio = 1.f;
    float frac = v->frac;
    for (uint32_t i = 0; i < n; i++) {
        float t = frac, t2 = t * t, t3 = t2 * t;
        for (uint32_t c = 0; c < nc; c++) {                 // Catmull-Rom between hist[1] and hist[2]
            float *h = v->hist[c];
            chan[c][i] = h[1] + 0.5f * t * (h[2] - h[0]) + t2 * (h[0] - 2.5f * h[1] + 2.f * h[2] - 0.5f * h[3]) +
                         t3 * (1.5f * (h[1] - h[2]) + 0.5f * (h[3] - h[0]));
        }
        frac += ratio;
        while (frac >= 1.f) {
            frac -= 1.f;
            if (!pull(r, v, s)) for (uint32_t c = 0; c < nc; c++) s[c] = 0;
            for (uint32_t c = 0; c < nc; c++) {
                float *h = v->hist[c];
                h[0] = h[1]; h[1] = h[2]; h[2] = h[3]; h[3] = s[c];
            }
        }
    }
    v->frac = frac;
}

static float *B(Renderer *r, uint32_t i) { return r->buf + (size_t)i * r->n; }

static float *voice_last(Renderer *r, Voice *v, uint32_t c) {
    return r->last + ((size_t)(v - r->voices) * 6 + c) * r->p.mix_buffer_count;
}

// UpdateParametersForCommandGeneration: returns whether the voice generates commands this frame.
static int voice_prepare(Renderer *r, Voice *v) {
    if (v->is_new) {
        voice_reset_dsp(v);
        v->prev_vol = v->vol;
        for (uint32_t c = 0; c < v->chans; c++)
            if (v->res[c] >= 0 && (uint32_t)v->res[c] < r->p.voice_count)
                memcpy(r->res[v->res[c]].prev, r->res[v->res[c]].mix, sizeof r->res[0].prev);
        for (uint32_t c = 0; c < 6; c++) memset(voice_last(r, v, c), 0, r->p.mix_buffer_count * sizeof(float));
        v->is_new = 0;
    }
    if (v->flush) {
        uint32_t idx = v->wb_index_param & 3;
        for (int i = 0; i < v->flush; i++) {
            v->wb[idx].to_dsp = 1;
            if (v->valid[idx]) {
                v->wb_index = (v->wb_index + 1) & 3;
                v->consumed++;
                v->valid[idx] = 0;
            }
            idx = (idx + 1) & 3;
        }
        v->flush = 0;
    }
    switch (v->play) {
    case PS_STARTED: {
        int any = 0;
        for (int i = 0; i < 4; i++) {
            if (!v->wb[i].to_dsp) { v->valid[i] = 1; v->wb[i].to_dsp = 1; }
            any |= v->valid[i];
        }
        v->was_playing = 0;
        return any;
    }
    case PS_STOPPING:
        for (int i = 0; i < 4; i++) {
            v->wb[i].to_dsp = 1;
            if (v->valid[i]) { v->wb_index = (v->wb_index + 1) & 3; v->consumed++; }
            v->valid[i] = 0;
        }
        v->offset = 0;
        v->played = 0;
        v->frac = 0;
        v->loop_count = 0;
        v->pred_scale = v->h0 = v->h1 = 0;
        memset(v->hist, 0, sizeof v->hist);
        v->play = PS_STOPPED;
        v->was_playing = v->prev_play == PS_STARTED;
        return v->was_playing;
    default:
        v->was_playing = v->prev_play == PS_STARTED;
        return v->was_playing;
    }
}


static SplDest *spl_dest(Renderer *r, uint32_t spl, int idx) {
    if (spl >= r->p.splitter_count) return NULL;
    Splitter *s = &r->spl[spl];
    if (idx < 0 || idx >= s->count) return NULL;
    int32_t d = s->dests[idx];
    return d >= 0 && (uint32_t)d < r->p.splitter_dest_count ? &r->dst[d] : NULL;
}

static Mix *mix_for(Renderer *r, int32_t id) { return id >= 0 && id < r->mix_count ? &r->mixes[id] : NULL; }

// DepopPrepare: a voice that stopped hands its last mixed samples to the depop buffer.
static void depop_prepare(Renderer *r, Voice *v) {
    for (uint32_t c = 0; c < 6; c++) {
        float *last = voice_last(r, v, c);
        for (uint32_t b = 0; b < r->p.mix_buffer_count; b++)
            if (last[b] != 0.f) { r->depop[b] += last[b]; last[b] = 0.f; }
    }
}

// DepopForMixBuffers: the tail decays exponentially (0.962189 per sample at 48 kHz) into the mix.
static void depop_apply(Renderer *r, Mix *m) {
    float k = m->rate == 32000 ? 0.943695f : 0.962189f;
    for (uint32_t b = m->off; b < m->off + m->buf_count && b < r->p.mix_buffer_count; b++) {
        float dv = r->depop[b];
        if (dv == 0.f) continue;
        float *x = B(r, b);
        for (uint32_t i = 0; i < r->n; i++) { dv *= k; x[i] += dv; }
        r->depop[b] = fabsf(dv) < 1e-6f ? 0.f : dv;
    }
}

static void render_voice(Renderer *r, Voice *v) {
    uint32_t n = r->n, nc = v->chans ? v->chans : 1, base = r->p.mix_buffer_count;
    float *chan[6], *last[6];
    for (uint32_t c = 0; c < nc; c++) chan[c] = B(r, base + c), last[c] = voice_last(r, v, c);
    voice_source(r, v, chan);
    r->active_voices++;
    if (v->mix_id == UNUSED_MIX && v->splitter_id == UNUSED_SPLITTER) return;
    for (uint32_t c = 0; c < nc; c++) {
        for (int k = 0; k < 2; k++) {
            if (!v->bq[k].enable) continue;
            if (!v->bq_was_on[k]) memset(&v->bqs[c][k], 0, sizeof(BqState));
            biquad(&v->bq[k], &v->bqs[c][k], chan[c], n);
        }
        float d = (v->vol - v->prev_vol) / n, g = v->prev_vol;   // volume ramp
        for (uint32_t i = 0; i < n; i++, g += d) chan[c][i] *= g;
    }
    v->prev_vol = v->vol;
    for (int k = 0; k < 2; k++) v->bq_was_on[k] = v->bq[k].enable;
    for (uint32_t c = 0; c < nc; c++) {
        if (v->mix_id != UNUSED_MIX) {
            Mix *m = mix_for(r, v->mix_id);
            if (!m || v->res[c] < 0 || (uint32_t)v->res[c] >= r->p.voice_count) continue;
            ChanRes *cr = &r->res[v->res[c]];
            for (uint32_t i = 0; i < m->buf_count; i++)
                last[c][m->off + i] = mix_ramp(B(r, m->off + i), chan[c], cr->prev[i], cr->mix[i], n);
            memcpy(cr->prev, cr->mix, sizeof cr->prev);
            continue;
        }
        for (int di = c;; di += nc) {
            if (v->splitter_id >= r->p.splitter_count || di >= r->spl[v->splitter_id].count) break;
            SplDest *d = spl_dest(r, v->splitter_id, di);
            if (!d || !d->used || d->dest == UNUSED_MIX) continue;
            Mix *m = mix_for(r, d->dest);
            if (!m) continue;
            const float *src = chan[c];
            if (d->bq[0].enable || d->bq[1].enable) {
                memcpy(r->tmp, chan[c], n * sizeof(float));
                for (int k = 0; k < 2; k++) {
                    if (!d->bq[k].enable) continue;
                    if (!d->bq_was_on[k]) memset(&d->bqs[c][k], 0, sizeof(BqState));
                    biquad(&d->bq[k], &d->bqs[c][k], r->tmp, n);
                }
                src = r->tmp;
            }
            for (int k = 0; k < 2; k++) d->bq_was_on[k] = d->bq[k].enable;
            for (uint32_t i = 0; i < m->buf_count; i++)
                last[c][m->off + i] = mix_ramp(B(r, m->off + i), src, d->prev[i], d->vol[i], n);
            d->need_update = 1;
        }
    }
}

// ---- effects -----------------------------------------------------------------------------------

static float q14(const uint8_t *p) { int32_t v; memcpy(&v, p, 4); return v / 16384.f; }

static void copy_io(Renderer *r, Mix *m, const uint8_t *in, const uint8_t *out, int count) {
    for (int i = 0; i < count; i++)
        if (in[i] != out[i] && in[i] < m->buf_count && out[i] < m->buf_count)
            memcpy(B(r, m->off + out[i]), B(r, m->off + in[i]), r->n * sizeof(float));
}

static void fx_aux(Renderer *r, Mix *m, Effect *e) {
    const uint8_t *p = e->p, *in = p, *outi = p + 24;
    uint32_t ch, count_max;
    uint64_t send, ret;
    memcpy(&ch, p + 48, 4);
    memcpy(&count_max, p + 56, 4);
    memcpy(&send, p + 64, 8);
    memcpy(&ret, p + 80, 8);
    if (ch > 6) ch = 6;
    uint64_t bytes = 0x80 + (uint64_t)count_max * 4;
    if (!send || !ret || !count_max || !pool_ok(r, send, bytes) || !pool_ok(r, ret, bytes)) {
        copy_io(r, m, in, outi, ch);
        return;
    }
    uint32_t *sinfo = (uint32_t *)(send + 0x40), *rinfo = (uint32_t *)(ret + 0x40);   // DSP-side infos
    int32_t *sbuf = (int32_t *)(send + 0x80), *rbuf = (int32_t *)(ret + 0x80);
    if (!e->enabled) {
        sinfo[0] = sinfo[1] = 0;
        rinfo[0] = rinfo[1] = 0;
        copy_io(r, m, in, outi, ch);
        return;
    }
    uint32_t n = r->n, wofs = 0;
    for (uint32_t c = 0; c < ch; c++, wofs += n) {
        if (in[c] >= m->buf_count || outi[c] >= m->buf_count) continue;
        float *x = B(r, m->off + in[c]), *y = B(r, m->off + outi[c]);
        uint32_t w = wofs + sinfo[1];
        if (w <= count_max)
            for (uint32_t i = 0; i < n; i++) sbuf[(w + i) % count_max] = (int32_t)x[i];
        uint32_t rd = wofs + rinfo[0];
        if (rd <= count_max)
            for (uint32_t i = 0; i < n; i++) y[i] = (float)rbuf[(rd + i) % count_max];
        else
            memset(y, 0, n * sizeof(float));
    }
    sinfo[1] = (sinfo[1] + ch * n) % count_max;
    rinfo[0] = (rinfo[0] + ch * n) % count_max;
}

static void fx_delay(Renderer *r, Mix *m, Effect *e) {
    const uint8_t *p = e->p, *in = p, *out = p + 6;
    uint16_t ch;
    memcpy(&ch, p + 14, 2);
    if (ch > 6) ch = 6;
    if (!e->enabled) { copy_io(r, m, in, out, ch); return; }
    uint32_t delay_ms, rate_q14;
    memcpy(&delay_ms, p + 20, 4);
    memcpy(&rate_q14, p + 24, 4);
    float rate = rate_q14 / 16384.f;                                // kHz in Q14 or Hz
    if (rate > 1000.f) rate /= 1000.f;
    uint32_t len = (uint32_t)(rate * delay_ms);
    if (len < 1) len = 1;
    if (len > 48000 * 10) len = 48000 * 10;
    if (len != e->line_len) {
        effect_free_lines(e);
        for (int c = 0; c < 6; c++) e->line[c] = calloc(len, sizeof(float));
        e->line_len = len;
    }
    float in_gain = q14(p + 28), fb = q14(p + 32) * 0.98f, out_gain = q14(p + 36), dry = q14(p + 40);
    float spread = q14(p + 44), lp_fb = 0.95f * q14(p + 48), lp_base = 1.f - lp_fb;
    float base = (1.f - spread) * fb, cross = (ch == 4 || ch == 6 ? 0.5f : 1.f) * spread * fb;
    float *x[6], *y[6];
    for (int c = 0; c < ch; c++) {
        if (in[c] >= m->buf_count || out[c] >= m->buf_count) return;
        x[c] = B(r, m->off + in[c]);
        y[c] = B(r, m->off + out[c]);
    }
    for (uint32_t i = 0; i < r->n; i++) {
        float d[6], s[6];
        for (int c = 0; c < ch; c++) d[c] = e->line[c][e->line_pos], s[c] = x[c][i] * 64.f;
        for (int c = 0; c < ch; c++) {
            float fbv = d[c] * base;
            if (ch == 2) fbv += d[c ^ 1] * cross;
            float t = fbv + s[c] * in_gain;
            e->lp[c] = lp_fb * e->lp[c] + t * lp_base;
            e->line[c][e->line_pos] = e->lp[c];
            y[c][i] = (s[c] * dry + d[c] * out_gain) / 64.f;
        }
        if (++e->line_pos >= e->line_len) e->line_pos = 0;
    }
}

// ---- reverbs (ports of Ryujinx ReverbCommand / Reverb3dCommand and their states) -------------------

// Delay line. is3d selects Ryujinx's DelayLine3d (separate read / write positions) over DelayLine.
typedef struct { float *buf; uint32_t max, cur, idx, last; int is3d; } DLine;

static uint32_t dl_samples(uint32_t rate, float ms) { return (uint32_t)roundf(rate * ms); }

static void dl_set_samples(DLine *d, uint32_t n) {
    if (d->is3d) {
        // A ring of max+1 slots. Ryujinx wraps both positions at max instead, so slot max kept the first
        // sample ever written and taps replayed it every cycle (a repeating burst).
        if (d->max >= n) { d->cur = n; d->last = (d->idx + n) % (d->max + 1); }
        return;
    }
    d->cur = n < d->max ? n : d->max;
    d->idx = 0;
    d->last = d->cur ? d->cur - 1 : 0;
}

static void dl_init(DLine *d, uint32_t rate, float ms_max, int is3d) {
    d->max = dl_samples(rate, ms_max);
    d->buf = calloc(d->max + 1, sizeof(float));
    d->idx = d->last = 0;
    d->is3d = is3d;
    dl_set_samples(d, d->max);
}

static inline float dl_read(DLine *d) { return d->buf[d->idx]; }

static inline float dl_update(DLine *d, float v) {
    if (d->is3d) {
        d->buf[d->last] = v;
        float out = d->buf[d->idx];
        if (++d->idx > d->max) d->idx = 0;
        if (++d->last > d->max) d->last = 0;
        return out;
    }
    float out = d->buf[d->idx];
    d->buf[d->idx++] = v;
    if (d->idx >= d->last) d->idx = 0;
    return out;
}

static inline float dl_tap_unsafe(DLine *d, uint32_t s, int off) {
    int base = (int)(d->is3d ? d->last : d->idx), size = (int)(d->is3d ? d->max + 1 : d->cur);
    int t = base - ((int)s + off);
    if (t < 0) t += size;
    if (t < 0 || t > (int)d->max) return 0.f;
    return d->buf[t];
}

static inline float dl_tap(DLine *d, uint32_t s) {
    if (!d->is3d && s >= d->cur) s = d->cur ? d->cur - 1 : 0;
    return dl_tap_unsafe(d, s, -1);
}

// DecayDelay: all-pass style section around a delay line.
static inline float decay_update(DLine *d, float rate, float v) {
    float p = v - rate * dl_read(d);
    return dl_update(d, p) + p * rate;
}

static float pow10_n(float x) { return x >= 0.f ? 1.f : x <= -5.3f ? 0.f : powf(10.f, x); }
static float cos_deg(float x) { return cosf(x * (float)M_PI / 180.f); }
static float sin_deg(float x) { return sinf(x * (float)M_PI / 180.f); }

typedef struct {
    DLine fdn[4], decay[4], pre, center;
    float decay_rate[4], hf_direct[4], hf_prev[4], prev_fb[4], early_gain[10];
    uint32_t early_time[10], pre_time;
} Reverb;

typedef struct {
    DLine fdn[4], decay1[4], decay2[4], pre, center;
    float rate1, rate2, dry, prev_pre, prev_pre_gain, target_pre_gain, early_refl_gain, late_gain;
    float direct[4], cur_fdn[4], cur_out[4], prev_dec[4];
    uint32_t early_time[20], refl_time;
} Reverb3d;

typedef struct { float det[6], gain[6], *buf; int pos[6]; int32_t ch, max; } Limiter;

static void reverb_free(Effect *e) {   // reverb states start with their delay lines
    if (!e->rv) return;
    if (e->type == FX_REVERB || e->type == FX_REVERB3D) {
        DLine *lines = e->rv;
        int count = e->type == FX_REVERB ? 10 : 14;
        for (int i = 0; i < count; i++) free(lines[i].buf);
    } else if (e->type == FX_LIMITER) free(((Limiter *)e->rv)->buf);
    free(e->rv);
    e->rv = NULL;
}

static const float rv_fdn_times[] = {53.953247f, 79.192566f, 116.238770f, 130.615295f, 53.953247f, 79.192566f, 116.238770f,
                                     170.615295f, 5.f, 10.f, 5.f, 10.f, 47.03f, 71.f, 103.f, 170.f,
                                     53.953247f, 79.192566f, 116.238770f, 170.615295f};
static const float rv_decay_times[] = {7, 9, 13, 17, 7, 9, 13, 17, 1, 1, 1, 1, 7, 7, 13, 9, 7, 9, 13, 17};
static const float rv_early_times[] = {0.0f, 3.5f, 2.8f, 3.9f, 2.7f, 13.4f, 7.9f, 8.4f, 9.9f, 12.0f,
                                       0.0f, 11.8f, 5.5f, 11.2f, 10.4f, 38.1f, 22.2f, 29.6f, 21.2f, 24.8f,
                                       0.0f, 41.5f, 20.5f, 41.3f, 0.0f, 29.5f, 33.8f, 45.2f, 46.8f, 0.0f,
                                       33.1f, 43.3f, 22.8f, 37.9f, 14.9f, 35.3f, 17.9f, 34.2f, 0.0f, 43.3f,
                                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
static const float rv_early_gain[] = {0.70f, 0.68f, 0.70f, 0.68f, 0.70f, 0.68f, 0.70f, 0.68f, 0.68f, 0.68f,
                                      0.70f, 0.68f, 0.70f, 0.68f, 0.70f, 0.68f, 0.68f, 0.68f, 0.68f, 0.68f,
                                      0.50f, 0.70f, 0.70f, 0.68f, 0.50f, 0.68f, 0.68f, 0.70f, 0.68f, 0.00f,
                                      0.93f, 0.92f, 0.87f, 0.86f, 0.94f, 0.81f, 0.80f, 0.77f, 0.76f, 0.65f,
                                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
static const float rv_pre_times[] = {12.5f, 40.0f, 50.0f, 50.0f, 0.0f};

// ReverbParameter: in 0, out 6, ch 14, rate 16 (Q14 kHz), early mode 20, early gain 24, predelay 28,
// late mode 32, late gain 36, decay time 40, hf decay 44, coloration 48, reverb gain 52, out 56, dry 60.
static void reverb_params(Reverb *s, const uint8_t *p) {
    uint32_t rate = (uint32_t)q14(p + 16);
    uint32_t early_mode, late_mode;
    uint16_t ch;
    memcpy(&early_mode, p + 20, 4);
    memcpy(&late_mode, p + 32, 4);
    memcpy(&ch, p + 14, 2);
    if (early_mode > 4) early_mode = 4;
    if (late_mode > 4) late_mode = 4;
    float pre_ms = q14(p + 28), early_gain = q14(p + 24), coloration = q14(p + 48), decay = q14(p + 40);
    for (int i = 0; i < 10; i++) {
        uint32_t t = dl_samples(rate, rv_early_times[early_mode * 10 + i] + pre_ms);
        s->early_time[i] = (t < s->pre.max ? t : s->pre.max) + 1;
        s->early_gain[i] = rv_early_gain[early_mode * 10 + i] * early_gain;
    }
    if (ch == 2) { s->early_gain[4] *= 0.5f; s->early_gain[5] *= 0.5f; }
    uint32_t pt = dl_samples(rate, rv_pre_times[early_mode] + pre_ms);
    s->pre_time = pt < s->pre.max ? pt : s->pre.max;
    float hf_ratio = q14(p + 44), hf_cos = cos_deg(1280.f / rate);
    for (int i = 0; i < 4; i++) {
        dl_set_samples(&s->fdn[i], dl_samples(rate, rv_fdn_times[late_mode * 4 + i]));
        dl_set_samples(&s->decay[i], dl_samples(rate, rv_decay_times[late_mode * 4 + i]));
        float a = -3.f * (s->decay[i].cur + s->fdn[i].cur), b = a / (decay * rate), c, d;
        if (hf_ratio < 0.995f) {
            float e = pow10_n(((1.f / hf_ratio) - 1.f) * 2 / 100 * (b / 10)), f = 1.f - e;
            float g = 2.f - e * 2 * hf_cos, h = sqrtf(g * g - f * f * 4);
            c = (g - h) / (f * 2);
            d = 1.f - c;
        } else { c = 0.f; d = 1.f; }
        s->hf_direct[i] = pow10_n(b / 1000) * d * 0.7071f;
        s->hf_prev[i] = c;
        s->prev_fb[i] = 0.f;
        s->decay_rate[i] = 0.6f * (1.f - coloration);
    }
}

static void fx_reverb(Renderer *r, Mix *m, Effect *e) {
    const uint8_t *p = e->p, *in = p, *out = p + 6;
    uint16_t ch;
    memcpy(&ch, p + 14, 2);
    if (ch != 1 && ch != 2 && ch != 4 && ch != 6) return;
    if (!e->enabled) { copy_io(r, m, in, out, ch); return; }
    float *x[6], *y[6];
    for (int c = 0; c < ch; c++) {
        if (in[c] >= m->buf_count || out[c] >= m->buf_count) return;
        x[c] = B(r, m->off + in[c]);
        y[c] = B(r, m->off + out[c]);
    }
    Reverb *s = e->rv;
    if (!s) {
        uint32_t rate = (uint32_t)q14(p + 16);
        if (!rate || rate > 192) return;
        s = e->rv = calloc(1, sizeof(Reverb));
        for (int i = 0; i < 4; i++) {
            dl_init(&s->fdn[i], rate, rv_fdn_times[4 * 4 + i], 0);   // allocated for the longest (Limit) mode
            dl_init(&s->decay[i], rate, rv_decay_times[4 * 4 + i], 0);
        }
        dl_init(&s->pre, rate, 350.f, 0);
        dl_init(&s->center, rate, 5.f, 0);
        reverb_params(s, p);
        memcpy(e->rv_p, p, sizeof e->rv_p);
    } else if (memcmp(e->rv_p, p, sizeof e->rv_p)) {
        reverb_params(s, p);
        memcpy(e->rv_p, p, sizeof e->rv_p);
    }
    static const int early_out[4][20] = {{0}, {0, 0, 1, 1, 0, 1, 0, 0, 1, 1}, {0, 0, 1, 1, 0, 1, 2, 2, 3, 3},
                                          {0, 5, 0, 5, 1, 5, 1, 5, 4, 5, 4, 5, 2, 5, 2, 5, 3, 5, 3, 5}};
    static const int early_tgt[4][20] = {{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9}, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9},
                                          {0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9}};
    static const int fb_tgt[4][6] = {{0, 1, 2, 3}, {2, 0, 3, 1}, {0, 1, 2, 3}, {0, 1, 2, 3, -1, 3}};
    static const int fb_out[4][6] = {{0, 0, 0, 0}, {0, 0, 1, 1}, {0, 1, 2, 3}, {0, 1, 2, 3, 4, 5}};
    int mode = ch == 1 ? 0 : ch == 2 ? 1 : ch == 4 ? 2 : 3, n_early = mode == 3 ? 20 : 10, n_fb = mode == 3 ? 6 : 4;
    int surround = ch == 6;
    float reverb_gain = q14(p + 52), late_gain = q14(p + 36), out_gain = q14(p + 56), dry = q14(p + 60);
    for (uint32_t i = 0; i < r->n; i++) {
        float ov[6] = {0}, fo[4], fv[4], cin[6], pre = 0.f;
        for (int k = 0; k < n_early; k++) {
            int t = early_tgt[mode][k];
            ov[early_out[mode][k]] += dl_tap_unsafe(&s->pre, s->early_time[t], 0) * s->early_gain[t];
        }
        if (surround) ov[5] *= 0.2f;
        for (int c = 0; c < ch; c++) { cin[c] = x[c][i] * 64.f; pre += cin[c] * reverb_gain; }
        dl_update(&s->pre, pre);
        float late = dl_tap(&s->pre, s->pre_time) * late_gain;
        for (int k = 0; k < 4; k++) {
            fo[k] = dl_read(&s->fdn[k]) * s->hf_direct[k] + s->prev_fb[k] * s->hf_prev[k];
            s->prev_fb[k] = fo[k];
        }
        fv[0] = fo[2] + fo[1];
        fv[1] = -fo[0] - fo[3];
        fv[2] = fo[0] - fo[3];
        fv[3] = fo[1] - fo[2];
        for (int k = 0; k < 4; k++) {
            fo[k] = decay_update(&s->decay[k], s->decay_rate[k], fv[k] + late);
            dl_update(&s->fdn[k], fo[k]);
        }
        for (int k = 0; k < n_fb; k++)
            if (fb_tgt[mode][k] >= 0) ov[fb_out[mode][k]] += fo[fb_tgt[mode][k]];
        if (surround) ov[4] += dl_update(&s->center, (fo[2] - fo[3]) * 0.5f);
        for (int c = 0; c < ch; c++) y[c][i] = (ov[c] * out_gain + cin[c] * dry) / 64.f;
    }
}

static const float r3_fdn_min[] = {5.0f, 6.0f, 13.0f, 14.0f}, r3_fdn_max[] = {45.704f, 82.782f, 149.94f, 271.58f};
static const float r3_decay1[] = {17.0f, 13.0f, 9.0f, 7.0f}, r3_decay2[] = {19.0f, 11.0f, 10.0f, 6.0f};
static const float r3_early_times[] = {0.017136f, 0.059154f, 0.16173f, 0.39019f, 0.42526f, 0.45541f, 0.68974f,
                                       0.74591f, 0.83384f, 0.8595f, 0.0f, 0.075024f, 0.16879f, 0.2999f,
                                       0.33744f, 0.3719f, 0.59901f, 0.71674f, 0.81786f, 0.85166f};
static const float r3_early_gain[] = {0.67096f, 0.61027f, 1.0f, 0.35680f, 0.68361f, 0.65978f, 0.51939f,
                                      0.24712f, 0.45945f, 0.45021f, 0.64196f, 0.54879f, 0.92925f, 0.38270f,
                                      0.72867f, 0.69794f, 0.5464f, 0.24563f, 0.45214f, 0.44042f};

// Reverb3dParameter: in 0, out 6, ch 14, rate 20 (Hz), then floats: room hf 24, hf reference 28,
// decay time 32, hf decay ratio 36, room gain 40, reflections gain 44, reverb gain 48, diffusion 52,
// reflection delay 56, reverb delay 60, density 64, dry gain 68.
static void reverb3d_params(Reverb3d *s, const uint8_t *p) {
    uint32_t srate;
    float f[12];
    memcpy(&srate, p + 20, 4);
    memcpy(f, p + 24, sizeof f);
    float room_hf = f[0], hf_ref = f[1], decay = f[2], hf_ratio = f[3], room = f[4], refl = f[5], rev = f[6];
    float diffusion = f[7], refl_delay = f[8], rev_delay = f[9], density = f[10];
    uint32_t rate = srate / 1000;
    float fr = (float)srate;
    s->dry = f[11];
    memset(s->prev_dec, 0, sizeof s->prev_dec);
    s->prev_pre = 0.f;
    s->early_refl_gain = pow10_n(fminf(room + refl, 5000.f) / 2000.f);
    s->late_gain = pow10_n(fminf(room + rev, 5000.f) / 2000.f);
    float hf_gain = pow10_n(room_hf / 2000.f);
    if (hf_gain < 1.f) {
        float a = 1.f - hf_gain, b = 2.f - 2.f * hf_gain * cos_deg(256.f * hf_ref / fr);
        float c = sqrtf(b * b - 4.f * (1.f - hf_gain) * (1.f - hf_gain));
        s->prev_pre_gain = (b - c) / (2.f * a);
        s->target_pre_gain = 1.f - s->prev_pre_gain;
    } else { s->prev_pre_gain = 0.f; s->target_pre_gain = 1.f; }
    s->refl_time = dl_samples(rate, 1000.f * (refl_delay + rev_delay));
    float echo = 0.6f * diffusion * 0.01f;
    for (int i = 0; i < 4; i++) {
        dl_set_samples(&s->fdn[i], dl_samples(rate, r3_fdn_min[i] + density / 100 * (r3_fdn_max[i] - r3_fdn_min[i])));
        uint32_t cnt = s->fdn[i].cur + s->decay1[i].cur + s->decay2[i].cur;
        float a = (-60.f * cnt) / (decay * fr), b = a / hf_ratio;
        float c = cos_deg(128.f * 0.5f * hf_ref / fr) / sin_deg(128.f * 0.5f * hf_ref / fr);
        float d = pow10_n((b - a) / 40.f), e2 = pow10_n((b + a) / 40.f) * 0.7071f;
        s->direct[i] = e2 * (d * c + 1.f) / (c + d);
        s->cur_fdn[i] = e2 * (1.f - d * c) / (c + d);
        s->cur_out[i] = (c - d) / (c + d);
    }
    s->rate1 = echo;
    s->rate2 = echo * -0.9f;
    for (int i = 0; i < 20; i++) {
        uint32_t t = dl_samples(rate, refl_delay * 1000.f + r3_early_times[i] * 1000.f * (rev_delay * 0.9998f + 0.02f));
        s->early_time[i] = t < s->pre.max ? t : s->pre.max;
    }
}

static void fx_reverb3d(Renderer *r, Mix *m, Effect *e) {
    const uint8_t *p = e->p, *in = p, *out = p + 6;
    uint16_t ch;
    memcpy(&ch, p + 14, 2);
    if (ch != 1 && ch != 2 && ch != 4 && ch != 6) return;
    if (!e->enabled) { copy_io(r, m, in, out, ch); return; }
    float *x[6], *y[6];
    for (int c = 0; c < ch; c++) {
        if (in[c] >= m->buf_count || out[c] >= m->buf_count) return;
        x[c] = B(r, m->off + in[c]);
        y[c] = B(r, m->off + out[c]);
    }
    Reverb3d *s = e->rv;
    if (!s) {
        uint32_t srate;
        memcpy(&srate, p + 20, 4);
        uint32_t rate = srate / 1000;
        if (!rate || rate > 192) return;
        s = e->rv = calloc(1, sizeof(Reverb3d));
        for (int i = 0; i < 4; i++) {
            dl_init(&s->fdn[i], rate, r3_fdn_max[i], 1);
            dl_init(&s->decay1[i], rate, r3_decay1[i], 1);
            dl_init(&s->decay2[i], rate, r3_decay2[i], 1);
        }
        dl_init(&s->pre, rate, 400.f, 1);
        dl_init(&s->center, rate, 5.f, 1);
        reverb3d_params(s, p);
        memcpy(e->rv_p, p, sizeof e->rv_p);
    } else if (memcmp(e->rv_p, p, sizeof e->rv_p)) {
        reverb3d_params(s, p);
        memcpy(e->rv_p, p, sizeof e->rv_p);
    }
    static const int early_out[4][40] = {
        {0},
        {0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1},
        {0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 0, 0, 0, 0, 3, 3, 3},
        {4, 5, 0, 5, 0, 5, 1, 5, 1, 5, 1, 5, 1, 5, 2, 5, 2, 5, 2, 5, 1, 5, 1, 5, 1, 5, 0, 5, 0, 5, 0, 5, 0, 5, 3, 5, 3, 5, 3, 5}};
    static const int fb_tgt[4][6] = {{0}, {0, 1}, {0, 1, 2, 3}, {0, 1, 2, 3, -1, 3}};
    int mode = ch == 1 ? 0 : ch == 2 ? 1 : ch == 4 ? 2 : 3, n_early = mode == 3 ? 40 : 20;
    int n_fb = mode == 0 ? 1 : mode == 1 ? 2 : mode == 2 ? 4 : 6;
    for (uint32_t i = 0; i < r->n; i++) {
        float ov[6] = {0}, fo[4], fv[4], v[4], cin[6], pre = 0.f;
        float tap = dl_tap_unsafe(&s->pre, s->refl_time, 1);
        for (int k = 0; k < n_early; k++) {
            int t = mode == 3 ? k / 2 : k;                   // target early delay line (Ryujinx tables)
            ov[early_out[mode][t]] += dl_tap_unsafe(&s->pre, s->early_time[t], 1) * r3_early_gain[t];
        }
        for (int c = 0; c < ch; c++) { cin[c] = x[c][i]; pre += cin[c]; }
        for (int c = 0; c < ch; c++) ov[c] *= s->early_refl_gain;
        s->prev_pre = pre * s->target_pre_gain + s->prev_pre * s->prev_pre_gain;
        dl_update(&s->pre, s->prev_pre);
        for (int k = 0; k < 4; k++) {
            float f = dl_read(&s->fdn[k]), o = f * s->direct[k] + s->prev_dec[k];
            s->prev_dec[k] = f * s->cur_fdn[k] + o * s->cur_out[k];
            fo[k] = o;
        }
        fv[0] = fo[2] + fo[1];
        fv[1] = -fo[0] - fo[3];
        fv[2] = fo[0] - fo[3];
        fv[3] = fo[1] - fo[2];
        for (int k = 0; k < 4; k++) {
            float t = decay_update(&s->decay1[k], s->rate1, tap * s->late_gain + fv[k]);
            v[k] = decay_update(&s->decay2[k], s->rate2, t);
            dl_update(&s->fdn[k], v[k]);
        }
        for (int c = 0; c < n_fb && c < ch; c++)
            if (fb_tgt[mode][c] >= 0) y[c][i] = ov[c] + v[fb_tgt[mode][c]] + cin[c] * s->dry;
        if (mode == 0) y[0][i] += v[1];
        if (mode == 3) y[4][i] += ov[4] + dl_update(&s->center, (v[2] - v[3]) * 0.5f) + cin[4] * s->dry;
    }
}

// ---- limiter and compressor (ports of Ryujinx LimiterCommandVersion2 / CompressorCommand) ----------

// LimiterParameter: in 0, out 6, ch 14, attack coef 36, release coef 40, threshold 44, input gain 48,
// output gain 52 (floats), delay samples min 56 / max 60. Look-ahead peak limiter per channel.
static void fx_limiter(Renderer *r, Mix *m, Effect *e) {
    const uint8_t *p = e->p, *in = p, *out = p + 6;
    uint16_t ch;
    memcpy(&ch, p + 14, 2);
    if (ch > 6) return;
    if (!e->enabled) { copy_io(r, m, in, out, ch); return; }
    float attack, release, threshold, in_gain, out_gain;
    int32_t dmin, dmax;
    memcpy(&attack, p + 36, 4);
    memcpy(&release, p + 40, 4);
    memcpy(&threshold, p + 44, 4);
    memcpy(&in_gain, p + 48, 4);
    memcpy(&out_gain, p + 52, 4);
    memcpy(&dmin, p + 56, 4);
    memcpy(&dmax, p + 60, 4);
    if (dmin < 1 || dmax < dmin || dmax > 48000) { copy_io(r, m, in, out, ch); return; }
    Limiter *s = e->rv;
    if (!s || s->ch != ch || s->max != dmax) {
        reverb_free(e);
        s = e->rv = calloc(1, sizeof(Limiter));
        s->buf = calloc((size_t)ch * dmax, sizeof(float));
        s->ch = ch;
        s->max = dmax;
        for (int c = 0; c < 6; c++) s->gain[c] = 1.f;
    }
    for (int c = 0; c < ch; c++) {
        if (in[c] >= m->buf_count || out[c] >= m->buf_count) continue;
        float *x = B(r, m->off + in[c]), *y = B(r, m->off + out[c]);
        for (uint32_t i = 0; i < r->n; i++) {
            float v = x[i] / 32767.f * in_gain, a = fabsf(v);
            s->det[c] += (a > s->det[c] ? attack : release) * (a - s->det[c]);
            float att = s->det[c] > threshold ? threshold / s->det[c] : 1.f;
            s->gain[c] += (s->gain[c] > att ? attack : release) * (att - s->gain[c]);
            float *d = &s->buf[c * dmax + s->pos[c]];
            y[i] = *d * s->gain[c] * out_gain * 32767.f;
            *d = v;
            if (++s->pos[c] >= dmin) s->pos[c] = 0;
        }
    }
}

typedef struct { float in_avg, u4, gain_avg, prev_alpha, reduction, knee_lo, knee_hi, out_gain; } Compressor;

// CompressorParameter: in 0, out 6, ch 14, threshold 20 (dB), ratio 24, input gain 36 (input EMA alpha),
// attack coef 40, release coef 44, output gain 48 (dB), makeup gain flag 53. Soft-knee RMS compressor,
// one gain for all channels.
static void fx_compressor(Renderer *r, Mix *m, Effect *e) {
    const uint8_t *p = e->p, *in = p, *out = p + 6;
    uint16_t ch;
    memcpy(&ch, p + 14, 2);
    if (ch < 1 || ch > 6) return;
    if (!e->enabled) { copy_io(r, m, in, out, ch); return; }
    float thr, ratio, alpha_in, attack, release, out_db;
    memcpy(&thr, p + 20, 4);
    memcpy(&ratio, p + 24, 4);
    memcpy(&alpha_in, p + 36, 4);
    memcpy(&attack, p + 40, 4);
    memcpy(&release, p + 44, 4);
    memcpy(&out_db, p + 48, 4);
    if (!(ratio > 0.f)) { copy_io(r, m, in, out, ch); return; }
    Compressor *s = e->rv;
    if (!s) {
        s = e->rv = calloc(1, sizeof(Compressor));
        s->u4 = 1.f;
        s->gain_avg = 1.f;
    }
    if (!e->rv_p[0] || memcmp(e->rv_p + 1, p + 1, sizeof e->rv_p - 1)) {   // UpdateParameter
        float inv = 1.f / ratio, makeup = p[53] ? thr * 0.5f * (inv - 1.f) - 3.f : 0.f;
        s->prev_alpha = attack;
        s->reduction = (1.f - inv) / 6.f;
        s->knee_lo = thr - 1.5f;
        s->knee_hi = thr + 1.5f;
        s->out_gain = powf(10.f, (out_db + makeup) / 20.f);
        memcpy(e->rv_p, p, sizeof e->rv_p);
        e->rv_p[0] = 1;
    }
    float *x[6], *y[6];
    for (int c = 0; c < ch; c++) {
        if (in[c] >= m->buf_count || out[c] >= m->buf_count) return;
        x[c] = B(r, m->off + in[c]);
        y[c] = B(r, m->off + out[c]);
    }
    for (uint32_t i = 0; i < r->n; i++) {
        float cin[6], mean = 0.f;
        for (int c = 0; c < ch; c++) { cin[c] = x[c][i]; float v = cin[c] / 32768.f; mean += v * v; }
        mean /= ch;
        s->in_avg += alpha_in * (mean - s->in_avg);
        float lvl = 10.f * log10f(fmaxf(s->in_avg, 1e-10f)), z = 1.f;
        int over = lvl >= s->knee_lo;
        if (s->in_avg < 1e-10f) { lvl = -100.f; over = s->knee_lo <= -100.f; }
        if (over) {
            float g = lvl >= s->knee_hi ? (1.f / ratio - 1.f) * (lvl - thr)
                                        : (lvl - s->knee_lo) * ((lvl - s->knee_lo) * -s->reduction);
            z = powf(10.f, g / 20.f);
        }
        float u4_new = z, a;
        if (s->u4 - z <= 0.08f) {
            a = release;
            if (s->u4 - z >= -0.08f) {
                if (fabsf(s->gain_avg - z) >= 0.001f) u4_new = s->u4;
                a = s->prev_alpha;
            }
        } else a = attack;
        s->gain_avg += a * (z - s->gain_avg);
        for (int c = 0; c < ch; c++) y[c][i] = cin[c] * s->gain_avg * s->out_gain;
        s->u4 = u4_new;
        s->prev_alpha = a;
    }
}

static void run_effect(Renderer *r, Mix *m, Effect *e) {
    const uint8_t *p = e->p;
    switch (e->type) {
    case FX_BUFMIX: {
        if (!e->enabled) break;
        uint32_t count;
        memcpy(&count, p + 144, 4);
        for (uint32_t i = 0; i < count && i < 24; i++) {
            float g;
            memcpy(&g, p + 48 + i * 4, 4);
            if (g != 0.f && p[i] < m->buf_count && p[24 + i] < m->buf_count)
                mix_const(B(r, m->off + p[24 + i]), B(r, m->off + p[i]), g, r->n);
        }
        break;
    }
    case FX_AUX: fx_aux(r, m, e); break;
    case FX_DELAY: fx_delay(r, m, e); break;
    case FX_REVERB: fx_reverb(r, m, e); break;
    case FX_REVERB3D: fx_reverb3d(r, m, e); break;
    case FX_LIMITER: fx_limiter(r, m, e); break;
    case FX_COMPRESSOR: fx_compressor(r, m, e); break;
    case FX_BIQUAD: {
        uint8_t ch = p[36];
        if (ch > 6) ch = 6;
        if (!e->enabled) { copy_io(r, m, p, p + 6, ch); break; }
        Biquad b = {.enable = 1};
        memcpy(b.num, p + 16, 12);
        memcpy(b.den, p + 28, 8);
        for (int c = 0; c < ch; c++) {
            if (p[c] >= m->buf_count || p[6 + c] >= m->buf_count) continue;
            float *x = B(r, m->off + p[c]), *y = B(r, m->off + p[6 + c]);
            if (x != y) memcpy(y, x, r->n * sizeof(float));
            biquad(&b, &e->bqs[c], y, r->n);
        }
        break;
    }
    default: {                                      // capture buffer: bypass
        uint16_t ch;
        memcpy(&ch, p + 14, 2);
        if (ch > 6) ch = 6;
        copy_io(r, m, p, p + 6, ch);
        break;
    }
    }
}

static double mix_energy(Renderer *r, Mix *m) {
    double sum = 0;
    for (uint32_t b = 0; b < m->buf_count; b++) {
        const float *x = B(r, m->off + b);
        for (uint32_t i = 0; i < r->n; i++) sum += (double)x[i] * x[i];
    }
    return sum;
}

static void run_effects(Renderer *r, Mix *m) {
    for (uint32_t order = 0; order < r->p.effect_count; order++)
        for (uint32_t i = 0; i < r->p.effect_count; i++) {
            Effect *e = &r->effects[i];
            if (!e->type || e->mix_id != m->id || e->order != order) continue;
            if (g_alog) e->e_in += mix_energy(r, m);
            run_effect(r, m, e);
            if (g_alog) e->e_out += mix_energy(r, m);
        }
}

// ---- mixes ---------------------------------------------------------------------------------------

static int mix_depth(Renderer *r, int id, int guard) {   // longest path to the final mix
    Mix *m = mix_for(r, id);
    if (!m || id == FINAL_MIX || guard > r->mix_count) return 0;
    int best = 0;
    if (m->dest_mix != UNUSED_MIX) {
        int d = mix_depth(r, m->dest_mix, guard + 1) + 1;
        if (d > best) best = d;
    } else if (m->dest_spl != UNUSED_SPLITTER && m->dest_spl < r->p.splitter_count) {
        for (int i = 0; i < r->spl[m->dest_spl].count; i++) {
            SplDest *sd = spl_dest(r, m->dest_spl, i);
            if (sd && sd->used && sd->dest != UNUSED_MIX) {
                int d = mix_depth(r, sd->dest, guard + 1) + 1;
                if (d > best) best = d;
            }
        }
    }
    return best;
}

static void mix_out(Renderer *r, Mix *m) {
    uint32_t n = r->n;
    if (m->dest_mix != UNUSED_MIX) {
        Mix *d = mix_for(r, m->dest_mix);
        if (!d) return;
        for (uint32_t i = 0; i < m->buf_count; i++)
            for (uint32_t j = 0; j < d->buf_count; j++) {
                float g = m->vol * m->mat[i * MIXBUF_MAX + j];
                if (g != 0.f) mix_const(B(r, d->off + j), B(r, m->off + i), g, n);
            }
    } else if (m->dest_spl != UNUSED_SPLITTER && m->dest_spl < r->p.splitter_count) {
        for (int di = 0; di < r->spl[m->dest_spl].count; di++) {
            SplDest *sd = spl_dest(r, m->dest_spl, di);
            if (!sd || !sd->used || sd->dest == UNUSED_MIX || !m->buf_count) continue;
            Mix *d = mix_for(r, sd->dest);
            if (!d) continue;
            float *src = B(r, m->off + di % m->buf_count);
            for (uint32_t j = 0; j < d->buf_count; j++) {
                float g = m->vol * sd->vol[j];
                if (g != 0.f) mix_const(B(r, d->off + j), src, g, n);
            }
        }
    }
}

// One audio frame: returns stereo float samples in r->out.
static void render_frame(Renderer *r) {
    uint32_t n = r->n;
    memset(r->buf, 0, (size_t)(r->p.mix_buffer_count + 6) * n * sizeof(float));
    r->active_voices = 0;
    for (uint32_t i = 0; i < r->p.voice_count; i++) {
        Voice *v = &r->voices[i];
        if (!v->in_use || !v->wb_count || v->ds_unmapped || v->buf_unmapped || v->drop) continue;
        if (!voice_prepare(r, v)) continue;
        if (v->was_playing) { v->prev_vol = 0; depop_prepare(r, v); continue; }
        render_voice(r, v);
    }
    for (uint32_t i = 0; i < r->p.splitter_dest_count; i++) {
        SplDest *d = &r->dst[i];
        if (d->used && d->need_update) memcpy(d->prev, d->vol, sizeof d->prev);
        d->need_update = 0;
    }
    // submixes, farthest from the final mix first
    int order[64], depth[64], k = 0;
    for (int i = 1; i < r->mix_count && k < 64; i++)
        if (r->mixes[i].used) { order[k] = i; depth[k++] = mix_depth(r, i, 0); }
    for (int a = 1; a < k; a++)                                  // insertion sort, depth descending
        for (int b = a; b > 0 && depth[b] > depth[b - 1]; b--) {
            int t = order[b]; order[b] = order[b - 1]; order[b - 1] = t;
            t = depth[b]; depth[b] = depth[b - 1]; depth[b - 1] = t;
        }
    for (int i = 0; i < k; i++) {
        Mix *m = &r->mixes[order[i]];
        depop_apply(r, m);
        run_effects(r, m);
        mix_out(r, m);
    }
    // final mix and device sink
    Mix *f = &r->mixes[FINAL_MIX];
    memset(r->out, 0, n * 2 * sizeof(float));
    if (!f->used) return;
    depop_apply(r, f);
    run_effects(r, f);
    if (f->vol != 1.f)
        for (uint32_t i = 0; i < f->buf_count; i++)
            for (uint32_t s = 0; s < n; s++) B(r, f->off + i)[s] *= f->vol;
    for (uint32_t si = 0; si < r->p.sink_count; si++) {
        Sink *s = &r->sinks[si];
        if (!s->used || s->type != 1 || !s->inputs) continue;
        float *ch[6];
        for (uint32_t c = 0; c < s->inputs; c++)
            ch[c] = s->in[c] < f->buf_count ? B(r, f->off + s->in[c]) : r->tmp;
        if (s->inputs == 1) memset(r->tmp, 0, n * sizeof(float));
        static const float def[4] = {1.0f, 0.707f, 0.251f, 0.707f};   // front, center, lfe, back
        const float *k6 = s->downmix_on ? s->downmix : def;
        for (uint32_t i = 0; i < n; i++) {
            float L, R;
            if (s->inputs >= 6) {
                L = k6[0] * ch[0][i] + k6[1] * ch[2][i] + k6[2] * ch[3][i] + k6[3] * ch[4][i];
                R = k6[0] * ch[1][i] + k6[1] * ch[2][i] + k6[2] * ch[3][i] + k6[3] * ch[5][i];
            } else if (s->inputs >= 2) {
                L = ch[0][i];
                R = ch[1][i];
            } else L = R = ch[0][i];
            L = sat16(L) / 32768.f;
            R = sat16(R) / 32768.f;
            r->out[2 * i] = L;
            r->out[2 * i + 1] = R;
            float a = fabsf(L) > fabsf(R) ? fabsf(L) : fabsf(R);
            if (a > r->peak) r->peak = a;
        }
        break;                                      // one device sink feeds the output
    }
}

static void *render_thread(void *arg) {
    Renderer *r = arg;
    pthread_setname_np("audren");
    for (;;) {
        pthread_mutex_lock(&r->lock);
        uint64_t t0 = g_alog ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
        if (r->started) render_frame(r);
        else memset(r->out, 0, r->n * 2 * sizeof(float));   // stopped: silence
        if (g_alog) r->render_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
        r->frames++;
        uint64_t frames = r->frames;
        pthread_mutex_unlock(&r->lock);
        nx_event_signal_obj(r->ev);
        nx_audio_out_write(r->out, r->n);           // paces this loop (device clock or host clock)
        if (g_alog && frames % 2000 == 0) {
            nx_log("audren: frame %llu, %u voices playing, peak %.3f, %llu updates, %llu underruns, render %.1f us/frame",
                   (unsigned long long)frames, r->active_voices, r->peak, (unsigned long long)r->updates,
                   (unsigned long long)nx_audio_out_underruns(), r->render_ns / 2000.0 / 1000.0);
            r->render_ns = 0;
            r->peak = 0;
            char line[1024];
            int len = 0;
            for (uint32_t i = 0; i < r->p.effect_count && len < 900; i++) {
                Effect *e = &r->effects[i];
                if (!e->type) continue;
                double n = 2000.0 * r->n * 32768.0 * 32768.0;
                len += snprintf(line + len, sizeof line - len, " %u:t%u/m%d %.1f->%.1f", i, e->type, e->mix_id,
                                10 * log10(e->e_in / n + 1e-12), 10 * log10(e->e_out / n + 1e-12));
                e->e_in = e->e_out = 0;
            }
            nx_log("audren: effects (index:type/mix in->out dBFS)%s", line);
            int hist[64] = {0}, voices_spl = 0;
            for (uint32_t i = 0; i < r->p.voice_count; i++) {
                Voice *v = &r->voices[i];
                if (!v->in_use || v->splitter_id == UNUSED_SPLITTER || v->splitter_id >= r->p.splitter_count) continue;
                voices_spl++;
                for (int k = 0; k < r->spl[v->splitter_id].count; k++) {
                    SplDest *d = spl_dest(r, v->splitter_id, k);
                    if (!d || !d->used || d->dest < 0 || d->dest >= 64) continue;
                    float sum = 0;
                    for (int j = 0; j < MIXBUF_MAX; j++) sum += fabsf(d->vol[j]);
                    if (sum > 0) hist[d->dest]++;
                }
            }
            len = 0;
            for (int i = 0; i < 64; i++) if (hist[i]) len += snprintf(line + len, sizeof line - len, " m%d:%d", i, hist[i]);
            nx_log("audren: %d voices on splitters; live destinations per mix:%s", voices_spl, line);
            len = 0;
            for (int i = 0; i < r->mix_count && len < 900; i++) {
                Mix *m = &r->mixes[i];
                if (m->used) len += snprintf(line + len, sizeof line - len, " m%d[%u bufs vol %.2f -> %d/%d]", i, m->buf_count, m->vol,
                                             m->dest_mix == UNUSED_MIX ? -1 : m->dest_mix, m->dest_spl == UNUSED_SPLITTER ? -1 : (int)m->dest_spl);
            }
            nx_log("audren: mixes:%s", line);
        }
    }
    return NULL;
}

// ---- IPC -----------------------------------------------------------------------------------------

static void get_work_buffer_size(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    RendererParams p;
    memcpy(&p, rq->data, sizeof p);
    uint64_t size = 0x4000 + (uint64_t)p.voice_count * 0x1000 + (uint64_t)p.mix_buffer_count * p.sample_count * 4 +
                    (uint64_t)(p.effect_count + p.sink_count + p.submix_count) * 0x1000 + 0x100000;
    OUT(rs, (size + 0xFFF) & ~0xFFFull);
}

static void open_renderer(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    g_alog = getenv("NXRT_AUDIOLOG") != NULL;
    g_vlog = getenv("NXRT_VOICELOG") != NULL;
    Renderer *r = calloc(1, sizeof *r);
    memcpy(&r->p, rq->data, sizeof r->p);
    RendererParams *p = &r->p;
    nx_log("audren: OpenAudioRenderer(%u Hz, %u samples, %u mix buffers, %u submixes, %u voices, %u sinks, "
           "%u effects, %u splitters / %u destinations, revision %#x)",
           p->sample_rate, p->sample_count, p->mix_buffer_count, p->submix_count, p->voice_count, p->sink_count,
           p->effect_count, p->splitter_count, p->splitter_dest_count, p->revision);
    if (p->sample_rate != 48000 || p->sample_count != 240)
        nx_log("audren: only 48 kHz / 240-sample frames are rendered; this renderer outputs silence");
    r->n = p->sample_count ? p->sample_count : 240;
    r->mix_count = (int)p->submix_count + 1;
    r->pool_count = (int)(p->effect_count + p->voice_count * 4);
    pthread_mutex_init(&r->lock, NULL);
    r->voices = calloc(p->voice_count + 1, sizeof(Voice));
    for (uint32_t i = 0; i < p->voice_count; i++) voice_init(&r->voices[i]), r->voices[i].index = (int)i;
    r->res = calloc(p->voice_count + 1, sizeof(ChanRes));
    r->mixes = calloc(r->mix_count, sizeof(Mix));
    for (int i = 0; i < r->mix_count; i++) {
        r->mixes[i].id = i;
        r->mixes[i].dest_mix = UNUSED_MIX;
        r->mixes[i].dest_spl = UNUSED_SPLITTER;
    }
    r->effects = calloc(p->effect_count + 1, sizeof(Effect));
    r->spl = calloc(p->splitter_count + 1, sizeof(Splitter));
    r->dst = calloc(p->splitter_dest_count + 1, sizeof(SplDest));
    r->sinks = calloc(p->sink_count + 1, sizeof(Sink));
    r->pools = calloc(r->pool_count + 1, sizeof(Pool));
    r->buf = calloc((size_t)(p->mix_buffer_count + 6) * r->n, sizeof(float));
    r->depop = calloc(p->mix_buffer_count + 1, sizeof(float));
    r->last = calloc((size_t)(p->voice_count + 1) * 6 * (p->mix_buffer_count + 1), sizeof(float));
    r->tmp = calloc(r->n, sizeof(float));
    r->out = calloc(r->n * 2, sizeof(float));
    if (p->sample_rate != 48000 || p->sample_count != 240) p->voice_count = 0;   // silent fallback
    r->has_device = nx_audio_out_open();
    r->ev = nx_event_new_readable(&r->ev_handle);
    pthread_t t;
    pthread_create(&t, NULL, render_thread, r);
    pthread_detach(t);
    ipc_push_object(rs, nx_obj_new(&svc_audren, "IAudioRenderer", r));
}

static void get_device_service(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    ipc_push_object(rs, nx_obj_new(&svc_audren, "IAudioDevice", NULL));
}

static Renderer *R(SvcObj *o) { return o->state; }
static void r_sample_rate(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, R(o)->p.sample_rate); }
static void r_sample_count(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, R(o)->p.sample_count); }
static void r_mix_count(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, R(o)->p.mix_buffer_count); }
static void r_state(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)(R(o)->started ? 0 : 1)); }
static void r_start(SvcObj *o, IpcReq *rq, IpcResp *rs) { R(o)->started = 1; }
static void r_stop(SvcObj *o, IpcReq *rq, IpcResp *rs) { R(o)->started = 0; }
static void r_event(SvcObj *o, IpcReq *rq, IpcResp *rs) { ipc_push_copy(rs, R(o)->ev_handle); }
static void r_time_limit(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)100); }

static void r_request_update(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    Renderer *r = R(o);
    IpcBuf *in = rq->num_a ? &rq->a[0] : rq->num_x ? &rq->x[0] : NULL;
    IpcBuf *out = rq->num_b ? &rq->b[0] : rq->num_c ? &rq->c[0] : NULL;
    if (!in || !out || !out->addr || !in->addr || in->size < 0x40) return;
    const char *dump = getenv("NXRT_AUDDUMP");      // NXRT_AUDDUMP=<prefix>: raw inputs of updates 1-3, 3000
    if (dump && (r->updates < 3 || r->updates == 2999)) {
        char path[512];
        snprintf(path, sizeof path, "%s_%llu.bin", dump, (unsigned long long)r->updates + 1);
        FILE *f = fopen(path, "wb");
        if (f) { fwrite((void *)in->addr, 1, in->size, f); fclose(f); }
    }
    request_update(r, (const uint8_t *)in->addr, in->size, (uint8_t *)out->addr, out->size);
}

// IAudioDevice
static void dev_list_names(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    IpcBuf *b = rq->num_b ? &rq->b[0] : &rq->c[0];
    if (b->addr && b->size >= 0x100) {
        memset((void *)b->addr, 0, 0x100);
        strcpy((char *)b->addr, "AudioTvOutput");
    }
    OUT(rs, (uint32_t)1);
}
static void dev_active_name(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    IpcBuf *b = rq->num_b ? &rq->b[0] : &rq->c[0];
    if (b->addr && b->size >= 0x100) {
        memset((void *)b->addr, 0, 0x100);
        strcpy((char *)b->addr, "AudioTvOutput");
    }
}
static void dev_volume(SvcObj *o, IpcReq *rq, IpcResp *rs) { float v = 1.0f; OUT(rs, v); }
static void dev_event(SvcObj *o, IpcReq *rq, IpcResp *rs) {
    uint32_t h;
    nx_event_new_readable(&h);
    ipc_push_copy(rs, h);
}
static void dev_channels(SvcObj *o, IpcReq *rq, IpcResp *rs) { OUT(rs, (uint32_t)2); }

static const IpcCmd cmds[] = {
    {NULL, 0, open_renderer},                             // OpenAudioRenderer
    {NULL, 1, get_work_buffer_size},                      // GetWorkBufferSize
    {NULL, 2, get_device_service},                        // GetAudioDeviceService
    {NULL, 4, get_device_service},                        // GetAudioDeviceServiceWithRevisionInfo
    {"IAudioRenderer", 0, r_sample_rate},
    {"IAudioRenderer", 1, r_sample_count},
    {"IAudioRenderer", 2, r_mix_count},
    {"IAudioRenderer", 3, r_state},
    {"IAudioRenderer", 4, r_request_update},
    {"IAudioRenderer", 5, r_start},
    {"IAudioRenderer", 6, r_stop},
    {"IAudioRenderer", 7, r_event},                       // QuerySystemEvent
    {"IAudioRenderer", 8, ok},                            // SetRenderingTimeLimit
    {"IAudioRenderer", 9, r_time_limit},                  // GetRenderingTimeLimit
    {"IAudioRenderer", 10, r_request_update},             // RequestUpdateAuto
    {"IAudioDevice", 0, dev_list_names},
    {"IAudioDevice", 1, ok},                              // SetAudioDeviceOutputVolume
    {"IAudioDevice", 2, dev_volume},
    {"IAudioDevice", 3, dev_active_name},
    {"IAudioDevice", 4, dev_event},
    {"IAudioDevice", 5, dev_channels},
    {"IAudioDevice", 6, dev_list_names},
    {"IAudioDevice", 7, ok},
    {"IAudioDevice", 8, dev_volume},
    {"IAudioDevice", 10, dev_active_name},
    {"IAudioDevice", 11, dev_event},
    {"IAudioDevice", 12, dev_event},
    {"IAudioDevice", 13, dev_active_name},
    {0},
};
const ServiceDef svc_audren = {.name = "audren:u", .cmds = cmds};
