import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root.appending(path: "docs/images")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let codex = NSColor(calibratedRed: 0.00, green: 0.43, blue: 0.96, alpha: 1)
let claude = NSColor(calibratedRed: 0.86, green: 0.39, blue: 0.24, alpha: 1)
let textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
let secondary = NSColor(calibratedWhite: 0.38, alpha: 1)
let muted = NSColor(calibratedWhite: 0.54, alpha: 1)
let hairline = NSColor(calibratedWhite: 0.55, alpha: 0.22)
let white = NSColor.white

func image(width: Int, height: Int, draw: @escaping (CGRect) -> Void) throws -> NSImage {
    NSImage(size: NSSize(width: width, height: height), flipped: true) { rect in
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(rect)
        return true
    }
}

func save(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "screenshot", code: 1)
    }
    try data.write(to: url)
}

func withGraphics(_ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func rounded(_ rect: CGRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func shadowedRounded(_ rect: CGRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, blur: CGFloat = 30, offsetY: CGFloat = 18, alpha: CGFloat = 0.24) {
    withGraphics {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = CGSize(width: 0, height: offsetY)
        shadow.set()
        rounded(rect, radius: radius, fill: fill, stroke: stroke, lineWidth: 1)
    }
}

func line(_ from: CGPoint, _ to: CGPoint, color: NSColor = hairline, width: CGFloat = 1) {
    let path = NSBezierPath()
    path.move(to: from)
    path.line(to: to)
    color.setStroke()
    path.lineWidth = width
    path.stroke()
}

func drawText(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = textColor, width: CGFloat = 500, align: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    paragraph.alignment = align
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    string.draw(in: CGRect(x: x, y: y, width: width, height: size + 9), withAttributes: attrs)
}

func monoText(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = secondary, align: NSTextAlignment = .right) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = align
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    string.draw(in: CGRect(x: x, y: y, width: width, height: size + 9), withAttributes: attrs)
}

func drawWallpaper(_ rect: CGRect) {
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.61, green: 0.75, blue: 0.97, alpha: 1),
        NSColor(calibratedRed: 0.86, green: 0.74, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 0.98, green: 0.82, blue: 0.69, alpha: 1),
        NSColor(calibratedRed: 0.70, green: 0.89, blue: 0.92, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: 235)

    let blobs: [(CGRect, NSColor)] = [
        (CGRect(x: -120, y: 120, width: 560, height: 520), NSColor(calibratedRed: 0.26, green: 0.55, blue: 1.00, alpha: 0.22)),
        (CGRect(x: 840, y: -150, width: 650, height: 600), NSColor(calibratedRed: 1.00, green: 0.48, blue: 0.33, alpha: 0.20)),
        (CGRect(x: 1050, y: 520, width: 620, height: 560), NSColor(calibratedRed: 0.36, green: 0.91, blue: 0.78, alpha: 0.20)),
        (CGRect(x: 270, y: 620, width: 680, height: 540), NSColor(calibratedRed: 1.00, green: 0.95, blue: 0.62, alpha: 0.16)),
        (CGRect(x: 520, y: 180, width: 440, height: 400), NSColor(calibratedRed: 0.94, green: 0.88, blue: 1.00, alpha: 0.16)),
    ]

    for (blob, color) in blobs {
        let path = NSBezierPath(ovalIn: blob)
        color.setFill()
        path.fill()
    }

    for index in 0..<22 {
        let x = CGFloat((index * 173) % Int(max(rect.width, 1)))
        let y = CGFloat((index * 97 + 55) % Int(max(rect.height, 1)))
        let size = CGFloat(26 + (index * 13) % 58)
        NSColor.white.withAlphaComponent(index.isMultiple(of: 3) ? 0.07 : 0.035).setFill()
        NSBezierPath(ovalIn: CGRect(x: x, y: y, width: size, height: size)).fill()
    }
}

