.PHONY: build run app install clean

build:
	swift build

run: build
	.build/debug/AppleMusicPresence

app:
	Scripts/build-app.sh

install: app
	rm -rf "/Applications/Apple Music Presence.app"
	cp -R "build/Apple Music Presence.app" /Applications/
	@echo "Installed. Launch it from /Applications (or: open '/Applications/Apple Music Presence.app')"

clean:
	rm -rf .build build
