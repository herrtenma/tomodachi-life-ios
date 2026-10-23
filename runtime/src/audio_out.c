// Host audio output: a stereo float ring buffer drained by a CoreAudio output unit (RemoteIO on
// iOS, the default output device on macOS). The renderer thread writes 5 ms frames and is paced
// by the ring: nx_audio_out_write blocks while more than `target` frames are queued, so the guest's
// audio frame event runs on the device clock like the Switch DSP. Without a device (headless runs,
// NXRT_AUDIO=0, or the unit failing to start) writes are paced by the host clock instead.
#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "nxrt.h"
#include "audio_out.h"

#define RING_FRAMES 16384                 // stereo sample frames (~340 ms); power of two
static float g_ring[RING_FRAMES * 2];
static _Atomic uint64_t g_wpos, g_rpos;   // sample frames written / read (monotonic)
static AudioComponentInstance g_unit;
static int g_have_device = -1;
static uint32_t g_target;                 // max sample frames queued before a write blocks
static _Atomic uint64_t g_underruns;
static FILE *g_wav;
static uint64_t g_wav_frames;

static OSStatus render_cb(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 nframes, AudioBufferList *io) {
    float *out = io->mBuffers[0].mData;
    // Game paused (under the launcher, or the app in the background): silence, and the ring isn't drained, so the
    // renderer thread waits and the music resumes where it stopped. NXRT_AUDIO_PLAY_PAUSED=1: keeps playing (old).
    extern volatile int g_gfx_background;
    static int play_paused = -1;
    if (play_paused < 0) play_paused = getenv("NXRT_AUDIO_PLAY_PAUSED") != NULL;
    if (g_gfx_background && !play_paused) {
        memset(out, 0, (size_t)nframes * 2 * sizeof(float));
        return noErr;
    }
    uint64_t r = atomic_load_explicit(&g_rpos, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&g_wpos, memory_order_acquire);
    uint64_t avail = w - r, n = avail < nframes ? avail : nframes;
    for (uint64_t i = 0; i < n; i++) {
        uint64_t k = (r + i) & (RING_FRAMES - 1);
        out[2 * i] = g_ring[2 * k];
        out[2 * i + 1] = g_ring[2 * k + 1];
    }
    if (n < nframes) {
        memset(out + 2 * n, 0, (nframes - n) * 2 * sizeof(float));
        if (r) atomic_fetch_add_explicit(&g_underruns, 1, memory_order_relaxed);
    }
    atomic_store_explicit(&g_rpos, r + n, memory_order_release);
    return noErr;
}

static int open_device(void) {
    AudioComponentDescription d = {.componentType = kAudioUnitType_Output,
#if TARGET_OS_IPHONE
                                   .componentSubType = kAudioUnitSubType_RemoteIO,
#else
                                   .componentSubType = kAudioUnitSubType_DefaultOutput,
#endif
                                   .componentManufacturer = kAudioUnitManufacturer_Apple};
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    if (!comp || AudioComponentInstanceNew(comp, &g_unit)) return 0;
    AudioStreamBasicDescription f = {.mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM,
                                     .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                     .mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8,
                                     .mChannelsPerFrame = 2, .mBitsPerChannel = 32};
    AURenderCallbackStruct cb = {.inputProc = render_cb};
    if (AudioUnitSetProperty(g_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) ||
        AudioUnitSetProperty(g_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) ||
        AudioUnitInitialize(g_unit) || AudioOutputUnitStart(g_unit)) {
        AudioComponentInstanceDispose(g_unit);
        return 0;
    }
    return 1;
}

