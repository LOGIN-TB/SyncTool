// Fenster-Kennungen der laufenden App, fuer `screencapture -l`.
//
// Ohne das bliebe nur `screencapture -w` mit Mausklick, und damit waere die
// Bildschirmfoto-Werkstatt keine Werkstatt, sondern Handarbeit. CGWindowList
// braucht keine Bedienungshilfen-Freigabe, nur die fuer Bildschirmaufnahme.
//
// Aufruf: swift window-id.swift <Programmname> [Fenstertitel]
// Gibt je Treffer eine Zeile "<id> <breite>x<hoehe> <titel>" aus.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Aufruf: window-id.swift <Programm> [Titel]\n".utf8))
    exit(2)
}
let owner = arguments[1]
let wantedTitle = arguments.count > 2 ? arguments[2] : nil

guard
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]]
else { exit(1) }

var found = false
for window in windows {
    guard window[kCGWindowOwnerName as String] as? String == owner else { continue }
    let title = window[kCGWindowName as String] as? String ?? ""
    if let wantedTitle, title != wantedTitle { continue }
    guard let number = window[kCGWindowNumber as String] as? Int,
        let bounds = window[kCGWindowBounds as String] as? [String: Any],
        let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
    else { continue }
    // Die Menueleisten-Kachel ist ein winziges Fenster desselben Programms und
    // waere sonst der erste Treffer.
    guard width > 200, height > 200 else { continue }
    print("\(number) \(Int(width))x\(Int(height)) \(title)")
    found = true
}
exit(found ? 0 : 1)
