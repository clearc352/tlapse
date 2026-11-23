TARGET := iphone:clang:latest:12.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES :=

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME := TlapseCameraFix

TlapseCameraFix_FILES := src/Tweak.m
TlapseCameraFix_FRAMEWORKS := Foundation
TlapseCameraFix_CFLAGS := -fno-objc-arc -Wall -Wextra -Werror
TlapseCameraFix_INSTALL_PATH := /usr/lib

TOOL_NAME := tlapse-camera-inject

tlapse-camera-inject_FILES := src/inject.c
tlapse-camera-inject_CFLAGS := -Os -Wall -Wextra
tlapse-camera-inject_CODESIGN_FLAGS := -S -Cadhoc
tlapse-camera-inject_INSTALL_PATH := /usr/local/bin

include $(THEOS_MAKE_PATH)/library.mk
include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	mkdir -p "$(THEOS_STAGING_DIR)/usr/share/doc/tlapse-camera"
	cp "$(THEOS_PROJECT_DIR)/../LICENSE" "$(THEOS_STAGING_DIR)/usr/share/doc/tlapse-camera/copyright"
