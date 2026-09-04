import SwiftUI
import TotemKit

/// Settings: notifications, appearance, avatar, and soundboard management.
/// The recorder pushes within this sheet's NavigationStack, same pattern as
/// the in-chat soundboard.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var isDrawing = false

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
                adornmentSection
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
                DoodleEditor(size: 280, isDrawing: $isDrawing)
                Spacer()
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hair")
                    Spacer()
                    let long = model.avatarSetting.longHair
                    Button {
                        model.avatarSetting.longHair.toggle()
                        model.commitAvatar()
                    } label: {
                        Text("Long")
                            .font(.subheadline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .foregroundStyle(long ? .white : Color.accentColor)
                            .background(long ? Color.accentColor : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                GradientSlider(value: $model.avatarSetting.hair, stops: AvatarPalette.hair) {
                    model.commitAvatar()
                }
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Skin")
                GradientSlider(value: $model.avatarSetting.skinTone, stops: AvatarPalette.skin) {
                    model.commitAvatar()
                }
            }
            .padding(.vertical, 4)
        } header: {
            HStack {
                Text("Avatar")
                Spacer()
                Button {
                    withAnimation(.snappy) { isDrawing.toggle() }
                } label: {
                    if isDrawing {
                        Text("Done")
                    } else {
                        Label("Draw", systemImage: "paintbrush.pointed")
                    }
                }
                .font(.subheadline)
                .textCase(nil)
            }
        } footer: {
            Text("Draw on your avatar with a finger. Friends see your latest look in every chat.")
        }
    }

    private var adornmentSection: some View {
        Section("Adornments") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Adornment.allCases) { adornment in
                    AdornmentCell(adornment: adornment, isOn: adornment.isOn(model.avatarSetting)) {
                        adornment.toggle(&model.avatarSetting)
                        model.commitAvatar()
                    }
                }
            }
            .padding(.vertical, 4)
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

/// One adornment drawn by itself, fitted into the cell, with its name below.
/// Lit like the Long hair button when it is worn.
struct AdornmentCell: View {
    let adornment: Adornment
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Canvas { context, canvasSize in
                    AvatarHeadView.draw(
                        adornment, in: &context,
                        g: AvatarGeometry(fitting: adornment.bounds, in: canvasSize))
                }
                .frame(width: 84, height: 30)
                Text(adornment.label)
                    .font(.body)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(isOn ? .white : Color.accentColor)
            .background(isOn ? Color.accentColor : Color.accentColor.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
