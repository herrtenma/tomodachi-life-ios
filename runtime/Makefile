CC      = clang
CFLAGS  = -O2 -g -Wall -Wextra -Wno-unused-parameter -Iinclude
SRCS    = src/main.c src/loader.c src/thread.c src/svc.c src/log.c src/mem.c src/kernel.c src/ipc.c src/content.c src/crash.c src/cores.c src/nvn.c \
          src/services/registry.c src/services/sm.c src/services/lm.c src/services/applet.c src/services/misc.c src/services/time.c src/services/fs.c src/services/nvdrv.c src/services/vi.c src/services/acc.c src/services/hid.c src/services/audio.c src/audio_out.c src/services/pl.c src/services/ldn.c src/gfx_metal.m src/host_ui.m src/gfx_textures.m src/gfx_bcdec.m src/gfx_cmd.m src/ui_touch.c \
          src/mac/ui_mac.m src/mac/launcher_mac.m src/mac/game_ui_mac.m src/mac/app_mac.m src/shaders.c src/save_import.m src/app_online.m src/shader_xlat.m src/nx_assets.m src/third_party.c src/svc_entry.S src/nvn_thunks.S src/probe_hooks.S
FRAMEWORKS = -framework Cocoa -framework Metal -framework MetalFX -framework QuartzCore -framework ImageIO -framework AudioToolbox -framework UniformTypeIdentifiers -framework Security -framework AVFoundation \
             -framework CoreText -framework GameController -lz
BUILD   = build
# On-device shader translator (xlat/, shader_xlat.m): Ryujinx's translator as a NativeAOT library + SPIRV-Cross.
.DEFAULT_GOAL := $(BUILD)/nxrt
XLAT    = xlat/build/osx-arm64
XLATLIB = $(XLAT)/libnxxlat.a $(XLAT)/nxxlat-boot.o -lc++ -licucore
$(XLAT)/libnxxlat.a:
	$(MAKE) -C xlat RID=osx-arm64

$(BUILD)/nxrt: $(SRCS) $(XLAT)/libnxxlat.a include/nxrt.h include/ipc.h include/audio_out.h include/gfx.h include/nvn_formats.h src/gfx_internal.h src/mac/ui_mac.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $(SRCS) $(FRAMEWORKS) $(XLATLIB)

# Static image (no JIT; the iOS way of loading the game): `make embed` [FPS=60] -> build/nxrt-embed.
# The game code is linked in from ../work/*.native.nso (tools/nxrecomp/embed.py); never distribute the result.
EMBED_PY = ../tools/nxrecomp/embed.py
WORK     = ../work
embed: $(BUILD)/nxrt-embed
$(BUILD)/image.s: $(EMBED_PY) $(wildcard $(WORK)/*.native.nso)
	@mkdir -p $(BUILD)
	/usr/bin/python3 $(EMBED_PY) $(WORK) $@ $(if $(filter 60,$(FPS)),--fps60)
$(BUILD)/nxrt-embed: $(SRCS) $(XLAT)/libnxxlat.a $(BUILD)/image.s include/nxrt.h include/ipc.h include/audio_out.h include/gfx.h include/nvn_formats.h src/gfx_internal.h
	$(CC) $(CFLAGS) -DNXRT_EMBED -fobjc-arc -o $@ $(SRCS) $(BUILD)/image.s $(FRAMEWORKS) $(XLATLIB) $(shell /usr/bin/python3 $(EMBED_PY) --ldflags)

# The Mac app: the same binary in "build/Tomodachi Life.app" (games category + Game Mode keys, so full screen turns on
# macOS Game Mode; the launcher defaults to full screen). It runs from this folder (Info.plist NxrtHome, set here):
# saves in ./data*, the game in ../work, the log in ./nxrt.log; bundle id "nxrt" = the same settings as the plain build. `make app` then open "build/Tomodachi Life.app".
APP = $(BUILD)/Tomodachi Life.app
app: $(BUILD)/nxrt src/mac/Info.plist
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS"
	cp $(BUILD)/nxrt "$(APP)/Contents/MacOS/nxrt"
	cp src/mac/Info.plist "$(APP)/Contents/Info.plist"
	plutil -replace NxrtHome -string "$(CURDIR)" "$(APP)/Contents/Info.plist"
	codesign -f -s - "$(APP)"
	@echo "built $(APP)"

clean:
	rm -rf $(BUILD)
.PHONY: clean embed app
