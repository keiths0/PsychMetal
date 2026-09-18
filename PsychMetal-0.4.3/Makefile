SHELL := /bin/zsh

SOURCE := PsychMetalCore.mm
OCTAVE_MEX := PsychMetalCore.mex
MATLAB_MEX := PsychMetalCore.mexmaca64
MATLAB_ROOT ?= /Applications/MATLAB_R2026a.app
SDKROOT := $(shell xcrun -sdk macosx --show-sdk-path)
# No OpenGL and no IOSurface as of 0.4.0: nothing in the core touches either.
FRAMEWORKS := -framework Cocoa -framework Metal -framework QuartzCore -framework CoreGraphics -framework Carbon
RELEASE_FLAGS := -O2 -DNDEBUG -Wall -Wextra -Wpedantic
DIST_DIR := dist/PsychMetal
HOST_ARCH := $(shell uname -m)

.PHONY: all check-arch octave matlab package clean test

all: octave matlab

check-arch:
	@test "$(HOST_ARCH)" = arm64 || { echo "PsychMetal currently supports Apple silicon (arm64) only."; exit 1; }

octave: check-arch $(OCTAVE_MEX)

$(OCTAVE_MEX): $(SOURCE) PsychMetalKeyboardQueue.h PsychMetalShaders.h
	clang++ -x objective-c++ -std=c++17 -fobjc-arc -fPIC -mmacosx-version-min=14.0 $(RELEASE_FLAGS) \
	  $$(mkoctfile -p INCFLAGS) -c $< -o PsychMetalCore.octave.o
	MACOSX_DEPLOYMENT_TARGET=14.0 LDFLAGS="$$(mkoctfile -p LDFLAGS) -mmacosx-version-min=14.0 $(FRAMEWORKS)" mkoctfile --mex PsychMetalCore.octave.o -o $@
	@$(RM) PsychMetalCore.octave.o

matlab: check-arch $(MATLAB_MEX)

$(MATLAB_MEX): $(SOURCE) PsychMetalKeyboardQueue.h PsychMetalShaders.h
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

# Stage only the checksummed, tested release payload; never rebuild implicitly.
package:
	python3 tests/package_release.py . "$(DIST_DIR)"

clean:
	$(RM) PsychMetalCore.octave.o PsychMetalCore.matlab.o $(OCTAVE_MEX) $(MATLAB_MEX)

PsychMetalShaders.h: PsychMetalShaders.metal tests/embed_shaders.py
	python3 tests/embed_shaders.py

test: octave
	python3 tests/run_tests.py
