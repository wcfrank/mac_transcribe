.PHONY: build app run clean

build:
	swift build

app:
	./scripts/build-app.sh

run: app
	open ./dist/Transcribe.app

clean:
	swift package clean
