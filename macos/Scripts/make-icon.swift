import AppKit
import CoreGraphics
import Foundation

// Zeichnet das Programmsymbol und schreibt ein .iconset.
//
// Bewusst von Hand gezeichnet statt aus einem SF Symbol gerendert: Apples
// Lizenz erlaubt SF Symbols in der Oberflaeche, nicht aber als Programmsymbol
// oder Logo. In der Menueleiste bleiben sie deshalb, hier nicht.
//
// Aufruf: swift Scripts/make-icon.swift <zielordner>.iconset

// MARK: - Proportionen

/// macOS maskiert Programmsymbole nicht, anders als iOS. Die abgerundete Form
/// muss das Symbol selbst mitbringen, sonst steht ein scharfkantiges Quadrat
/// neben lauter gerundeten Systemsymbolen.
///
/// Bezogen auf 1024 Bildpunkte Leinwand: Koerper 824, also 100 Rand je Seite.
/// Der Rand ist kein verschenkter Platz, dort zeichnet das System den Schatten.
let bodyRatio: CGFloat = 824.0 / 1024.0

/// Durchmesser des Pfeilkreises, bezogen auf die Koerperbreite.
let circleRatio: CGFloat = 0.46
/// In kleinen Groessen etwas groesser, sonst bleibt fuer die Spitzen kein Platz.
let smallCircleRatio: CGFloat = 0.54
/// Strichstaerke, bezogen auf die Koerperbreite.
let strokeRatio: CGFloat = 0.075
/// Unterhalb dieser Kantenlaenge verschluckt die Rasterung feine Striche.
let smallSizeThreshold: CGFloat = 64
let smallStrokeRatio: CGFloat = 0.095

// MARK: - Formen