func drawMenuBar(width: CGFloat, activeIconX: CGFloat? = nil, time: String = "Чт 23 апр. 22:58") {
    rounded(CGRect(x: 0, y: 0, width: width, height: 42), radius: 0, fill: NSColor.white.withAlphaComponent(0.50))
    line(CGPoint(x: 0, y: 42), CGPoint(x: width, y: 42), color: NSColor.white.withAlphaComponent(0.38), width: 1)

    drawText("", x: 24, y: 10, size: 18, weight: .semibold, color: NSColor.black.withAlphaComponent(0.72), width: 28)
    drawText("Limits", x: 60, y: 11, size: 14, weight: .semibold, color: NSColor.black.withAlphaComponent(0.70), width: 80)
    drawText("Файл", x: 128, y: 11, size: 14, weight: .regular, color: NSColor.black.withAlphaComponent(0.56), width: 56)
    drawText("Вид", x: 180, y: 11, size: 14, weight: .regular, color: NSColor.black.withAlphaComponent(0.56), width: 56)

    let rightStart = width - 360
    let trayX = activeIconX ?? (rightStart + 136)
    let iconGroupX = trayX - 132
    let iconColor = NSColor.black.withAlphaComponent(0.54)

    iconColor.setStroke()
    let signalCenter = CGPoint(x: iconGroupX + 18, y: 27)
    for radius in [15.0, 10.0, 5.2] {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: signalCenter, radius: CGFloat(radius), startAngle: 218, endAngle: 322)
        arc.lineWidth = 1.5
        arc.stroke()
    }

    rounded(CGRect(x: iconGroupX + 48, y: 15, width: 25, height: 12), radius: 3, fill: NSColor.clear, stroke: iconColor, lineWidth: 1.4)
    rounded(CGRect(x: iconGroupX + 75, y: 18, width: 2.6, height: 6), radius: 1.2, fill: iconColor)
    rounded(CGRect(x: iconGroupX + 51, y: 18, width: 16, height: 6), radius: 2, fill: iconColor.withAlphaComponent(0.34))

    for offset in [0.0, 7.0, 14.0] {
        line(
            CGPoint(x: iconGroupX + 90, y: 15 + CGFloat(offset)),
            CGPoint(x: iconGroupX + 114, y: 15 + CGFloat(offset)),
            color: iconColor,
            width: 1.3
        )
    }
    iconColor.setFill()
    NSBezierPath(ovalIn: CGRect(x: iconGroupX + 96, y: 12.7, width: 4.8, height: 4.8)).fill()
    NSBezierPath(ovalIn: CGRect(x: iconGroupX + 108, y: 19.7, width: 4.8, height: 4.8)).fill()
    NSBezierPath(ovalIn: CGRect(x: iconGroupX + 102, y: 26.7, width: 4.8, height: 4.8)).fill()

    if activeIconX != nil {
        rounded(CGRect(x: trayX - 11, y: 6, width: 34, height: 30), radius: 9, fill: NSColor.white.withAlphaComponent(0.36), stroke: NSColor.white.withAlphaComponent(0.55), lineWidth: 0.8)
    }
    drawTrayGlyph(center: CGPoint(x: trayX + 6, y: 21), size: 19, color: codex)
    drawText(time, x: width - 176, y: 11, size: 14, weight: .medium, color: NSColor.black.withAlphaComponent(0.66), width: 150, align: .right)
}

func trafficLights(x: CGFloat, y: CGFloat) {
    let colors = [
        NSColor(calibratedRed: 1.00, green: 0.36, blue: 0.32, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.20, alpha: 1),
        NSColor(calibratedRed: 0.21, green: 0.80, blue: 0.32, alpha: 1),
    ]
    for (index, color) in colors.enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: x + CGFloat(index) * 22, y: y, width: 12, height: 12)).fill()
    }
}

func accountIcon(center: CGPoint, color: NSColor, active: Bool = false, selected: Bool = false) {
    let radius: CGFloat = selected ? 21 : 16
    color.withAlphaComponent(selected ? 0.90 : 0.78).setStroke()
    let outer = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    outer.lineWidth = selected ? 3.4 : 2.8
    outer.stroke()

    color.withAlphaComponent(selected ? 0.92 : 0.68).setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - 6.4, y: center.y - 8, width: 12.8, height: 12.8)).fill()
    let body = NSBezierPath()
    body.appendArc(withCenter: CGPoint(x: center.x, y: center.y + 14), radius: 17, startAngle: 210, endAngle: 330)
    body.line(to: CGPoint(x: center.x + 13, y: center.y + 10))
    body.appendArc(withCenter: CGPoint(x: center.x, y: center.y + 15), radius: 17, startAngle: 315, endAngle: 225, clockwise: true)
    body.close()
    body.fill()

    if active {
        let badgeCenter = CGPoint(x: center.x - radius + 4, y: center.y + radius - 5)
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: CGRect(x: badgeCenter.x - 8, y: badgeCenter.y - 8, width: 16, height: 16)).fill()
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: badgeCenter.x - 6.5, y: badgeCenter.y - 6.5, width: 13, height: 13)).fill()
        white.setStroke()
        let check = NSBezierPath()
        check.move(to: CGPoint(x: badgeCenter.x - 3.5, y: badgeCenter.y))
        check.line(to: CGPoint(x: badgeCenter.x - 1, y: badgeCenter.y + 2.8))
        check.line(to: CGPoint(x: badgeCenter.x + 4.8, y: badgeCenter.y - 4))
        check.lineWidth = 1.9
        check.stroke()
    }
}

