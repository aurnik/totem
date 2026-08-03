import SwiftUI
import TotemKit

/// Records a soundboard sample (up to 10s, saved on-device with a label) for
/// the mic button's long-press menu.
struct RecordSoundSheet: View {
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

    private func cancel() {
        model.discardRecordedSample()
        dismiss()
    }

    private var recorder: some View {
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

    var body: some View {
        #if os(iOS)
        NavigationStack {
            List {
                Section {
                    TextField("Label", text: $label)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
                Section { recorder }
            }
            .navigationTitle("New Sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(model.isRecordingSample)
        .onDisappear { model.stopSampleRecording() }
        #else
        VStack(alignment: .leading, spacing: 16) {
            Text("New Sound")
                .font(.headline)
            TextField("Label", text: $label)
                .textFieldStyle(.roundedBorder)
            recorder
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding()
        .frame(minWidth: 320)
        .onDisappear { model.stopSampleRecording() }
        #endif
    }
}
