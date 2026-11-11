CC = clang
ARCH ?= arm64
CFLAGS = -arch $(ARCH) -Wall -Wextra -Werror -Wno-deprecated-declarations -O2 -fobjc-arc -mmacosx-version-min=13.0
FRAMEWORKS = -framework Foundation -framework AppKit -framework IOKit -framework CoreGraphics
SOURCES = main.m DisplayDiscovery.m DisplayProfile.m DDC/DDCBackend.m Daemon/DisplayStateManager.m Daemon/DisplaySocketServer.m Daemon/DisplayWatcher.m Daemon/DisplayBlackout.m
TARGET = build/display-helper
PROFILE_JSON = Profile/profiles.json

.PHONY: all plugin clean

all: $(TARGET)

plugin: $(TARGET)
	python3 scripts/embed_plugin_resources.py $(TARGET) $(PROFILE_JSON) ..
	mkdir -p build/DellColorPreset.iinaplugin
	cp ../Info.json ../entry.js ../main.js ../preferences.html ../helperPayload.js ../profilesPayload.js build/DellColorPreset.iinaplugin/

$(TARGET): $(SOURCES) DisplayDiscovery.h DisplayProfile.h DDC/DDCBackend.h Daemon/DisplayStateManager.h Daemon/DisplaySocketServer.h Daemon/DisplayWatcher.h Daemon/DisplayBlackout.h $(PROFILE_JSON)
	mkdir -p build
	cp $(PROFILE_JSON) build/profiles.json
	$(CC) $(CFLAGS) $(SOURCES) $(FRAMEWORKS) -o $(TARGET)

clean:
	rm -rf build