func drawTrayGlyph(center: CGPoint, size: CGFloat, color: NSColor) {
    let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    rounded(rect, radius: size * 0.28, fill: color.withAlphaComponent(0.96))
    NSColor.white.withAlphaComponent(0.96).setStroke()
    let ring = NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.27, dy: size * 0.20))
    ring.lineWidth = 1.6
    ring.stroke()
    NSColor.white.withAlphaComponent(0.98).setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - size * 0.10, y: center.y - size * 0.03, width: size * 0.20, height: size * 0.20)).fill()
}

func progressBar(x: CGFloat, y: CGFloat, width: CGFloat, progress: CGFloat, color: NSColor, height: CGFloat = 12) {
    rounded(CGRect(x: x, y: y, width: width, height: height), radius: height / 2, fill: NSColor.white.withAlphaComponent(0.36), stroke: NSColor(calibratedWhite: 0.20, alpha: 0.13), lineWidth: 0.8)
    let fillWidth = max(height, (width - 4) * progress)
    rounded(CGRect(x: x + 2, y: y + 2, width: fillWidth, height: height - 4), radius: (height - 4) / 2, fill: color.withAlphaComponent(0.92))
}

func providerPill(x: CGFloat, y: CGFloat, title: String, selected: Bool, color: NSColor, width: CGFloat) {
    if selected {
        rounded(CGRect(x: x, y: y, width: width, height: 32), radius: 16, fill: color.withAlphaComponent(0.88), stroke: NSColor.white.withAlphaComponent(0.45), lineWidth: 0.8)
        drawText(title, x: x, y: y + 6, size: 13, weight: .semibold, color: white, width: width, align: .center)
    } else {
        drawText(title, x: x, y: y + 6, size: 13, weight: .semibold, color: textColor.withAlphaComponent(0.58), width: width, align: .center)
    }
}

func sidebarRow(y: CGFloat, title: String, subtitle: String?, percent: String?, color: NSColor, active: Bool, selected: Bool, windowX: CGFloat = 0) {
    let left = windowX + 28
    let rowHeight: CGFloat = subtitle == nil ? 58 : 74
    if selected {
        rounded(CGRect(x: left, y: y - 9, width: 352, height: rowHeight), radius: 16, fill: color.withAlphaComponent(0.88), stroke: NSColor.white.withAlphaComponent(0.36), lineWidth: 0.8)
    }
    let contentColor = selected ? white : textColor
    let subColor = selected ? NSColor.white.withAlphaComponent(0.74) : secondary.withAlphaComponent(0.82)
    accountIcon(center: CGPoint(x: left + 34, y: y + 19), color: selected ? white : color, active: active, selected: selected)
    drawText(title, x: left + 68, y: y - 2, size: 17, weight: .semibold, color: contentColor, width: 208)
    if let subtitle {
        drawText(subtitle, x: left + 68, y: y + 23, size: 12.5, weight: .medium, color: subColor, width: 230)
    }
    if let percent {
        monoText(percent, x: left + 284, y: y + (subtitle == nil ? 6 : 12), width: 48, size: 14, weight: .semibold, color: selected ? white.withAlphaComponent(0.82) : secondary.withAlphaComponent(0.78))
    }
}

func limitLine(label: String, progress: CGFloat, color: NSColor, reset: String, y: CGFloat, x: CGFloat, width: CGFloat) {
    drawText(label, x: x, y: y, size: 16, weight: .semibold, color: secondary, width: 180)
    progressBar(x: x + 194, y: y + 8, width: width - 430, progress: progress, color: color, height: 13)
    monoText("\(Int(round(progress * 100)))% осталось", x: x + width - 218, y: y - 1, width: 120, size: 15, weight: .semibold, color: textColor)
    drawText(reset, x: x + width - 96, y: y + 1, size: 12.5, weight: .medium, color: muted, width: 180)
}

