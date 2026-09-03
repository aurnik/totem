import SwiftUI

/// The first sign-on binds the voice endpoint, and the endpoint probing the
/// LAN is what makes the system ask about the local network. Asked cold,
/// that question reads as suspicious for a chat app, so it's preceded once by
/// a screen that says what it's for, and the prompt is raised deliberately
/// on Continue rather than whenever the endpoint's first probe happens to go
/// out.
enum LocalNetworkExplainer {
    private static let shownKey = "explainedLocalNetwork"

    /// macOS only started asking in Sequoia; a screen about a question that
    /// never comes is just noise.
    static var isNeeded: Bool {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return false }
        #if os(macOS)
        if #available(macOS 15, *) { return true }
        return false
        #else
        return true
        #endif
    }

    static func markShown() {
        UserDefaults.standard.set(true, forKey: shownKey)
    }

    /// Apple's documented way to raise the alert (TN3179): connecting a UDP
    /// socket to a link-local address counts as local network access without
    /// sending anything. Best effort — if it doesn't fire, the endpoint's own
    /// probes will a moment later.
    static func triggerPrompt() {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET6),
                  ifa.ifa_flags & UInt32(IFF_BROADCAST) != 0
            else { continue }
            var sin6 = UnsafeRawPointer(addr).loadUnaligned(as: sockaddr_in6.self)
            let bytes = sin6.sin6_addr.__u6_addr.__u6_addr8
            guard bytes.0 == 0xfe, bytes.1 & 0xc0 == 0x80 else { continue }
            sin6.sin6_port = in_port_t(9).bigEndian
            let sock = socket(AF_INET6, SOCK_DGRAM, 0)
            guard sock >= 0 else { continue }
            withUnsafePointer(to: &sin6) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            close(sock)
        }
    }
}

struct LocalNetworkExplainerView: View {
    let onContinue: () -> Void

    private var system: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ConnectionVisualization()
                .frame(height: 220)
                .padding(.horizontal, 32)
            Spacer().frame(height: 40)
            VStack(spacing: 14) {
                Text("Chats go straight to your friends")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Totem sends your chat data directly between your devices, not through a server.\n\nConnecting devices directly can include ones on your own Wi-Fi, so \(system) will ask before Totem reaches them.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 36)
            Spacer()
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.explainerBackground)
        #if os(macOS)
        .frame(width: 440, height: 560)
        #endif
    }
}

/// Two people, breathing slowly, with a signal drifting between them. Soft
/// shapes and slow easing on purpose: this is the moment before a permission
/// prompt, so the picture should feel calm, not technical.
private struct ConnectionVisualization: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = reduceMotion ? 0.7 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                draw(in: &canvas, size: size, time: t)
            }
        }
        .accessibilityLabel("Two people connected directly to each other")
    }

    private func draw(in canvas: inout GraphicsContext, size: CGSize, time t: TimeInterval) {
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = min(size.width * 0.34, 130)
        let left = CGPoint(x: mid.x - reach, y: mid.y)
        let right = CGPoint(x: mid.x + reach, y: mid.y)
        let breath = 0.5 + 0.5 * sin(t * 0.9)

        // A halo behind everything, swelling with the breath.
        let haloRadius = size.height * (0.46 + 0.04 * breath)
        canvas.fill(
            Path(ellipseIn: CGRect(x: mid.x - haloRadius, y: mid.y - haloRadius,
                                   width: haloRadius * 2, height: haloRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [Color.explainerHalo, Color.explainerHalo.opacity(0)]),
                center: mid, startRadius: 0, endRadius: haloRadius))

        // The path between them: a faint arc, with soft dots drifting along
        // it from one person to the other and back, spaced evenly so the
        // motion reads as a steady flow rather than a clump.
        let control = CGPoint(x: mid.x, y: mid.y - 44)
        var arc = Path()
        arc.move(to: left)
        arc.addQuadCurve(to: right, control: control)
        canvas.stroke(arc, with: .color(Color.explainerSignal.opacity(0.22)),
                      style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 9]))
        for i in 0..<4 {
            let phase = (t * 0.22 + Double(i) * 0.25).truncatingRemainder(dividingBy: 1)
            let s = 0.5 - 0.5 * cos(phase * 2 * .pi)
            let u = 1 - s
            let point = CGPoint(
                x: u * u * left.x + 2 * u * s * control.x + s * s * right.x,
                y: u * u * left.y + 2 * u * s * control.y + s * s * right.y)
            let dotRadius = 5 + 2 * sin(s * .pi)
            let opacity = 0.3 + 0.6 * sin(s * .pi)
            canvas.fill(
                Path(ellipseIn: CGRect(x: point.x - dotRadius, y: point.y - dotRadius,
                                       width: dotRadius * 2, height: dotRadius * 2)),
                with: .color(Color.explainerSignal.opacity(opacity)))
        }

        for (point, color, offset) in [(left, Color.explainerYou, 0.0), (right, Color.explainerFriend, 1.3)] {
            let radius = 30 + 3 * sin(t * 0.9 + offset)
            let glow = radius * 1.7
            canvas.fill(
                Path(ellipseIn: CGRect(x: point.x - glow, y: point.y - glow, width: glow * 2, height: glow * 2)),
                with: .radialGradient(
                    Gradient(colors: [color.opacity(0.35), color.opacity(0)]),
                    center: point, startRadius: radius * 0.8, endRadius: glow))
            canvas.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(color))
        }
    }
}

private extension Color {
    static let explainerYou = Color(red: 0.99, green: 0.62, blue: 0.42)
    static let explainerFriend = Color(red: 0.42, green: 0.66, blue: 0.93)
    static let explainerSignal = Color(red: 0.96, green: 0.76, blue: 0.36)
    static var explainerHalo: Color { .explainerYou.opacity(0.09) }
    static var explainerBackground: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
