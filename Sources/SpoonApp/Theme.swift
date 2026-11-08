import AppKit
import SwiftUI

/// Semantic color tokens (§5.1), built on system colors so accent, contrast and dark mode follow the system.
@MainActor
enum Theme {
    static func dynamic(_ base: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return base.withAlphaComponent(isDark ? dark : light)
        }
    }

    static let addLine = dynamic(.systemGreen, light: 0.14, dark: 0.22)
    static let addWord = dynamic(.systemGreen, light: 0.32, dark: 0.42)
    static let delLine = dynamic(.systemRed, light: 0.12, dark: 0.22)
    static let delWord = dynamic(.systemRed, light: 0.30, dark: 0.42)
    static let filler = NSColor.quaternaryLabelColor.withAlphaComponent(0.3)
    static let hunkHeader = NSColor.windowBackgroundColor
    static let searchMatch = dynamic(.systemYellow, light: 0.55, dark: 0.45)

    /// Graph lane palette, in spec order. Lane color 0 (main) uses the accent color.
    static let lanes: [NSColor] = [
        .systemBlue, .systemOrange, .systemGreen, .systemPink, .systemPurple, .systemTeal,
        .systemYellow, .systemRed, .systemIndigo, .systemBrown, .systemMint, .systemGray,
    ]

    static func lane(_ i: Int) -> NSColor { i == 0 ? .controlAccentColor : lanes[i % lanes.count] }

    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let rowFont = NSFont.systemFont(ofSize: 13)
    static let digitsFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let secondaryFont = NSFont.systemFont(ofSize: 11)

    static func statusColor(_ letter: Character) -> NSColor {
        switch letter {
        case "M": .systemYellow
        case "A", "U", "?": .systemGreen
        case "D": .systemRed
        case "R": .systemBlue
        case "C": .systemTeal
        case "!": .systemOrange
        default: .systemGray
        }
    }
}

/// Rounded-square file status badge with a letter, so it is never color-only (§5.1).
struct StatusBadge: View {
    let letter: Character
    var body: some View {
        let color = Color(nsColor: Theme.statusColor(letter))
        Text(String(letter == "?" ? "U" : letter))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .frame(width: 14, height: 14)
            .foregroundStyle(letter == "?" || letter == "U" ? color : .white)
            .background(RoundedRectangle(cornerRadius: 3).fill(letter == "?" || letter == "U" ? .clear : color))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: letter == "?" || letter == "U" ? 1 : 0))
            .accessibilityLabel(StatusBadge.name(letter))
    }

    static func name(_ l: Character) -> String {
        switch l {
        case "M": "Modified"
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        case "T": "Type changed"
        case "?", "U": "Untracked"
        case "!": "Conflicted"
        default: "Changed"
        }
    }
}

/// Initials avatar with a stable color per email (HIST-10 fallback).
struct Avatar: View {
    let name: String
    let email: String
    var size: CGFloat = 16

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Circle()
            .fill(Color(nsColor: Theme.lanes[Int(email.lowercased().utf8.reduce(UInt32(5381)) { $0 &* 33 &+ UInt32($1) } % 12)]))
            .frame(width: size, height: size)
            .overlay(Text(initials.uppercased()).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

enum Format {
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static let absolute: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
    static let full: DateFormatter = { let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .medium; return f }()

    /// "Today 14:29", "Yesterday 22:05", otherwise absolute (§5.7.1).
    static func date(_ unix: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(unix))
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today \(time.string(from: d))" }
        if cal.isDateInYesterday(d) { return "Yesterday \(time.string(from: d))" }
        return absolute.string(from: d)
    }

    static func age(_ date: Date?) -> String {
        guard let date else { return "never" }
        // Also covers file mtimes a few ms ahead of now, which would read "in 0 sec.".
        if date.timeIntervalSinceNow > -5 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
