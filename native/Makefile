CC = clang
CFLAGS = -Wall -Wextra -Werror -O2 -fobjc-arc -mmacosx-version-min=13.0
FRAMEWORKS = -framework Foundation -framework IOKit -framework CoreGraphics
SOURCES = main.m DisplayDiscovery.m
TARGET = build/display-helper

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SOURCES) DisplayDiscovery.h
	mkdir -p build
	$(CC) $(CFLAGS) $(SOURCES) $(FRAMEWORKS) -o $(TARGET)

clean:
	rm -rf build