func drawWindowScene() throws -> NSImage {
    try image(width: 1600, height: 1000) { rect in
        drawWallpaper(rect)
        drawMenuBar(width: rect.width, time: "Чт 23 апр. 22:58")

        let window = CGRect(x: 145, y: 108, width: 1310, height: 810)
        shadowedRounded(window, radius: 30, fill: NSColor.white.withAlphaComponent(0.72), stroke: NSColor.white.withAlphaComponent(0.80), blur: 48, offsetY: 24, alpha: 0.27)

        let clip = NSBezierPath(roundedRect: window, xRadius: 30, yRadius: 30)
        withGraphics {
            clip.addClip()
            rounded(window, radius: 30, fill: NSColor.white.withAlphaComponent(0.52))
            CGRect(x: window.minX, y: window.minY, width: 406, height: window.height).fill(using: .sourceOver)
            NSColor.white.withAlphaComponent(0.34).setFill()
            CGRect(x: window.minX, y: window.minY, width: 406, height: window.height).fill()
            NSColor.white.withAlphaComponent(0.20).setFill()
            CGRect(x: window.minX + 406, y: window.minY, width: window.width - 406, height: window.height).fill()
            NSColor.white.withAlphaComponent(0.30).setFill()
            CGRect(x: window.minX, y: window.minY, width: window.width, height: 66).fill()
        }

        trafficLights(x: window.minX + 26, y: window.minY + 24)
        drawText("Limits", x: window.minX + 112, y: window.minY + 21, size: 15, weight: .semibold, color: textColor.withAlphaComponent(0.78), width: 120)
        line(CGPoint(x: window.minX + 406, y: window.minY), CGPoint(x: window.minX + 406, y: window.maxY), color: NSColor.white.withAlphaComponent(0.45), width: 1)
        line(CGPoint(x: window.minX, y: window.minY + 66), CGPoint(x: window.maxX, y: window.minY + 66), color: NSColor.black.withAlphaComponent(0.08), width: 1)

        rounded(CGRect(x: window.minX + 88, y: window.minY + 86, width: 248, height: 36), radius: 18, fill: NSColor.white.withAlphaComponent(0.34), stroke: NSColor.black.withAlphaComponent(0.08), lineWidth: 0.8)
        providerPill(x: window.minX + 91, y: window.minY + 88, title: "Все", selected: true, color: codex, width: 72)
        providerPill(x: window.minX + 166, y: window.minY + 88, title: "Codex", selected: false, color: codex, width: 82)
        providerPill(x: window.minX + 250, y: window.minY + 88, title: "Claude", selected: false, color: claude, width: 84)

        sidebarRow(y: window.minY + 154, title: "Codex CLI", subtitle: "codex@example.com", percent: "70%", color: codex, active: true, selected: false, windowX: window.minX)
        sidebarRow(y: window.minY + 232, title: "Claude Code", subtitle: "claude@example.com", percent: "85%", color: claude, active: true, selected: true, windowX: window.minX)

        line(CGPoint(x: window.minX + 34, y: window.minY + 332), CGPoint(x: window.minX + 370, y: window.minY + 332), color: NSColor.black.withAlphaComponent(0.10), width: 1)
        drawText("Аккаунты Codex", x: window.minX + 34, y: window.minY + 357, size: 12, weight: .bold, color: muted.withAlphaComponent(0.90), width: 180)
        sidebarRow(y: window.minY + 400, title: "work@codex.example", subtitle: nil, percent: "99%", color: NSColor.gray, active: false, selected: false, windowX: window.minX)
        sidebarRow(y: window.minY + 464, title: "research@codex.example", subtitle: nil, percent: "70%", color: codex, active: true, selected: false, windowX: window.minX)
        sidebarRow(y: window.minY + 528, title: "backup@codex.example", subtitle: nil, percent: "0%", color: NSColor.systemOrange, active: false, selected: false, windowX: window.minX)

        line(CGPoint(x: window.minX + 34, y: window.minY + 610), CGPoint(x: window.minX + 370, y: window.minY + 610), color: NSColor.black.withAlphaComponent(0.10), width: 1)
        drawText("Аккаунты Claude", x: window.minX + 34, y: window.minY + 635, size: 12, weight: .bold, color: muted.withAlphaComponent(0.90), width: 180)
        sidebarRow(y: window.minY + 678, title: "claude@example.com", subtitle: nil, percent: "85%", color: claude, active: true, selected: false, windowX: window.minX)

        let contentX = window.minX + 464
        let contentWidth = window.width - 535
        drawText("claude@example.com", x: contentX, y: window.minY + 112, size: 34, weight: .semibold, color: textColor, width: 610)
        drawText("Claude Max · Текущий аккаунт", x: contentX + 1, y: window.minY + 157, size: 16, weight: .medium, color: secondary, width: 420)
        rounded(CGRect(x: window.maxX - 178, y: window.minY + 118, width: 86, height: 30), radius: 15, fill: claude.withAlphaComponent(0.14), stroke: claude.withAlphaComponent(0.16), lineWidth: 0.8)
        drawText("Текущий", x: window.maxX - 166, y: window.minY + 124, size: 12.5, weight: .semibold, color: claude, width: 70)

        line(CGPoint(x: contentX, y: window.minY + 222), CGPoint(x: window.maxX - 88, y: window.minY + 222), color: NSColor.black.withAlphaComponent(0.10), width: 1)
        drawText("Claude Code", x: contentX, y: window.minY + 260, size: 22, weight: .semibold, color: textColor, width: 260)
        limitLine(label: "5ч лимит", progress: 0.85, color: claude, reset: "Сброс в 22:51", y: window.minY + 320, x: contentX, width: contentWidth)
        limitLine(label: "Недельный лимит", progress: 0.98, color: claude, reset: "Сброс 30 апреля", y: window.minY + 382, x: contentX, width: contentWidth)

        line(CGPoint(x: contentX, y: window.minY + 476), CGPoint(x: window.maxX - 88, y: window.minY + 476), color: NSColor.black.withAlphaComponent(0.10), width: 1)
        drawText("GPT-5.3-Codex-Spark", x: contentX, y: window.minY + 514, size: 22, weight: .semibold, color: textColor, width: 340)
        limitLine(label: "5ч лимит", progress: 1.00, color: codex, reset: "Сброс в 22:52", y: window.minY + 574, x: contentX, width: contentWidth)
        limitLine(label: "Недельный лимит", progress: 0.70, color: codex, reset: "Сброс 30 апреля", y: window.minY + 636, x: contentX, width: contentWidth)

        drawText("Обновлено 22:58", x: contentX, y: window.maxY - 74, size: 13, weight: .medium, color: muted.withAlphaComponent(0.72), width: 220)
    }
}

