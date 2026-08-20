# Weiterleitung. Die macOS-App liegt unter macos/, damit eine Windows-Fassung
# spaeter daneben passt, ohne dass etwas umziehen muss. Die vertrauten Aufrufe
# funktionieren von hier aus unveraendert weiter.
.PHONY: app app-native install run build test icon version release release-dev clean

app app-native install run build test icon version release release-dev clean:
	@$(MAKE) --no-print-directory -C macos $@
