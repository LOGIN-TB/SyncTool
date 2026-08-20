CONFIG ?= release

.PHONY: app app-native install run test build clean icon version release

app:
	@bash Scripts/bundle.sh

# Schneller Durchlauf ohne Universal-Binary, fuer die Entwicklung.
app-native:
	@NATIVE_ONLY=1 CONFIG=debug bash Scripts/bundle.sh

install: app
	@rm -rf /Applications/SyncTool.app
	@cp -R build/SyncTool.app /Applications/SyncTool.app
	@# Der Finder merkt sich Symbole je Bundle-Pfad. Ohne das zeigt die
	@# installierte App noch das alte Symbol.
	@touch /Applications/SyncTool.app
	@echo "==> /Applications/SyncTool.app installiert"

run: app-native
	@open build/SyncTool.app

build:
	@swift build -c $(CONFIG)

# Ohne Xcode findet SwiftPM Testing.framework weder beim Übersetzen noch beim
# Laden. Suchpfad und beide rpaths müssen deshalb von Hand mit.
#
# Geprüft wird das Framework selbst und nicht sein Elternverzeichnis: mit vollem
# Xcode liegt Testing an einer anderen Stelle, der abgeleitete Pfad zeigt ins
# Leere, und SwiftPM findet es dort von sich aus. Vorher fiel der Wächter dort
# aus Versehen durch, jetzt mit Absicht.
DEVELOPER_DIR := $(shell xcode-select -p 2>/dev/null)
TESTING_FRAMEWORKS := $(DEVELOPER_DIR)/Library/Developer/Frameworks
TESTING_LIBS := $(DEVELOPER_DIR)/Library/Developer/usr/lib

test:
	@if [ -d "$(TESTING_FRAMEWORKS)/Testing.framework" ]; then \
		swift test -Xswiftc -F -Xswiftc "$(TESTING_FRAMEWORKS)" \
			-Xlinker -F -Xlinker "$(TESTING_FRAMEWORKS)" \
			-Xlinker -rpath -Xlinker "$(TESTING_FRAMEWORKS)" \
			-Xlinker -rpath -Xlinker "$(TESTING_LIBS)"; \
	else \
		swift test; \
	fi

# Das Symbol aendert sich praktisch nie, deshalb ein eigenes Ziel und nicht
# bei jedem Bau. Die erzeugte .icns liegt als Datei im Projekt.
icon:
	@swift Scripts/make-icon.swift build/SyncTool.iconset
	@iconutil -c icns build/SyncTool.iconset -o Resources/SyncTool.icns
	@echo "==> Resources/SyncTool.icns erzeugt"

version:
	@printf "Fassung:   %s\nLetzter Build: %s\n" \
		"$$(sed -n '1p' VERSION)" "$$(sed -n '2p' VERSION)"

# Signiert, notarisiert, verpackt. Die Tore stehen im Skript, damit nie still
# ein unsigniertes Artefakt entsteht.
release:
	@test -n "$(VERSION)" || { echo "Aufruf: make release VERSION=1.4.0"; exit 1; }
	@bash Scripts/release.sh "$(VERSION)"

# Trockenlauf ohne Zertifikat: erzeugt eine unsignierte DMG und keine
# Pruefsummen, damit sich die Maschinerie erproben laesst.
release-dev:
	@test -n "$(VERSION)" || { echo "Aufruf: make release-dev VERSION=1.4.0"; exit 1; }
	@bash Scripts/release.sh "$(VERSION)" --dev

clean:
	@swift package clean 2>/dev/null || true
	@rm -rf build dist .build .build-arm64 .build-x86_64
