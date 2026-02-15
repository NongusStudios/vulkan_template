DBG_FLAGS = -debug -o:minimal -out:bin/debug/a.out
FLAGS = -o:speed -out:bin/release/a.out

.PHONY: all

all: build

bin/debug:
	mkdir -p bin/debug
bin/release:
	mkdir -p bin/release	

build: vma imgui bin/debug
	odin build src $(DBG_FLAGS)

release: vma imgui bin/release
	odin build src $(FLAGS)

run: build
	./bin/debug/a.out

clean:
	rm -r bin
	rm -rf lib/vma/build lib/vma/libvma_linux_x86_64.a
	rm -rf lib/imgui/build lib/imgui/libimgui_linux_x64.a

# Build dependencies
lib/vma/libvma_linux_x86_64.a:
	cd lib/vma && premake5 --vk-version=3 gmake && \
		cd build/make/linux && make config=release_x86_64

lib/imgui/libimgui_linux_x64.a:
	cd lib/imgui && premake5 --backends=sdl3,vulkan gmake && \
		cd build/make/linux && make config=release_x86_64

vma: lib/vma/libvma_linux_x86_64.a
imgui: lib/imgui/libimgui_linux_x64.a