func trayAccountCard(x: CGFloat, y: CGFloat, width: CGFloat, provider: String, account: String, color: NSColor, active: Bool, first: CGFloat, second: CGFloat) {
    rounded(CGRect(x: x, y: y, width: width, height: 130), radius: 22, fill: NSColor.white.withAlphaComponent(0.34), stroke: NSColor.white.withAlphaComponent(0.46), lineWidth: 1)
    accountIcon(center: CGPoint(x: x + 35, y: y + 36), color: color, active: active, selected: false)
    drawText(provider, x: x + 66, y: y + 20, size: 13, weight: .semibold, color: muted, width: 140)
    drawText(account, x: x + 66, y: y + 42, size: 17, weight: .semibold, color: textColor, width: 265)
    if active {
        rounded(CGRect(x: x + width - 94, y: y + 24, width: 68, height: 25), radius: 12.5, fill: color.withAlphaComponent(0.14), stroke: color.withAlphaComponent(0.16), lineWidth: 0.8)
        drawText("Текущий", x: x + width - 84, y: y + 29, size: 11.5, weight: .semibold, color: color, width: 56)
    }
    progressBar(x: x + 66, y: y + 78, width: width - 154, progress: first, color: color, height: 10)
    monoText("\(Int(round(first * 100)))%", x: x + width - 72, y: y + 69, width: 42, size: 12.5, weight: .semibold, color: secondary)
    progressBar(x: x + 66, y: y + 105, width: width - 154, progress: second, color: color, height: 10)
    monoText("\(Int(round(second * 100)))%", x: x + width - 72, y: y + 96, width: 42, size: 12.5, weight: .semibold, color: secondary)
}

