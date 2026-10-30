.PHONY: build test app universal run install dmg release publish update-key icon strings notarize clean

APP := build/Kumquat.app
VERSION := $(shell cat VERSION)
DMG := build/Kumquat-$(VERSION).dmg
ZIP := build/Kumquat-$(VERSION).zip

build:
	swift build

test:
	swift test

app:
	./Scripts/build-app.sh

universal:
	ARCHS="arm64 x86_64" ./Scripts/build-app.sh

run: app
	open $(APP)

install: app
	rm -rf /Applications/Kumquat.app
	cp -R $(APP) /Applications/
	open /Applications/Kumquat.app

# Disk image with the app and an Applications shortcut to drag it onto.
dmg: universal
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	ditto $(APP) build/dmg/Kumquat.app
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "Kumquat $(VERSION)" -srcfolder build/dmg -ov -format UDZO $(DMG)
	rm -rf build/dmg

# GitHub release files: DMG, ZIP, the ZIP's update signature and checksums. Ad-hoc signed unless
# SIGN_IDENTITY is set; the update signature needs the key from `make update-key`.
release:
	SIGN_IDENTITY="$${SIGN_IDENTITY:--}" $(MAKE) dmg
	rm -f $(ZIP) $(ZIP).sig
	ditto -c -k --norsrc --noextattr --keepParent $(APP) $(ZIP)
	swift Scripts/update-signing.swift sign $(APP) $(ZIP)
	cd build && shasum -a 256 $(notdir $(DMG)) $(notdir $(ZIP)) $(notdir $(ZIP)).sig > SHA256SUMS.txt

# GitHub release from those files, notes from CHANGELOG.md (see docs/RELEASING.md).
publish:
	./Scripts/publish.sh

# Once per maintainer: the updater's signing key, into the login keychain (see docs/RELEASING.md).
update-key:
	swift Scripts/update-signing.swift generate

icon:
	./Scripts/make-icon.sh

# Clean build that makes swiftc list every localizable string, merged into the catalog
# (new keys appear untranslated, removed ones are marked stale).
strings:
	rm -rf .build/strings
	mkdir -p .build/strings/data
	swift build --scratch-path .build/strings -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc .build/strings/data
	xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata .build/strings/data/*.stringsdata

# Requires SIGN_IDENTITY (Developer ID) and a notarytool keychain profile named "kumquat".
notarize: dmg
	xcrun notarytool submit $(DMG) --keychain-profile kumquat --wait
	xcrun stapler staple $(DMG)

clean:
	rm -rf .build build