static void wav_header(void) {
    uint32_t data = (uint32_t)(g_wav_frames * 4);
    uint8_t h[44];
    memcpy(h, "RIFF", 4);
    uint32_t v = 36 + data; memcpy(h + 4, &v, 4);
    memcpy(h + 8, "WAVEfmt ", 8);
    v = 16; memcpy(h + 16, &v, 4);
    uint16_t s = 1; memcpy(h + 20, &s, 2);         // PCM
    s = 2; memcpy(h + 22, &s, 2);                  // stereo
    v = 48000; memcpy(h + 24, &v, 4);
    v = 48000 * 4; memcpy(h + 28, &v, 4);
    s = 4; memcpy(h + 32, &s, 2);
    s = 16; memcpy(h + 34, &s, 2);
    memcpy(h + 36, "data", 4);
    memcpy(h + 40, &data, 4);
    long pos = ftell(g_wav);
    fseek(g_wav, 0, SEEK_SET);
    fwrite(h, 1, 44, g_wav);
    fseek(g_wav, pos, SEEK_SET);
    fflush(g_wav);
}

int nx_audio_out_open(void) {
    if (g_have_device >= 0) return g_have_device;
    const char *e = getenv("NXRT_AUDIO");
    int want = e ? atoi(e) != 0 : !getenv("NXRT_HEADLESS");
    const char *lat = getenv("NXRT_AUDIO_LATENCY_MS");   // queued audio before a write blocks
    g_target = (uint32_t)((lat ? atoi(lat) : 40) * 48);
    g_have_device = want && open_device();
    const char *wav = getenv("NXRT_AUDIO_WAV");          // capture of everything the renderer outputs
    if (wav && (g_wav = fopen(wav, "wb"))) wav_header();
    nx_log("audio: output %s (latency target %u ms)%s%s", g_have_device ? "CoreAudio 48 kHz stereo" : "none (host-clock pacing)",
           g_target / 48, g_wav ? ", WAV capture to " : "", g_wav ? wav : "");
    return g_have_device;
}

static uint64_t now_ns(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

void nx_audio_out_write(const float *stereo, uint32_t frames) {
    {   // level report every 10 s, so a silent run shows whether silence left the renderer or got lost after it
        static float peak;
        static uint64_t total;
        for (uint32_t i = 0; i < frames * 2; i++) {
            float a = stereo[i] < 0 ? -stereo[i] : stereo[i];
            if (a > peak) peak = a;
        }
        if ((total += frames) >= 480000) {
            nx_log("audio: output peak %.3f over 10 s, %s, %llu underruns", peak, g_have_device ? "device" : "no device",
                   (unsigned long long)atomic_load(&g_underruns));
            peak = 0, total = 0;
        }
    }
    if (g_wav) {
        int16_t tmp[2 * 1024];
        for (uint32_t i = 0; i < frames * 2 && i < 2048; i++) {
            float x = stereo[i] * 32768.0f;
            tmp[i] = (int16_t)(x > 32767 ? 32767 : x < -32768 ? -32768 : x);
        }
        fwrite(tmp, 4, frames < 1024 ? frames : 1024, g_wav);
        uint64_t before = g_wav_frames;
        g_wav_frames += frames < 1024 ? frames : 1024;
        if (before / 24000 != g_wav_frames / 24000) wav_header();   // keep the header valid twice a second
    }
    if (!g_have_device) {                       // pace by the host clock: one call per frame time
        static uint64_t next;
        uint64_t t = now_ns(), step = (uint64_t)frames * 1000000000ull / 48000;
        if (!next || t > next + 100000000ull) next = t;   // start, or fell >100 ms behind: resync
        next += step;
        if (next > t) {
            struct timespec ts = {(time_t)((next - t) / 1000000000ull), (long)((next - t) % 1000000000ull)};
            nanosleep(&ts, NULL);
        }
        return;
    }
    uint64_t w = atomic_load_explicit(&g_wpos, memory_order_relaxed);
    while (w - atomic_load_explicit(&g_rpos, memory_order_acquire) + frames > g_target) usleep(1000);
    for (uint32_t i = 0; i < frames; i++) {
        uint64_t k = (w + i) & (RING_FRAMES - 1);
        g_ring[2 * k] = stereo[2 * i];
        g_ring[2 * k + 1] = stereo[2 * i + 1];
    }
    atomic_store_explicit(&g_wpos, w + frames, memory_order_release);
}

uint64_t nx_audio_out_underruns(void) { return atomic_load(&g_underruns); }