func drawTrayScene() throws -> NSImage {
    try image(width: 1220, height: 820) { rect in
        drawWallpaper(rect)
        let trayX: CGFloat = rect.width - 242
        drawMenuBar(width: rect.width, activeIconX: trayX, time: "Чт 23 апр. 22:58")

        rounded(CGRect(x: 72, y: 118, width: 118, height: 88), radius: 18, fill: NSColor.white.withAlphaComponent(0.18), stroke: NSColor.white.withAlphaComponent(0.23), lineWidth: 1)
        rounded(CGRect(x: 88, y: 132, width: 36, height: 28), radius: 8, fill: NSColor.white.withAlphaComponent(0.26))
        rounded(CGRect(x: 138, y: 132, width: 36, height: 28), radius: 8, fill: NSColor.white.withAlphaComponent(0.20))
        drawText("Демо", x: 86, y: 170, size: 13, weight: .medium, color: NSColor.white.withAlphaComponent(0.82), width: 88, align: .center)

        let popover = CGRect(x: rect.width - 640, y: 62, width: 560, height: 660)
        let arrow = NSBezierPath()
        arrow.move(to: CGPoint(x: trayX + 6, y: 42))
        arrow.line(to: CGPoint(x: trayX - 14, y: 64))
        arrow.line(to: CGPoint(x: trayX + 26, y: 64))
        arrow.close()

        withGraphics {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 42
            shadow.shadowOffset = CGSize(width: 0, height: 18)
            shadow.set()
            arrow.fill()
            rounded(popover, radius: 30, fill: NSColor.white.withAlphaComponent(0.62), stroke: NSColor.white.withAlphaComponent(0.80), lineWidth: 1)
        }
        NSColor.white.withAlphaComponent(0.64).setFill()
        arrow.fill()
        NSColor.white.withAlphaComponent(0.34).setStroke()
        arrow.lineWidth = 1
        arrow.stroke()

        rounded(popover.insetBy(dx: 1.5, dy: 1.5), radius: 28, fill: NSColor.white.withAlphaComponent(0.20), stroke: NSColor.white.withAlphaComponent(0.28), lineWidth: 0.8)
        drawText("Limits", x: popover.minX + 34, y: popover.minY + 28, size: 22, weight: .semibold, color: textColor, width: 190)
        drawText("Обновлено 22:58", x: popover.maxX - 184, y: popover.minY + 34, size: 12.5, weight: .medium, color: muted, width: 150, align: .right)
        rounded(CGRect(x: popover.minX + 34, y: popover.minY + 72, width: popover.width - 68, height: 38), radius: 19, fill: NSColor.white.withAlphaComponent(0.30), stroke: NSColor.black.withAlphaComponent(0.08), lineWidth: 0.8)
        providerPill(x: popover.minX + 38, y: popover.minY + 75, title: "Все", selected: true, color: codex, width: 112)
        providerPill(x: popover.minX + 154, y: popover.minY + 75, title: "Codex", selected: false, color: codex, width: 154)
        providerPill(x: popover.minX + 312, y: popover.minY + 75, title: "Claude", selected: false, color: claude, width: 172)

        drawText("Codex CLI", x: popover.minX + 34, y: popover.minY + 142, size: 18, weight: .semibold, color: textColor, width: 180)
        drawText("3 аккаунта", x: popover.maxX - 124, y: popover.minY + 146, size: 12.5, weight: .medium, color: muted, width: 90, align: .right)
        trayAccountCard(x: popover.minX + 34, y: popover.minY + 184, width: popover.width - 68, provider: "Codex", account: "codex@example.com", color: codex, active: true, first: 0.70, second: 0.62)

        line(CGPoint(x: popover.minX + 34, y: popover.minY + 350), CGPoint(x: popover.maxX - 34, y: popover.minY + 350), color: NSColor.black.withAlphaComponent(0.10), width: 1)
        drawText("Claude Code", x: popover.minX + 34, y: popover.minY + 382, size: 18, weight: .semibold, color: textColor, width: 180)
        drawText("1 аккаунт", x: popover.maxX - 124, y: popover.minY + 386, size: 12.5, weight: .medium, color: muted, width: 90, align: .right)
        trayAccountCard(x: popover.minX + 34, y: popover.minY + 424, width: popover.width - 68, provider: "Claude", account: "claude@example.com", color: claude, active: true, first: 0.85, second: 0.98)

        line(CGPoint(x: popover.minX + 34, y: popover.maxY - 84), CGPoint(x: popover.maxX - 34, y: popover.maxY - 84), color: NSColor.black.withAlphaComponent(0.10), width: 1)
        drawText("Открыть окно", x: popover.minX + 34, y: popover.maxY - 51, size: 14, weight: .semibold, color: codex, width: 140)
        drawText("Обновить значения", x: popover.maxX - 184, y: popover.maxY - 51, size: 14, weight: .medium, color: secondary, width: 150, align: .right)
    }
}

try save(try drawWindowScene(), to: outputDirectory.appending(path: "limits-window.png"))
try save(try drawTrayScene(), to: outputDirectory.appending(path: "limits-tray.png"))
print("Generated docs/images/limits-window.png")
print("Generated docs/images/limits-tray.png")
