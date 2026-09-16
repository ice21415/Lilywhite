TARGET := iphone:clang:latest:15.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_DIR = build-packages

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Lilywhite
Lilywhite_FILES = Tweak.xm
Lilywhite_CFLAGS = -fobjc-arc
Lilywhite_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

after-all::
	@echo "Build with: make package THEOS_PACKAGE_SCHEME=roothide"
