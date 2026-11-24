TARGET := iphone:clang:latest:12.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES :=

# checkra1n on iOS 12 is rootful. Do not set THEOS_PACKAGE_SCHEME=rootless.

HOST_SDK := $(shell xcrun --sdk macosx --show-sdk-path)
# 主机验证可用 HOST_TEST_CFLAGS=-O2 复核生产优化下的资源生命周期。
HOST_TEST_CFLAGS ?=
HOST_SRCS := src/TLVersion.m src/TLRules.m src/TLSupport.m src/TLLog.m src/TLConfig.m src/TLState.m src/TLImage.m src/TLEncode.m src/TLEncoder.m src/TLUploader.m src/TLJobs.m src/TLScheduler.m src/TLWeb.m app/TLClient.m tests/test_host.m

ifeq ($(filter test test-web-fixture,$(MAKECMDGOALS)),)

ifndef THEOS
$(error 请先安装 Theos，并执行 export THEOS=$$HOME/theos)
endif

include $(THEOS)/makefiles/common.mk

TOOL_NAME := tlapsed

tlapsed_FILES := src/main.m src/TLVersion.m src/TLRules.m src/TLSupport.m src/TLLog.m src/TLConfig.m src/TLState.m src/TLImage.m src/TLCapture.m src/TLEncode.m src/TLEncoder.m src/TLUploader.m src/TLJobs.m src/TLScheduler.m src/TLDaemon.m src/TLWeb.m
tlapsed_FRAMEWORKS := Foundation AVFoundation CoreGraphics ImageIO CoreMotion CoreVideo CoreMedia
tlapsed_LDFLAGS := -framework IOKit
tlapsed_CFLAGS := -fobjc-arc -Isrc -Wall
tlapsed_CODESIGN_FLAGS := -Sentitlements.plist
tlapsed_INSTALL_PATH := /usr/local/bin

APPLICATION_NAME := Tlapse
Tlapse_FILES := app/main.m app/TLClient.m
Tlapse_FRAMEWORKS := Foundation UIKit AVFoundation AVKit CoreGraphics ImageIO
Tlapse_CFLAGS := -fobjc-arc -Wall -Werror=unguarded-availability
Tlapse_RESOURCE_DIRS := app/Resources

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	xcrun --sdk iphoneos ibtool --minimum-deployment-target 12.0 --target-device iphone --compile "$(THEOS_STAGING_DIR)/Applications/Tlapse.app/LaunchScreen.storyboardc" app/LaunchScreen.storyboard

else

.PHONY: test
test:
	clang $(HOST_TEST_CFLAGS) -fobjc-arc -Wall -Wextra -Werror -Isrc -isysroot "$(HOST_SDK)" -framework Foundation -framework CoreGraphics -framework ImageIO -framework IOKit -framework AVFoundation -framework CoreVideo -framework CoreMedia $(HOST_SRCS) -o /tmp/tlapse-host-tests
	/tmp/tlapse-host-tests
	rm -f /tmp/tlapse-host-tests

# 真实 TLWeb 本地浏览器夹具，不启动相机/调度器，不连接上传服务。
.PHONY: test-web-fixture
test-web-fixture:
	clang $(HOST_TEST_CFLAGS) -fobjc-arc -Wall -Wextra -Werror -Isrc -isysroot "$(HOST_SDK)" -framework Foundation -framework CoreGraphics -framework ImageIO -framework IOKit -framework AVFoundation -framework CoreVideo -framework CoreMedia $(filter-out tests/test_host.m,$(HOST_SRCS)) tests/web_fixture.m -o /tmp/tlapse-web-fixture

endif
