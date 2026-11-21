APP_NAME = Android
EXECUTABLE_NAME = MacDroid
BUNDLE_DIR = $(APP_NAME).app
CONTENTS_DIR = $(BUNDLE_DIR)/Contents
MACOS_DIR = $(CONTENTS_DIR)/MacOS
RESOURCES_DIR = $(CONTENTS_DIR)/Resources
RESOURCE_BUNDLE = .build/release/$(EXECUTABLE_NAME)_$(EXECUTABLE_NAME).bundle

.PHONY: all deps build app run test clean

all: app

deps:
	@mkdir -p Sources/MacDroid/Resources
	@curl -fsSL "https://github.com/Genymobile/scrcpy/releases/download/v3.1/scrcpy-server-v3.1" -o Sources/MacDroid/Resources/scrcpy-server
	@echo "Saved Sources/MacDroid/Resources/scrcpy-server"

build:
	swift build -c release

app: build
	@rm -rf "$(RESOURCES_DIR)"
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES_DIR)"
	@cp ".build/release/$(EXECUTABLE_NAME)" "$(MACOS_DIR)/$(APP_NAME)"
	@if [ -f "AppIcon.icns" ]; then \
		cp "AppIcon.icns" "$(RESOURCES_DIR)/AppIcon.icns"; \
	fi
	@if [ -d "$(RESOURCE_BUNDLE)" ]; then \
		cp -R "$(RESOURCE_BUNDLE)" "$(RESOURCES_DIR)/"; \
	fi
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>CFBundleDevelopmentRegion</key>' \
		'    <string>en</string>' \
		'    <key>CFBundleExecutable</key>' \
		'    <string>$(APP_NAME)</string>' \
		'    <key>CFBundleIconFile</key>' \
		'    <string>AppIcon</string>' \
		'    <key>CFBundleIdentifier</key>' \
		'    <string>com.macdroid.app</string>' \
		'    <key>CFBundleInfoDictionaryVersion</key>' \
		'    <string>6.0</string>' \
		'    <key>CFBundleName</key>' \
		'    <string>$(APP_NAME)</string>' \
		'    <key>CFBundleDisplayName</key>' \
		'    <string>$(APP_NAME)</string>' \
		'    <key>CFBundlePackageType</key>' \
		'    <string>APPL</string>' \
		'    <key>CFBundleShortVersionString</key>' \
		'    <string>0.1</string>' \
		'    <key>CFBundleVersion</key>' \
		'    <string>1</string>' \
		'    <key>LSMinimumSystemVersion</key>' \
		'    <string>14.0</string>' \
		'    <key>NSHighResolutionCapable</key>' \
		'    <true/>' \
		'    <key>NSPrincipalClass</key>' \
		'    <string>NSApplication</string>' \
		'    <key>NSLocalNetworkUsageDescription</key>' \
		'    <string>MacDroid discovers Android devices with Wireless Debugging on your local network.</string>' \
		'    <key>NSBonjourServices</key>' \
		'    <array>' \
		'        <string>_adb-tls-connect._tcp</string>' \
		'        <string>_adb-tls-pairing._tcp</string>' \
		'    </array>' \
		'</dict>' \
		'</plist>' > "$(CONTENTS_DIR)/Info.plist"
	@touch "$(BUNDLE_DIR)"
	@codesign --force --deep --sign - "$(BUNDLE_DIR)" >/dev/null 2>&1 || true
	@echo "Built $(BUNDLE_DIR)"

run: app
	open "$(BUNDLE_DIR)"

test:
	swift test

clean:
	swift package clean
	rm -rf "$(BUNDLE_DIR)"
