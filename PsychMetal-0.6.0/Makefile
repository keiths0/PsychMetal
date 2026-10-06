SHELL := /bin/zsh

# One engine, three front ends. The engine is PsychMetalEngine.mm (Metal,
# AppKit) plus PsychMetalShared.cpp (plain C++); each front end links both.
ENGINE := PsychMetalEngine.mm
SHARED := PsychMetalShared.cpp
MEX_FRONTEND := PsychMetalMex.cpp
PY_FRONTEND := PsychMetalPython.cpp
HEADERS := PsychMetalEngine.h PsychMetalInternal.h PsychMetalKeyboardQueue.h PsychMetalShaders.h
OCTAVE_MEX := PsychMetalCore.mex
MATLAB_MEX := PsychMetalCore.mexmaca64
MATLAB_ROOT ?= /Applications/MATLAB_R2026a.app
PYTHON ?= python3
SDKROOT := $(shell xcrun -sdk macosx --show-sdk-path 2>/dev/null)
# No OpenGL and no IOSurface: nothing in the engine touches either.
FRAMEWORKS := -framework Cocoa -framework Metal -framework QuartzCore -framework CoreGraphics -framework Carbon -framework CoreText -framework IOKit
RELEASE_FLAGS := -O2 -DNDEBUG -Wall -Wextra -Wpedantic
DIST_DIR := dist/PsychMetal
HOST_ARCH := $(shell uname -m)
# Never add this directory with -I: on a case-insensitive disk its VERSION file
# would answer the C++ library's #include <version>. Sources include each other
# with quotes, which search the including file's own directory.

