import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root.appending(path: "docs/images")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let codex = NSColor(calibratedRed: 0.00, green: 0.43, blue: 0.96, alpha: 1)
let claude = NSColor(calibratedRed: 0.86, green: 0.39, blue: 0.24, alpha: 1)
let text = NSColor(calibratedWhite: 0.08, alpha: 1)
let secondary = NSColor(calibratedWhite: 0.43, alpha: 1)
let muted = NSColor(calibratedWhite: 0.72, alpha: 1)
let panel = NSColor(calibratedWhite: 0.965, alpha: 1)
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

func line(_ from: CGPoint, _ to: CGPoint, color: NSColor, width: CGFloat = 1) {
    let path = NSBezierPath()
    path.move(to: from)
    path.line(to: to)
    color.setStroke()
    path.lineWidth = width
    path.stroke()
}

func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = text, width: CGFloat = 500) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    string.draw(in: CGRect(x: x, y: y, width: width, height: size + 8), withAttributes: attrs)
}

func rightText(_ string: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = secondary) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    string.draw(in: CGRect(x: x, y: y, width: width, height: size + 8), withAttributes: attrs)
}

func accountIcon(center: CGPoint, color: NSColor, active: Bool = false, selected: Bool = false) {
    let radius: CGFloat = selected ? 22 : 17
    color.setStroke()
    let outer = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    outer.lineWidth = selected ? 4 : 3
    outer.stroke()

    color.withAlphaComponent(selected ? 0.95 : 0.72).setFill()
    NSBezierPath(ovalIn: CGRect(x: center.x - 7, y: center.y - 9, width: 14, height: 14)).fill()
    let body = NSBezierPath()
    body.appendArc(withCenter: CGPoint(x: center.x, y: center.y + 15), radius: 18, startAngle: 210, endAngle: 330)
    body.line(to: CGPoint(x: center.x + 14, y: center.y + 10))
    body.appendArc(withCenter: CGPoint(x: center.x, y: center.y + 16), radius: 19, startAngle: 315, endAngle: 225, clockwise: true)
    body.close()
    body.fill()

    if active {
        let badgeCenter = CGPoint(x: center.x - radius + 4, y: center.y + radius - 5)
        white.setFill()
        NSBezierPath(ovalIn: CGRect(x: badgeCenter.x - 8, y: badgeCenter.y - 8, width: 16, height: 16)).fill()
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: badgeCenter.x - 7, y: badgeCenter.y - 7, width: 14, height: 14)).fill()
        white.setStroke()
        let check = NSBezierPath()
        check.move(to: CGPoint(x: badgeCenter.x - 4, y: badgeCenter.y))
        check.line(to: CGPoint(x: badgeCenter.x - 1, y: badgeCenter.y + 3))
        check.line(to: CGPoint(x: badgeCenter.x + 5, y: badgeCenter.y - 4))
        check.lineWidth = 2
        check.stroke()
    }
}

func progressBar(x: CGFloat, y: CGFloat, width: CGFloat, progress: CGFloat, color: NSColor) {
    rounded(CGRect(x: x, y: y, width: width, height: 12), radius: 6, fill: NSColor(calibratedWhite: 0.90, alpha: 1), stroke: NSColor(calibratedWhite: 0.82, alpha: 1), lineWidth: 0.8)
    rounded(CGRect(x: x + 2, y: y + 2, width: max(8, (width - 4) * progress), height: 8), radius: 4, fill: color)
}

func sidebarRow(y: CGFloat, title: String, subtitle: String?, percent: String?, color: NSColor, active: Bool, selected: Bool) {
    if selected {
        rounded(CGRect(x: 24, y: y - 10, width: 380, height: subtitle == nil ? 58 : 76), radius: 14, fill: color)
    }
    let contentColor = selected ? white : text
    let subColor = selected ? NSColor.white.withAlphaComponent(0.72) : secondary
    accountIcon(center: CGPoint(x: 58, y: y + 18), color: selected ? white : color, active: active, selected: selected)
    text(title, x: 92, y: y - 2, size: 20, weight: .semibold, color: contentColor, width: 250)
    if let subtitle {
        text(subtitle, x: 92, y: y + 24, size: 14, weight: .medium, color: subColor, width: 260)
    }
    if let percent {
        rightText(percent, x: 328, y: y + (subtitle == nil ? 5 : 12), width: 55, size: 16, weight: .semibold, color: selected ? white.withAlphaComponent(0.82) : secondary)
    }
}

