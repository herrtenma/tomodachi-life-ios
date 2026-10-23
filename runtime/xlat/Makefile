# On-device shader translator (see shader_xlat.m): NativeAOT static library + SPIRV-Cross, per target.
#   make RID=osx-arm64 | ios-arm64 | iossimulator-arm64   -> build/<RID>/libnxxlat.a (everything the app links)
#   make check                                            -> translate a shader dump with the Mac build, compare
# Needs the .NET 10 SDK (DOTNET=...) and, for iOS, an iPhoneOS SDK (SDK=..., also used as the NativeAOT sysroot).
DOTNET  ?= dotnet
RID     ?= osx-arm64
SDK     ?= $(HOME)/sdks/iPhoneOS16.5.sdk
MINIOS  ?= 16.4
BUILD    = build/$(RID)
NUGET   ?= $(HOME)/.nuget/packages
AOTVER   = $(shell $(DOTNET) --list-runtimes | awk '/Microsoft.NETCore.App/ {v=$$2} END {print v}')
AOTPACK  = $(NUGET)/microsoft.netcore.app.runtime.nativeaot.$(RID)/$(AOTVER)/runtimes/$(RID)/native
# NativeAOT runtime pieces the library needs (Workstation GC, no event pipe, invariant globalization)
AOTLIBS  = libRuntime.WorkstationGC.a libeventpipe-disabled.a libstandalonegc-disabled.a \
           libaotminipal.a libstdc++compat.a libSystem.Native.a libSystem.Globalization.Native.a

ifeq ($(RID),osx-arm64)
  TARGET  = -target arm64-apple-macos13.0
  AOTARGS =
else ifeq ($(RID),iossimulator-arm64)
  SIMSDK ?= $(shell xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
  TARGET  = -target arm64-apple-ios$(MINIOS)-simulator -isysroot $(SIMSDK)
  AOTARGS = -p:SysRoot=$(SIMSDK) -p:AppleMinOSVersion=$(MINIOS)
else
  TARGET  = -target arm64-apple-ios$(MINIOS) -isysroot $(SDK)
  AOTARGS = -p:SysRoot=$(SDK) -p:AppleMinOSVersion=$(MINIOS)
endif

SCDIR    = ../../third_party/spirv-cross
SCSRC    = $(filter-out $(SCDIR)/spirv_cross_c.cpp $(SCDIR)/main.cpp,$(wildcard $(SCDIR)/*.cpp))
SCOBJ    = $(patsubst $(SCDIR)/%.cpp,$(BUILD)/sc/%.o,$(SCSRC)) $(BUILD)/sc/xlat_msl.o
CS       = $(wildcard *.cs) $(shell find ../../third_party/ryujinx-shader -name '*.cs')

all: $(BUILD)/libnxxlat.a

$(BUILD)/aot/NxXlat.a: $(CS) NxXlat.csproj
	$(DOTNET) publish NxXlat.csproj -c Release -r $(RID) $(AOTARGS) -o $(BUILD)/aot

$(BUILD)/sc/%.o: $(SCDIR)/%.cpp
	@mkdir -p $(BUILD)/sc
	clang++ $(TARGET) -std=c++17 -O2 -c -o $@ $<
$(BUILD)/sc/xlat_msl.o: xlat_msl.cpp $(SCDIR)/main.cpp
	@mkdir -p $(BUILD)/sc
	clang++ $(TARGET) -std=c++17 -O2 -Wno-everything -c -o $@ xlat_msl.cpp

# One archive with the translator, its NativeAOT runtime and SPIRV-Cross, plus nxxlat-boot.o: the runtime's start-up
# (a load-time constructor nothing references, so it must be linked as an object, not from an archive). Link both with
# -lc++ -lz -licucore -framework Foundation -framework Security.
$(BUILD)/libnxxlat.a: $(BUILD)/aot/NxXlat.a $(SCOBJ)
	cp $(AOTPACK)/libbootstrapperdll.o $(BUILD)/nxxlat-boot.o
	rm -rf $(BUILD)/merge && mkdir -p $(BUILD)/merge
	cp $(BUILD)/aot/NxXlat.a $(SCOBJ) $(addprefix $(AOTPACK)/,$(AOTLIBS)) $(BUILD)/merge/
	libtool -static -no_warning_for_no_symbols -o $@ $(BUILD)/merge/*.a $(BUILD)/merge/*.o
	@ls -lh $@

# Mac check against a shader dump made with the offline pipeline (NXRT_SHADERDUMP + build_shaders.sh in the dev tree):
#   make check DUMP=<dir with bin/, msl/, spv/>
check:
	$(MAKE) RID=osx-arm64
	clang -target arm64-apple-macos13.0 -O2 -fobjc-arc -o build/osx-arm64/xlatcheck xlatcheck.m build/osx-arm64/libnxxlat.a build/osx-arm64/nxxlat-boot.o \
	  -lc++ -lz -licucore -framework Foundation -framework Security
	build/osx-arm64/xlatcheck $(DUMP)

clean:
	rm -rf build bin obj
.PHONY: all check clean