# Python: evaluated only when the python target runs.
PY_INCLUDE = $(shell $(PYTHON) -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
PY_SUFFIX = $(shell $(PYTHON) -c 'import sysconfig; print(sysconfig.get_config_var("EXT_SUFFIX"))')
PY_ARCH = $(shell $(PYTHON) -c 'import platform; print(platform.machine())')
PY_EXT = python/psychmetal/_psychmetal$(PY_SUFFIX)
PY_FLAGS := -arch arm64 -mmacosx-version-min=14.0 -isysroot "$(SDKROOT)" -fPIC -fexceptions \
            -fwrapv -ffp-contract=off -std=c++17 -stdlib=libc++ $(RELEASE_FLAGS)

.PHONY: all check-arch octave matlab python package clean test

all: octave matlab python

check-arch:
	@test "$(HOST_ARCH)" = arm64 || { echo "PsychMetal currently supports Apple silicon (arm64) only."; exit 1; }

octave: check-arch $(OCTAVE_MEX)

$(OCTAVE_MEX): $(ENGINE) $(SHARED) $(MEX_FRONTEND) $(HEADERS)
	clang++ -x objective-c++ -std=c++17 -fobjc-arc -fPIC -mmacosx-version-min=14.0 $(RELEASE_FLAGS) \
	  -c $(ENGINE) -o engine.octave.o
	clang++ -x c++ -std=c++17 -fPIC -mmacosx-version-min=14.0 $(RELEASE_FLAGS) \
	  -c $(SHARED) -o shared.octave.o
	clang++ -x c++ -std=c++17 -fPIC -mmacosx-version-min=14.0 $(RELEASE_FLAGS) \
	  $$(mkoctfile -p INCFLAGS) -c $(MEX_FRONTEND) -o mex.octave.o
	MACOSX_DEPLOYMENT_TARGET=14.0 LDFLAGS="$$(mkoctfile -p LDFLAGS) -mmacosx-version-min=14.0 $(FRAMEWORKS)" \
	  mkoctfile --mex engine.octave.o shared.octave.o mex.octave.o -o $@
	@$(RM) engine.octave.o shared.octave.o mex.octave.o

matlab: check-arch $(MATLAB_MEX)

MATLAB_FLAGS = -DMATLAB_MEX_FILE -I"$(MATLAB_ROOT)/extern/include" -I"$(MATLAB_ROOT)/simulink/include" \
  -fno-common -arch arm64 -mmacosx-version-min=14.0 -fexceptions \
  -isysroot "$(SDKROOT)" -fwrapv -ffp-contract=off -std=c++17 -stdlib=libc++ $(RELEASE_FLAGS)

$(MATLAB_MEX): $(ENGINE) $(SHARED) $(MEX_FRONTEND) $(HEADERS)
	test -d "$(MATLAB_ROOT)" || { echo "Set MATLAB_ROOT to the MATLAB application directory."; exit 1; }
	xcrun -sdk macosx clang++ -x objective-c++ -fobjc-arc $(MATLAB_FLAGS) -c $(ENGINE) -o engine.matlab.o
	xcrun -sdk macosx clang++ -x c++ $(MATLAB_FLAGS) -c $(SHARED) -o shared.matlab.o
	xcrun -sdk macosx clang++ -x c++ $(MATLAB_FLAGS) -c $(MEX_FRONTEND) -o mex.matlab.o
	xcrun -sdk macosx clang++ -Wl,-twolevel_namespace -arch arm64 \
	  -mmacosx-version-min=14.0 -Wl,-syslibroot,"$(SDKROOT)" -bundle -stdlib=libc++ \
	  -Wl,-exported_symbols_list,"$(MATLAB_ROOT)/extern/lib/maca64/mexFunction.map" \
	  engine.matlab.o shared.matlab.o mex.matlab.o -L"$(MATLAB_ROOT)/bin/maca64" \
	  -weak-lmx -weak-lmex -weak-lmat -L"$(MATLAB_ROOT)/extern/bin/maca64" \
	  -weak-lMatlabDataArray $(FRAMEWORKS) -o $@
	@$(RM) engine.matlab.o shared.matlab.o mex.matlab.o

# The Python extension: psychmetal/_psychmetal*.so for the Python in $(PYTHON).
# Needs only clang and that Python's headers; numpy is a run-time dependency.
python: check-arch
	@test "$(PY_ARCH)" = arm64 || { echo "$(PYTHON) is an $(PY_ARCH) build; use an arm64 Python."; exit 1; }
	@$(MAKE) --no-print-directory "$(PY_EXT)"

python/psychmetal/_psychmetal%: $(ENGINE) $(SHARED) $(PY_FRONTEND) $(HEADERS)
	xcrun -sdk macosx clang++ -x objective-c++ -fobjc-arc $(PY_FLAGS) -c $(ENGINE) -o engine.python.o
	xcrun -sdk macosx clang++ -x c++ $(PY_FLAGS) -c $(SHARED) -o shared.python.o
	xcrun -sdk macosx clang++ -x c++ $(PY_FLAGS) -I"$(PY_INCLUDE)" -c $(PY_FRONTEND) -o frontend.python.o
	xcrun -sdk macosx clang++ -bundle -undefined dynamic_lookup -arch arm64 -mmacosx-version-min=14.0 \
	  -isysroot "$(SDKROOT)" -stdlib=libc++ engine.python.o shared.python.o frontend.python.o \
	  $(FRAMEWORKS) -o $@
	codesign --force --sign - $@ >/dev/null
	@$(RM) engine.python.o shared.python.o frontend.python.o
	cd python && $(PYTHON) -c 'import psychmetal, sys; print("Built", psychmetal._core.__file__, "engine", psychmetal._core.version())'

# Stage only the checksummed, tested release payload; never rebuild implicitly.
package:
	python3 tests/package_release.py . "$(DIST_DIR)"

clean:
	$(RM) *.octave.o *.matlab.o *.python.o $(OCTAVE_MEX) $(MATLAB_MEX) python/psychmetal/_psychmetal*.so

PsychMetalShaders.h: PsychMetalShaders.metal tests/embed_shaders.py
	python3 tests/embed_shaders.py

test: octave
	python3 tests/run_tests.py
