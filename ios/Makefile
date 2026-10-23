# The iPhone app without Xcode: the Command Line Tools' clang/ld + an iPhoneOS SDK (theos/sdks iPhoneOS16.5.sdk).
#   make        -> build/Payload/nxrt.app, the base app: the runtime with EMPTY game slots (embed.py --empty); no game
#                  code, no keys, no game shaders in it. It can't run until the packager fills the slots.
#   make pack   -> build/tomodachi.nxport, the port pack for the packager app (nx-packager): the base app, the patch
#                  (../port, from tools/nxrecomp/mkpack.py) and nxport.json (the game version it needs).
#   make sim    -> build-sim/..., the same for the iOS Simulator (Xcode's SDK: SIMDEV).
SDK     ?= $(HOME)/sdks/iPhoneOS16.5.sdk
TRIPLE  ?= arm64-apple-ios16.4
CC       = clang
ARCH     = -target $(TRIPLE) -mcpu=apple-a14 -isysroot $(SDK)   # A14 and later (the 6 GB iPhones start at A14)
# -ffile-prefix-map: no paths of the build machine in the binary
CFLAGS   = $(ARCH) -O2 -g -Wall -Wextra -Wno-unused-parameter -I../runtime/include -I../runtime/src -DNXRT_EMBED=1 \
           -ffile-prefix-map=$(abspath ..)=.
SRCS     = $(filter-out ../runtime/src/host_ui.m, \
             $(wildcard ../runtime/src/*.c ../runtime/src/*.m ../runtime/src/*.S ../runtime/src/services/*.c ../runtime/src/ios/*.m))
FRAMEWORKS = -framework UIKit -framework Metal $(if $(findstring simulator,$(TRIPLE)),,-framework MetalFX) -framework QuartzCore -framework GameController -framework CoreHaptics \
             -framework AudioToolbox -framework ImageIO -framework CoreGraphics -framework CoreText -framework UniformTypeIdentifiers -framework Foundation -framework Security -framework AVFoundation -lz
EMBED_PY = ../tools/nxrecomp/embed.py
LAYOUT   = ../port/layout.json
BUILD   ?= build
SIMDEV  ?= /Volumes/Xcode/Xcode.app/Contents/Developer
APP      = $(BUILD)/Payload/nxrt.app
# On-device shader translator (../runtime/xlat)
XRID     = $(if $(findstring simulator,$(TRIPLE)),iossimulator-arm64,ios-arm64)
XLAT     = ../runtime/xlat/build/$(XRID)
VERSION  = $(shell plutil -extract CFBundleShortVersionString raw Info.plist)

all: $(APP)

sim:
	DEVELOPER_DIR=$(SIMDEV) $(MAKE) BUILD=build-sim TRIPLE=arm64-apple-ios16.4-simulator \
	  SDK=$$(DEVELOPER_DIR=$(SIMDEV) xcrun --sdk iphonesimulator --show-sdk-path) CC="xcrun clang" build-sim/Payload/nxrt.app

$(SDK):
	@echo "iPhoneOS SDK missing: $(SDK) (https://github.com/theos/sdks/releases, iPhoneOS16.5.sdk.tar.xz into ~/sdks)"; exit 1

$(XLAT)/libnxxlat.a:
	$(MAKE) -C ../runtime/xlat RID=$(XRID) SDK=$(SDK)

$(BUILD)/image.s: $(EMBED_PY) $(LAYOUT)
	@mkdir -p $(BUILD)
	/usr/bin/python3 $(EMBED_PY) --empty $(LAYOUT) $@

$(BUILD)/nxrt: $(SDK) $(SRCS) $(BUILD)/image.s $(XLAT)/libnxxlat.a $(wildcard ../runtime/include/*.h ../runtime/src/*.h)
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $(SRCS) $(BUILD)/image.s $(FRAMEWORKS) $(XLAT)/libnxxlat.a $(XLAT)/nxxlat-boot.o \
	  -lc++ -licucore $$(/usr/bin/python3 $(EMBED_PY) --ldflags)

# The app: binary, Info.plist, launcher music, ad-hoc signature with the entitlements (the installer re-signs it with
# the user's Apple ID and keeps what the account allows).
$(APP): $(BUILD)/nxrt Info.plist nxrt.entitlements $(wildcard icon/*.png) $(wildcard music/*.m4a)
	rm -rf $(BUILD)/Payload
	mkdir -p $(APP)/music
	cp $(BUILD)/nxrt Info.plist $(APP)/
	cp music/*.m4a $(APP)/music/
	cp icon/AppIcon60x60*.png icon/AppIcon76x76*.png icon/AppIcon83.5x83.5*.png $(APP)/
	if [ -n "$(findstring simulator,$(TRIPLE))" ]; then \
	  plutil -replace CFBundleSupportedPlatforms -json '["iPhoneSimulator"]' $(APP)/Info.plist; \
	  plutil -replace DTPlatformName -string iphonesimulator $(APP)/Info.plist; \
	  plutil -replace DTSDKName -string iphonesimulator $(APP)/Info.plist; fi
	# The simulator app is a Mac process: macOS refuses ad-hoc binaries with these restricted entitlements.
	codesign -f -s - $(if $(findstring simulator,$(TRIPLE)),,--entitlements nxrt.entitlements) $(APP)
	touch $(APP)

# The port pack: a zip of Payload/ (the base app), nxport.json and the patch.
pack: $(BUILD)/tomodachi.nxport
$(BUILD)/tomodachi.nxport: $(APP) ../port/nxport.in.json ../port/modules.json $(LAYOUT) $(wildcard ../port/patches/* ../port/modules/*)
	rm -rf $(BUILD)/pack && mkdir -p $(BUILD)/pack
	/usr/bin/python3 ../port/mknxport.py ../port $(VERSION) $(BUILD)/pack/nxport.json
	cp -R ../port/patches ../port/modules $(BUILD)/pack/
	ditto $(BUILD)/Payload $(BUILD)/pack/Payload
	rm -f $@ && cd $(BUILD)/pack && zip -qry -X ../tomodachi.nxport nxport.json patches modules Payload
	@ls -lh $@

clean:
	rm -rf build build-sim
.PHONY: all clean sim pack