let windowImage = try image(width: 1320, height: 860) { rect in
    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    rect.fill()
    rounded(CGRect(x: 24, y: 24, width: 1272, height: 812), radius: 22, fill: white, stroke: NSColor(calibratedWhite: 0.86, alpha: 1))
    NSColor(calibratedWhite: 0.975, alpha: 1).setFill()
    CGRect(x: 24, y: 24, width: 420, height: 812).fill()
    line(CGPoint(x: 444, y: 24), CGPoint(x: 444, y: 836), color: NSColor(calibratedWhite: 0.86, alpha: 1))

    rounded(CGRect(x: 105, y: 50, width: 260, height: 38), radius: 10, fill: NSColor(calibratedWhite: 0.90, alpha: 1))
    rounded(CGRect(x: 106, y: 51, width: 86, height: 36), radius: 9, fill: codex)
    text("Все", x: 132, y: 57, size: 16, weight: .semibold, color: white, width: 80)
    text("Codex", x: 206, y: 57, size: 16, weight: .semibold, color: text, width: 90)
    text("Claude", x: 292, y: 57, size: 16, weight: .semibold, color: text, width: 90)

    sidebarRow(y: 122, title: "Codex CLI", subtitle: "codex@example.com", percent: "70%", color: codex, active: true, selected: false)
    sidebarRow(y: 202, title: "Claude Code", subtitle: "claude@example.com", percent: "85%", color: claude, active: true, selected: true)

    text("Аккаунты Codex", x: 34, y: 304, size: 16, weight: .bold, color: muted, width: 250)
    sidebarRow(y: 354, title: "work@codex.example", subtitle: nil, percent: "99%", color: NSColor.gray, active: false, selected: false)
    sidebarRow(y: 420, title: "research@codex.example", subtitle: nil, percent: "70%", color: codex, active: true, selected: false)
    sidebarRow(y: 486, title: "backup@codex.example", subtitle: nil, percent: "0%", color: NSColor.systemOrange, active: false, selected: false)

    text("Аккаунты Claude", x: 34, y: 580, size: 16, weight: .bold, color: muted, width: 250)
    sidebarRow(y: 630, title: "claude@example.com", subtitle: nil, percent: "85%", color: claude, active: true, selected: false)

    text("claude@example.com", x: 490, y: 78, size: 34, weight: .semibold, color: text, width: 620)
    text("Claude Max · Текущий аккаунт", x: 492, y: 122, size: 17, weight: .medium, color: secondary, width: 520)
    rounded(CGRect(x: 1110, y: 82, width: 86, height: 30), radius: 15, fill: claude.withAlphaComponent(0.14))
    text("Текущий", x: 1122, y: 87, size: 13, weight: .semibold, color: claude, width: 90)

    line(CGPoint(x: 492, y: 185), CGPoint(x: 1220, y: 185), color: NSColor(calibratedWhite: 0.88, alpha: 1))
    text("Claude Code", x: 492, y: 226, size: 22, weight: .semibold, color: text, width: 250)
    text("5ч лимит", x: 492, y: 282, size: 17, weight: .semibold, color: secondary, width: 150)
    progressBar(x: 660, y: 288, width: 360, progress: 0.85, color: claude)
    rightText("85% осталось", x: 1040, y: 276, width: 150, size: 17, weight: .semibold, color: text)
    text("Сброс в 22:51", x: 1085, y: 302, size: 12, weight: .regular, color: secondary, width: 150)
    text("Недельный лимит", x: 492, y: 342, size: 17, weight: .semibold, color: secondary, width: 170)
    progressBar(x: 660, y: 348, width: 360, progress: 0.98, color: claude)
    rightText("98% осталось", x: 1040, y: 336, width: 150, size: 17, weight: .semibold, color: text)
    text("Сброс в 17:51, 30 апреля", x: 1030, y: 362, size: 12, weight: .regular, color: secondary, width: 200)
}

