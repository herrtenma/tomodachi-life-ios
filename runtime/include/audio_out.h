// Host audio output (audio_out.c): 48 kHz stereo float frames to CoreAudio.
#pragma once
#include <stdint.h>

int nx_audio_out_open(void);                                   // 1 if a device plays the audio
void nx_audio_out_write(const float *stereo, uint32_t frames); // blocks to pace the caller
uint64_t nx_audio_out_underruns(void);
