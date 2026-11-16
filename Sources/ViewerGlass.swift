import AppKit
import SwiftUI


struct BezierBox: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = max(0, min(14 - insetAmount, min(box.width, box.height) / 2))
        let handle = radius * 0.55228475
        let left = box.minX, top = box.minY, right = box.maxX, bottom = box.maxY
        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addLine(to: CGPoint(x: right - radius, y: top))
        path.addCurve(to: CGPoint(x: right, y: top + radius),
                      control1: CGPoint(x: right - radius + handle, y: top),
                      control2: CGPoint(x: right, y: top + radius - handle))
        path.addLine(to: CGPoint(x: right, y: bottom - radius))
        path.addCurve(to: CGPoint(x: right - radius, y: bottom),
                      control1: CGPoint(x: right, y: bottom - radius + handle),
                      control2: CGPoint(x: right - radius + handle, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addCurve(to: CGPoint(x: left, y: bottom - radius),
                      control1: CGPoint(x: left + radius - handle, y: bottom),
                      control2: CGPoint(x: left, y: bottom - radius + handle))
        path.addLine(to: CGPoint(x: left, y: top + radius))
        path.addCurve(to: CGPoint(x: left + radius, y: top),
                      control1: CGPoint(x: left, y: top + radius - handle),
                      control2: CGPoint(x: left + radius - handle, y: top))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> BezierBox {
        BezierBox(insetAmount: insetAmount + amount)
    }
}

struct ViewerGlass: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(white: 0.105)
            } else {
                Backdrop()
                Color.black.opacity(0.16)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Backdrop: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }
}

struct ViewerEdgeLight: View {
    var body: some View {
        BezierBox()
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.44), .white.opacity(0.08), .white.opacity(0.23)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct ViewerControlScale: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var viewerControlScale: CGFloat {
        get { self[ViewerControlScale.self] }
        set { self[ViewerControlScale.self] = newValue }
    }
}

struct GlassControlStyle: ButtonStyle {
    @Environment(\.viewerControlScale) private var controlScale
    var row = false
    var solid = false
    var wallpaper: CGImage?

    func makeBody(configuration: Configuration) -> some View {
        GlassControlSurface(pressed: configuration.isPressed, row: row, solid: solid, wallpaper: wallpaper) {
            configuration.label.font(ViewerTypography.font(row ? .regular : .medium, size: row ? 13 * controlScale : 11))
        }
    }
}

struct GlassControlSurface<Content: View>: View {
    var pressed = false
    var row = false
    var solid = false
    var wallpaper: CGImage?
    @ViewBuilder var content: Content

    @Environment(\.viewerControlScale) private var controlScale
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovering = false

    var body: some View {
        let shape = BezierBox()
        content
            .padding(.horizontal, row ? 12 * controlScale : 9)
            .frame(minHeight: row ? 37 * controlScale : 23)
            .background {
                ZStack {
                    if let wallpaper {
                        WallpaperSlice(image: wallpaper)
                            .overlay(.black.opacity(hovering ? 0.27 : 0.40))
                            .clipShape(shape)
                            .allowsHitTesting(false)
                    } else if solid {
                        shape.fill(Color(white: hovering ? 0.17 : 0.12))
                    } else if reduceTransparency {
                        shape.fill(Color(white: 0.22))
                    } else {
                        shape.fill(.ultraThinMaterial).opacity(0.26)
                    }
                    shape.fill(LinearGradient(
                        colors: [.white.opacity(hovering ? 0.17 : 0.07), .white.opacity(0.015), .black.opacity(0.06)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    shape.strokeBorder(LinearGradient(
                        colors: [.white.opacity(solid ? 0.23 : (hovering ? 0.68 : 0.42)), .white.opacity(0.12), .white.opacity(0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.75)
                }
            }
            .contentShape(shape)
            .shadow(color: row ? .clear : .black.opacity(0.18), radius: row ? 0 : 3, y: row ? 0 : 2)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(pressed && !reduceMotion ? 0.96 : 1)
            .onHover { hovering = $0 && enabled }

    }
}