/// Superellipse statt `roundedRect`.
///
/// Apples Symbolform ist eine stetige Kruemmung. Eine gewoehnliche Rundung aus
/// Kreisboegen wirkt an den Ecken eingeschnuert und faellt neben Systemsymbolen auf.
func squircle(in rect: CGRect, exponent: CGFloat = 5, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let power = 2 / exponent

    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosT = cos(t)
        let sinT = sin(t)
        let x = cx + a * (cosT < 0 ? -1 : 1) * pow(abs(cosT), power)
        let y = cy + b * (sinT < 0 ? -1 : 1) * pow(abs(sinT), power)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Ein Bogen mit runden Enden und einer Pfeilspitze am Ende.
///
/// Der Bogen hoert vor der Spitze auf, sonst schaut der runde Abschluss unter
/// dem Dreieck hervor und die Spitze wirkt stumpf.
func arrow(
    center: CGPoint, radius: CGFloat, stroke: CGFloat,
    from startDegrees: CGFloat, to endDegrees: CGFloat,
    headWidth: CGFloat, headLength: CGFloat
) -> CGPath {
    let start = startDegrees * .pi / 180
    let end = endDegrees * .pi / 180
    // Der Bogen hoert vor der Spitze auf, und zwar eine halbe Strichstaerke
    // frueher als die Grundlinie: sonst schaut die runde Kappe als Wulst unter
    // dem Dreieck hervor.
    let forward: CGFloat = end > start ? 1 : -1
    let baseAngle = end - forward * headLength / radius
    let arcEnd = baseAngle - forward * (stroke / 2) / radius

    let path = CGMutablePath()
    let arc = CGMutablePath()
    arc.addArc(
        center: center, radius: radius,
        startAngle: start, endAngle: arcEnd,
        clockwise: end < start
    )
    path.addPath(
        arc.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
    )

    // Spitze auf dem Kreis, Grundlinie radial dazu: bei einem Bogen steht die
    // Tangente senkrecht auf dem Radius, die Grundlinie liegt also richtig.
    let tip = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
    let base = CGPoint(x: center.x + radius * cos(baseAngle), y: center.y + radius * sin(baseAngle))
    let radial = CGPoint(x: cos(baseAngle), y: sin(baseAngle))
    path.move(to: tip)
    path.addLine(to: CGPoint(x: base.x + radial.x * headWidth, y: base.y + radial.y * headWidth))
    path.addLine(to: CGPoint(x: base.x - radial.x * headWidth, y: base.y - radial.y * headWidth))
    path.closeSubpath()
    return path
}

// MARK: - Zeichnen

/// `pixels` ist die Kantenlaenge in Bildpunkten, nicht in Punkten: davon haengt
/// der Detailgrad ab. Ein aus 1024 verkleinertes Symbol ist bei 16 nur Matsch.
func drawIcon(into context: CGContext, pixels: CGFloat) {
    let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    context.clear(canvas)

    let bodySize = pixels * bodyRatio
    let body = CGRect(
        x: (pixels - bodySize) / 2, y: (pixels - bodySize) / 2,
        width: bodySize, height: bodySize
    )

    let shape = squircle(in: body)
    context.saveGState()
    context.addPath(shape)
    context.clip()
    // Senkrechter Verlauf von hell nach dunkel. Bei kleinen Groessen wuerde er
    // nur den Kontrast zu den weissen Pfeilen kosten, deshalb dort Volltonfarbe.
    if pixels >= smallSizeThreshold {
        let space = CGColorSpaceCreateDeviceRGB()
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(red: 0.36, green: 0.62, blue: 0.98, alpha: 1),
                CGColor(red: 0.08, green: 0.33, blue: 0.80, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: body.midX, y: body.maxY),
            end: CGPoint(x: body.midX, y: body.minY),
            options: []
        )
    } else {
        context.setFillColor(CGColor(red: 0.16, green: 0.44, blue: 0.90, alpha: 1))
        context.fill(body)
    }
    context.restoreGState()

    let center = CGPoint(x: body.midX, y: body.midY)
    let radius = bodySize * (pixels < smallSizeThreshold ? smallCircleRatio : circleRatio) / 2
    let stroke = bodySize * (pixels < smallSizeThreshold ? smallStrokeRatio : strokeRatio)

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    // Zwei Boegen, der zweite ist der erste um 180 Grad gedreht. Beide laufen
    // im Uhrzeigersinn, der obere ueber den Scheitel nach rechts, der untere
    // ueber den Boden nach links. Zusammen ergeben sie einen Kreislauf.
    // Bei 16 Bildpunkten entscheidet die Spitze darueber, ob man zwei Pfeile
    // sieht oder nur einen aufgebrochenen Ring; bei 512 wuerde dieselbe
    // Uebertreibung wie ein abgeloester Keil wirken. Deshalb je Groesse anders.
    let small = pixels < smallSizeThreshold
    let headWidth = stroke * (small ? 1.15 : 0.92)
    let headLength = stroke * (small ? 1.9 : 1.6)
    for (from, to) in [(CGFloat(165), CGFloat(15)), (CGFloat(-15), CGFloat(-165))] {
        context.addPath(
            arrow(
                center: center, radius: radius, stroke: stroke, from: from, to: to,
                headWidth: headWidth, headLength: headLength
            )
        )
    }
    context.fillPath()
}

// MARK: - Ausgabe

func writeIcon(name: String, pixels: Int, to directory: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { throw NSError(domain: "make-icon", code: 1) }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    drawIcon(into: context, pixels: CGFloat(pixels))

    guard
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            directory.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil
        )
    else { throw NSError(domain: "make-icon", code: 2) }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let target = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "build/SyncTool.iconset")

try? FileManager.default.removeItem(at: target)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

// `iconutil` verlangt genau diese Namen. icon_16x16@2x und icon_32x32 haben
// beide 32 Bildpunkte, sind aber zwei Dateien: die eine ist die Netzhautfassung
// des kleinen Symbols, die andere die Normalfassung des mittleren.
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in sizes {
    try writeIcon(name: name, pixels: pixels, to: target)
}
print("==> \(sizes.count) Größen in \(target.path)")
