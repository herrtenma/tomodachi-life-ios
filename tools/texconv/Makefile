# texconv: BC -> ASTC in Tomodachi's RomFS for the iPhone (see texconv.c). Ported from ~/Desktop/botw-ios/tools/texconv.
# Needs astc-encoder 5.2.0 (BOTW's checkout by default; ASTCDIR=<dir> to use another:
#   git clone --depth 1 --branch 5.2.0 https://github.com/ARM-software/astc-encoder.git <dir>) and zstd (brew install zstd).
ASTCDIR ?= $(HOME)/Desktop/botw-ios/tools/ext/astc-encoder
ASTC    = $(ASTCDIR)/Source
ZSTD   ?= /opt/homebrew/opt/zstd
BUILD   = build
ASTCSRC = $(filter-out $(ASTC)/astcenccli%,$(wildcard $(ASTC)/astcenc_*.cpp))
ASTCOBJ = $(patsubst $(ASTC)/%.cpp,$(BUILD)/%.o,$(ASTCSRC))
ASTCDEF = -DASTCENC_NEON=1 -DASTCENC_SSE=0 -DASTCENC_AVX=0 -DASTCENC_POPCNT=0 -DASTCENC_F16C=0 -DASTCENC_SVE=0 -DNDEBUG

$(BUILD)/texconv: texconv.c $(BUILD)/astc_wrap.o $(ASTCOBJ) ../../runtime/third_party/bcdec.h
	clang -O2 -g -Wall -Wextra -I$(ZSTD)/include -o $@ texconv.c $(BUILD)/astc_wrap.o $(ASTCOBJ) $(ZSTD)/lib/libzstd.a -lc++ -lpthread
$(BUILD)/astc_wrap.o: astc_wrap.cpp
	@mkdir -p $(BUILD)
	clang++ -std=c++17 -O3 $(ASTCDEF) -I$(ASTC) -c -o $@ $<
$(BUILD)/%.o: $(ASTC)/%.cpp
	@mkdir -p $(BUILD)
	clang++ -std=c++17 -O3 -ffp-contract=fast $(ASTCDEF) -c -o $@ $<
clean:
	rm -rf $(BUILD)
.PHONY: clean
