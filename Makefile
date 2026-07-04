.PHONY: test build app dmg preview restart pricing ci

test:
	swift test

build:
	swift build

app:
	Scripts/build-app.sh debug

app-release:
	Scripts/build-app.sh release

dmg:
	Scripts/package-dmg.sh release

preview:
	Scripts/regenerate-preview.sh

restart:
	Scripts/rebuild-and-restart.sh debug

pricing:
	python3 Scripts/update-pricing.py

ci: test build
