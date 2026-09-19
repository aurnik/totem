import SwiftUI
import TotemKit

/// Soundboard sheet: tap a sample to play it into the chat, swipe to delete.
/// The recorder pushes within this sheet's own NavigationStack rather than
/// replacing the presentation, which leaves presentation state stuck.
struct SoundboardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID

    var body: some View {
        NavigationStack {
            List {
                SoundSampleRows { sample in
                    model.playSample(sample, in: conversationID)
                    dismiss()
                }
            }
            .navigationTitle("Soundboard")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #else
        .frame(minWidth: 320, minHeight: 320)
        #endif
    }
}

/// Every sample with swipe-to-delete, plus "New sound" while under the cap.
/// With `onTap` the rows play; without it they are inert labels, as Settings
/// wants them.
struct SoundSampleRows: View {
    @Environment(AppModel.self) private var model
    var onTap: ((AppModel.SoundSample) -> Void)?

    var body: some View {
        ForEach(model.soundSamples) { sample in
            row(sample)
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
    }

    @ViewBuilder
    private func row(_ sample: AppModel.SoundSample) -> some View {
        if let onTap {
            Button { onTap(sample) } label: {
                Label(sample.label, systemImage: "waveform")
            }
        } else {
            Label(sample.label, systemImage: "waveform")
        }
    }
}

/// Records a soundboard sample, saved on-device with a label. Saving pops back
/// to the list; backing out abandons the take.
struct RecordSoundView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty
            && model.sampleRecordingSeconds > 0
    }

    private func save() {
        guard canSave else { return }
        model.saveRecordedSample(label: label)
        dismiss()
    }

    var body: some View {
        List {
            Section {
                TextField("Label", text: $label)
                    .submitLabel(.done)
                    .onSubmit(save)
            }
            Section {
                VStack(spacing: 12) {
                    Text(String(format: "%.1fs / %.0fs",
                                model.sampleRecordingSeconds, AppModel.sampleMaxSeconds))
                        .font(.title3.monospacedDigit())
                    ProgressView(value: model.sampleRecordingSeconds,
                                 total: AppModel.sampleMaxSeconds)
                    Button {
                        if model.isRecordingSample {
                            model.stopSampleRecording()
                        } else {
                            Task { await model.startSampleRecording() }
                        }
                    } label: {
                        Image(systemName: model.isRecordingSample ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 56))
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, isActive: model.isRecordingSample)
                    }
                    .buttonStyle(.plain)
                    Text(model.isRecordingSample
                         ? "Recording…"
                         : model.sampleRecordingSeconds > 0
                            ? "Tap to re-record"
                            : "Tap to record")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("New Sound")
        .inlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
            }
        }
        .onDisappear { model.stopSampleRecording() }
    }
}