let trayImage = try image(width: 720, height: 620) { rect in
    NSColor.clear.setFill()
    rect.fill()
    rounded(CGRect(x: 28, y: 24, width: 664, height: 572), radius: 28, fill: NSColor.white.withAlphaComponent(0.90), stroke: NSColor.white.withAlphaComponent(0.80), lineWidth: 1)

    text("Codex CLI", x: 62, y: 56, size: 18, weight: .semibold, color: text, width: 240)
    text("3 аккаунта", x: 560, y: 58, size: 13, weight: .medium, color: secondary, width: 120)
    rounded(CGRect(x: 58, y: 94, width: 604, height: 150), radius: 20, fill: NSColor.white.withAlphaComponent(0.55), stroke: NSColor(calibratedWhite: 0.82, alpha: 0.5))
    accountIcon(center: CGPoint(x: 90, y: 126), color: codex, active: true, selected: false)
    text("codex@example.com", x: 122, y: 103, size: 17, weight: .semibold, color: text, width: 300)
    rounded(CGRect(x: 560, y: 105, width: 64, height: 24), radius: 12, fill: codex.withAlphaComponent(0.12))
    text("Текущий", x: 568, y: 109, size: 11, weight: .semibold, color: codex, width: 70)
    progressBar(x: 122, y: 154, width: 420, progress: 0.70, color: codex)
    rightText("70%", x: 565, y: 146, width: 55, size: 13, weight: .semibold, color: secondary)
    progressBar(x: 122, y: 188, width: 420, progress: 0.62, color: codex)
    rightText("62%", x: 565, y: 180, width: 55, size: 13, weight: .semibold, color: secondary)

    line(CGPoint(x: 58, y: 274), CGPoint(x: 662, y: 274), color: NSColor(calibratedWhite: 0.86, alpha: 1))
    text("Claude Code", x: 62, y: 304, size: 18, weight: .semibold, color: text, width: 240)
    text("1 аккаунт", x: 560, y: 306, size: 13, weight: .medium, color: secondary, width: 120)
    rounded(CGRect(x: 58, y: 342, width: 604, height: 150), radius: 20, fill: NSColor.white.withAlphaComponent(0.55), stroke: NSColor(calibratedWhite: 0.82, alpha: 0.5))
    accountIcon(center: CGPoint(x: 90, y: 374), color: claude, active: true, selected: false)
    text("claude@example.com", x: 122, y: 351, size: 17, weight: .semibold, color: text, width: 300)
    rounded(CGRect(x: 560, y: 353, width: 64, height: 24), radius: 12, fill: claude.withAlphaComponent(0.14))
    text("Текущий", x: 568, y: 357, size: 11, weight: .semibold, color: claude, width: 70)
    progressBar(x: 122, y: 402, width: 420, progress: 0.85, color: claude)
    rightText("85%", x: 565, y: 394, width: 55, size: 13, weight: .semibold, color: secondary)
    progressBar(x: 122, y: 436, width: 420, progress: 0.98, color: claude)
    rightText("98%", x: 565, y: 428, width: 55, size: 13, weight: .semibold, color: secondary)

    text("Окно…", x: 58, y: 536, size: 14, weight: .semibold, color: codex, width: 80)
    text("Обновить значения", x: 468, y: 536, size: 14, weight: .medium, color: secondary, width: 160)
}

try save(windowImage, to: outputDirectory.appending(path: "limits-window.png"))
try save(trayImage, to: outputDirectory.appending(path: "limits-tray.png"))
print("Generated docs/images/limits-window.png")
print("Generated docs/images/limits-tray.png")
