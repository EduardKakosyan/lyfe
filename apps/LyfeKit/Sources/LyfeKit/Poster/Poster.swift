import SwiftUI

/// The Poster look: flat colour, heavy type, hard edges. One colour per
/// routine; solid means done, stripes mean in recovery or estimated,
/// outline means still open.
public enum Poster {
    public static let ink = Color(red: 0x0e / 255, green: 0x0e / 255, blue: 0x0e / 255)
    public static let paper = Color(red: 0xf3 / 255, green: 0xef / 255, blue: 0xe6 / 255)
    /// Gym.
    public static let red = Color(red: 0xff / 255, green: 0x4a / 255, blue: 0x1c / 255)
    /// The darker stripe on the gym band while its streak is in recovery.
    public static let redShade = Color(red: 0xdb / 255, green: 0x36 / 255, blue: 0x0c / 255)
    /// Breath and pool.
    public static let blue = Color(red: 0x28 / 255, green: 0x48 / 255, blue: 0xff / 255)
    /// The darker stripe on the breath band while its streak is in recovery.
    public static let blueShade = Color(red: 0x1d / 255, green: 0x38 / 255, blue: 0xd9 / 255)
    /// Food.
    public static let yellow = Color(red: 0xff / 255, green: 0xd2 / 255, blue: 0x1f / 255)

    /// Thickness of the rules between sections.
    public static let rule: CGFloat = 3
    public static let margin: CGFloat = 18
}

extension Poster {
    /// Text for a giant figure, set tighter than the font spaces it. The
    /// squeeze goes between characters only: after the last one it would
    /// make the text narrower than its ink, and the edge of the last
    /// character would be cut off.
    static func tight(_ text: String, by kern: CGFloat) -> AttributedString {
        var string = AttributedString(text)
        string.kern = kern
        if let last = string.characters.indices.last {
            string[last...].kern = 0
        }
        return string
    }
}

extension Text {
    /// Small tracked capitals: every label that is not the number.
    func posterLabel() -> some View {
        self.font(.system(size: 11, weight: .bold))
            .tracking(0.9)
            .textCase(.uppercase)
    }

    /// A routine's name or a heading.
    func posterHeading(_ size: CGFloat = 22) -> some View {
        self.font(.system(size: size, weight: .heavy))
            .tracking(-size * 0.03)
            .textCase(.uppercase)
    }
}

/// A full-width ink line.
struct PosterRule: View {
    var thickness: CGFloat = Poster.rule

    var body: some View {
        Rectangle()
            .fill(Poster.ink)
            .frame(height: thickness)
    }
}

/// The three states every Poster mark can be in.
enum MarkState {
    case solid, striped, outline
}

/// A square mark: a session done, a source healthy, and so on.
struct PosterSquare: View {
    var state: MarkState
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            switch state {
            case .solid:
                Rectangle().fill(.foreground)
            case .striped:
                Stripes(spacing: max(2, size / 5)).clipped()
            case .outline:
                EmptyView()
            }
            Rectangle().strokeBorder(.foreground, lineWidth: max(2, size * 0.14))
        }
        .frame(width: size, height: size)
    }
}

/// Diagonal stripes in the foreground colour.
struct Stripes: View {
    var spacing: CGFloat

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing * 2
            }
            context.stroke(path, with: .foreground, lineWidth: spacing)
        }
    }
}

/// Broad diagonal stripes of a second colour over a band: the streak is in
/// recovery.
struct Hatch: View {
    var colour: Color
    var width: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + width, y: 0))
                path.addLine(to: CGPoint(x: x + width - size.height, y: size.height))
                path.addLine(to: CGPoint(x: x - size.height, y: size.height))
                path.closeSubpath()
                x += width * 2
            }
            context.fill(path, with: .color(colour))
        }
        .accessibilityHidden(true)
    }
}

/// How long ago something happened, in Poster capitals: "2 MIN AGO".
public func agoLabel(from past: Date, to now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(past)))
    switch seconds {
    case ..<60: return "JUST NOW"
    case ..<3600: return "\(seconds / 60) MIN AGO"
    case ..<86_400: return "\(seconds / 3600) H AGO"
    default: return "\(seconds / 86_400) D AGO"
    }
}
