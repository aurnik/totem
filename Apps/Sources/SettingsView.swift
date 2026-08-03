import SwiftUI
import TotemKit

/// Settings: notifications, appearance, avatar, and soundboard management.
/// The recorder pushes within this sheet's NavigationStack, same pattern as
/// the in-chat soundboard.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pushBinding = Binding(
            get: { model.signOnPushes },
            set: { model.setSignOnPushes($0) }
        )
        let appearanceBinding = Binding(
            get: { model.appearance },
            set: { model.setAppearance($0) }
        )
        NavigationStack {
            List {
                Section {
                    Toggle("Notify me when friends sign on", isOn: pushBinding)
                } footer: {
                    Text("Delivered even while Totem is closed.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: appearanceBinding) {
                        ForEach(AppModel.Appearance.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                avatarSection
                soundboardSection
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
    }

    private var avatarSection: some View {
        @Bindable var model = model
        return Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Skin tone")
                GradientSlider(value: $model.avatar.skinTone, stops: AvatarPalette.skin) {
                    model.commitAvatar()
                }
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Hair")
                GradientSlider(value: $model.avatar.hair, stops: AvatarPalette.hair) {
                    model.commitAvatar()
                }
            }
            .padding(.vertical, 4)
            Toggle("Glasses", isOn: Binding(
                get: { model.avatar.glasses },
                set: {
                    model.avatar.glasses = $0
                    model.commitAvatar()
                }
            ))
        } header: {
            Text("Avatar")
        } footer: {
            Text("Friends see your latest avatar in every chat.")
        }
    }

    private var soundboardSection: some View {
        Section {
            ForEach(model.soundSamples) { sample in
                Label(sample.label, systemImage: "waveform")
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            model.deleteSample(sample)
                        }
                    }
            }
            if model.soundSamples.count < AppModel.maxSoundSamples {
                NavigationLink {
                    RecordSoundView()
                } label: {
                    Label("New sound", systemImage: "waveform.badge.plus")
                }
            }
        } header: {
            Text("Soundboard")
        } footer: {
            Text("Up to \(AppModel.maxSoundSamples) sounds, kept on this device. Play them from the soundboard button in any chat; swipe to delete.")
        }
    }
}

/// Palette stops for the avatar sliders, as RGB triples so the same values
/// drive the gradient track, the knob preview, and (later) avatar rendering.
enum AvatarPalette {
    /// Pale white → dark brown.
    static let skin: [(Double, Double, Double)] = [
        (0.98, 0.89, 0.80),
        (0.94, 0.80, 0.64),
        (0.83, 0.62, 0.42),
        (0.62, 0.42, 0.25),
        (0.42, 0.27, 0.16),
        (0.28, 0.18, 0.11),
    ]
    /// Blonde → ginger → brunette → almost black.
    static let hair: [(Double, Double, Double)] = [
        (0.92, 0.78, 0.44),
        (0.78, 0.42, 0.18),
        (0.42, 0.28, 0.15),
        (0.10, 0.08, 0.06),
    ]

    static func colors(_ stops: [(Double, Double, Double)]) -> [Color] {
        stops.map { Color(red: $0.0, green: $0.1, blue: $0.2) }
    }

    /// Piecewise-linear interpolation across the stops at `t` in 0…1.
    static func color(_ stops: [(Double, Double, Double)], at t: Double) -> Color {
        let clamped = min(max(t, 0), 1)
        let position = clamped * Double(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        let fraction = position - Double(index)
        let (a, b) = (stops[index], stops[index + 1])
        return Color(
            red: a.0 + (b.0 - a.0) * fraction,
            green: a.1 + (b.1 - a.1) * fraction,
            blue: a.2 + (b.2 - a.2) * fraction)
    }
}

/// A slider whose track is the palette gradient and whose knob previews the
/// selected color. `onCommit` fires on release so the owner can persist once
/// per gesture instead of per pixel.
struct GradientSlider: View {
    @Binding var value: Double
    let stops: [(Double, Double, Double)]
    var onCommit: () -> Void

    private let knobSize: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width - knobSize
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: AvatarPalette.colors(stops),
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 14)
                Circle()
                    .fill(AvatarPalette.color(stops, at: value))
                    .overlay(Circle().strokeBorder(.background, lineWidth: 3))
                    .shadow(radius: 1, y: 1)
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: travel * value)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        value = min(max((drag.location.x - knobSize / 2) / travel, 0), 1)
                    }
                    .onEnded { _ in onCommit() }
            )
        }
        .frame(height: 28)
    }
}
