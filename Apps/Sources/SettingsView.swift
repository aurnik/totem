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
                    #if os(iOS)
                    Text("On or off, the badge on the app icon counts the friends who are online.")
                    #endif
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
            .inlineTitle()
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
            HStack {
                Spacer()
                DoodleEditor(size: 280)
                Spacer()
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Skin tone")
                GradientSlider(value: $model.avatarSetting.skinTone, stops: AvatarPalette.skin) {
                    model.commitAvatar()
                }
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Hair")
                GradientSlider(value: $model.avatarSetting.hair, stops: AvatarPalette.hair) {
                    model.commitAvatar()
                }
            }
            .padding(.vertical, 4)
            Toggle("Glasses", isOn: Binding(
                get: { model.avatarSetting.glasses },
                set: {
                    model.avatarSetting.glasses = $0
                    model.commitAvatar()
                }
            ))
            Toggle("Cigarette", isOn: Binding(
                get: { model.avatarSetting.cigarette },
                set: {
                    model.avatarSetting.cigarette = $0
                    model.commitAvatar()
                }
            ))
        } header: {
            Text("Avatar")
        } footer: {
            Text("Draw on your avatar with a finger. Friends see your latest look in every chat.")
        }
    }

    private var soundboardSection: some View {
        Section {
            SoundSampleRows()
        } header: {
            Text("Soundboard")
        } footer: {
            Text("Up to \(AppModel.maxSoundSamples) sounds, kept on this device. Play them from the soundboard button in any chat; swipe to delete.")
        }
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
