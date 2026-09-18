TARGET := iphone:clang:latest:15.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = SpringBoard
THEOS_PACKAGE_DIR = build-packages

# Release defaults. FINALPACKAGE=1 in CI also implies DEBUG=0 + STRIP=1,
# but keeping these explicit prevents accidental local debug packages.
DEBUG = 0
STRIP = 1
OPTFLAG = -Os
TARGET_STRIP_FLAGS = -x

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Lilywhite
Lilywhite_FILES = Tweak.xm
Lilywhite_CFLAGS = -fobjc-arc -DLILYWHITE_DEBUG=0 -fvisibility=hidden -fno-ident
Lilywhite_LDFLAGS = -Wl,-dead_strip
Lilywhite_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

after-all::
	@echo "Build with: make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1"
