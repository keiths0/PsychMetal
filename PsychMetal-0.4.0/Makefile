SHELL := /bin/zsh

SOURCE := PsychMetalCore.mm
OCTAVE_MEX := PsychMetalCore.mex
MATLAB_MEX := PsychMetalCore.mexmaca64
MATLAB_ROOT ?= /Applications/MATLAB_R2026a.app
SDKROOT := $(shell xcrun -sdk macosx --show-sdk-path)
# No OpenGL and no IOSurface as of 0.4.0: nothing in the core touches either.
FRAMEWORKS := -framework Cocoa -framework Metal -framework QuartzCore -framework CoreGraphics
RELEASE_FLAGS := -O2 -DNDEBUG -Wall -Wextra -Wpedantic
DIST_DIR := dist/PsychMetal
PACKAGE_FILES := PsychMetal.m PsychMetalTearTest.m PsychMetalWhenTest.m \
	PsychMetalLatchTest.m PsychMetalDrawableCompare.m \
	PTBGeometryCompare.m PsychMetalRateCompare.m PsychMetalWarmupLength.m \
	PsychMetalMinimalDemo.m PsychMetalMouseRectDemo.m PsychMetalBlobDemo.m PsychMetalTextureDemo.m \
	PsychMetalDotDemo.m PsychMetalGaborDemo.m PsychMetalNoiseDemo.m \
	PsychMetalKbDemo.m \
	PTBTimingTest.m PTBWhenBug.m \
	PsychMetalFrameStats.m \
	PsychMetalInputLatencyProbe.m PsychMetalCompositorProbe.m \
	PsychMetalScheduleSweep.m PsychMetalMixedCadenceProbe.m \
	PsychMetalCallerSleepProbe.m PsychMetalInventoryTest.m \
	PsychMetalCore.mm PsychMetalCore.mex \
	PsychMetalCore.mexmaca64 Makefile README.md RELEASE-0.4.0.txt \
	LICENSE CHANGELOG.md VERSION .gitignore
HOST_ARCH := $(shell uname -m)

.PHONY: all check-arch octave matlab package clean

all: octave matlab

check-arch:
	@test "$(HOST_ARCH)" = arm64 || { echo "PsychMetal currently supports Apple silicon (arm64) only."; exit 1; }

octave: check-arch $(OCTAVE_MEX)

$(OCTAVE_MEX): $(SOURCE)
	clang++ -x objective-c++ -std=c++17 -fobjc-arc -fPIC $(RELEASE_FLAGS) \
	  $$(mkoctfile -p INCFLAGS) -c $< -o PsychMetalCore.octave.o
	LDFLAGS="$$(mkoctfile -p LDFLAGS) $(FRAMEWORKS)" mkoctfile --mex PsychMetalCore.octave.o -o $@
	@$(RM) PsychMetalCore.octave.o

matlab: check-arch $(MATLAB_MEX)

$(MATLAB_MEX): $(SOURCE)
	test -d "$(MATLAB_ROOT)" || { echo "Set MATLAB_ROOT to the MATLAB application directory."; exit 1; }
	xcrun -sdk macosx clang++ -x objective-c++ -c -DMATLAB_MEX_FILE \
	  -I"$(MATLAB_ROOT)/extern/include" -I"$(MATLAB_ROOT)/simulink/include" \
	  -fno-common -arch arm64 -mmacosx-version-min=14.0 -fexceptions \
	  -isysroot "$(SDKROOT)" -fwrapv -ffp-contract=off -fobjc-arc \
	  -std=c++17 -stdlib=libc++ $(RELEASE_FLAGS) $< -o PsychMetalCore.matlab.o
	xcrun -sdk macosx clang++ -Wl,-twolevel_namespace -arch arm64 \
	  -mmacosx-version-min=14.0 -Wl,-syslibroot,"$(SDKROOT)" -bundle -stdlib=libc++ \
	  -Wl,-exported_symbols_list,"$(MATLAB_ROOT)/extern/lib/maca64/mexFunction.map" \
	  PsychMetalCore.matlab.o -L"$(MATLAB_ROOT)/bin/maca64" \
	  -weak-lmx -weak-lmex -weak-lmat -L"$(MATLAB_ROOT)/extern/bin/maca64" \
	  -weak-lMatlabDataArray $(FRAMEWORKS) -o $@
	@$(RM) PsychMetalCore.matlab.o

package: all
	$(RM) -r "$(DIST_DIR)"
	mkdir -p "$(DIST_DIR)"
	cp -f $(PACKAGE_FILES) "$(DIST_DIR)/"
	@echo "Path-ready package: $(DIST_DIR)"

clean:
	$(RM) PsychMetalCore.octave.o PsychMetalCore.matlab.o $(OCTAVE_MEX) $(MATLAB_MEX)
