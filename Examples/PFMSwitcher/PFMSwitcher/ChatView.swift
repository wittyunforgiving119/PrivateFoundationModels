import CoreGraphics
import PhotosUI
import PrivateFoundationModels
import PrivateFoundationModelsCoreML
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @ObservedObject var manager: ModelManager

    @State private var input: String = ""
    @State private var streamingText: String = ""
    @State private var entries: [Transcript.Entry] = []
    @State private var inFlight = false

    /// Attached image for the next message. Cleared after send. Only the
    /// active backend's vision-capable branch (Gemma 4 E2B multimodal)
    /// actually consumes the image — text-only backends silently drop it.
    @State private var attachedImage: CGImage?
    @State private var attachedPickerItem: PhotosPickerItem?
    @State private var attachedPreviewData: Data?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(entries.indices, id: \.self) { i in
                                bubble(for: entries[i])
                            }
                            if !streamingText.isEmpty {
                                bubble(for: .init(kind: .response, content: streamingText))
                                    .id("streaming")
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: streamingText) { _, _ in
                        withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                    }
                }
                Divider()
                inputBar
            }
            .navigationTitle("PFM Switcher")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Header (picker + memory readout + status)

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 8) {
            Picker("Model", selection: Binding(
                get: { manager.selection },
                set: { newValue in
                    entries = []
                    streamingText = ""
                    Task { await manager.switchTo(newValue) }
                }
            )) {
                Text("None").tag(ModelManager.Selection.none)
                Section("Apple") {
                    Text("FoundationModels (iOS 26+)").tag(ModelManager.Selection.appleFM)
                }
                Section("CoreML / on-device") {
                    ForEach(manager.coreMLOptions, id: \.self) { catalog in
                        Text(coreMLLabel(catalog)).tag(ModelManager.Selection.coreML(catalog))
                    }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            statusRow
            memoryRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch manager.status {
        case .idle:
            Label("Idle — pick a model to load.", systemImage: "circle")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .loading(let stage):
            HStack(spacing: 6) {
                ProgressView()
                Text(stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .ready:
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Ready — \(manager.selection.description)").font(.caption)
                if let dt = manager.lastSwitchDuration {
                    Text("(\(String(format: "%.1f", dt)) s switch)").font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var memoryRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "memorychip")
                .font(.caption2)
            Text("Resident: \(formatMB(manager.residentBytes))")
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatMB(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        return String(format: "%.0f MB", mb)
    }

    // MARK: - Bubbles + input

    @ViewBuilder
    private func bubble(for entry: Transcript.Entry) -> some View {
        switch entry.kind {
        case .prompt:
            HStack {
                Spacer(minLength: 60)
                Text(entry.content)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 12))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .response:
            Text(entry.content)
                .padding(10)
                .background(Color.gray.opacity(0.12), in: .rect(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if let preview = attachedPreviewData {
                attachmentPreview(data: preview)
            }
            HStack(spacing: 8) {
                PhotosPicker(selection: $attachedPickerItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title3)
                }
                .disabled(manager.session == nil || inFlight)
                .onChange(of: attachedPickerItem) { _, newItem in
                    Task { await loadPickedImage(from: newItem) }
                }

                TextField("Message", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(manager.session == nil || inFlight)

                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(manager.session == nil || inFlight ||
                           input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func attachmentPreview(data: Data) -> some View {
        #if canImport(UIKit)
        if let image = UIImage(data: data) {
            HStack(spacing: 6) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(.rect(cornerRadius: 6))
                Text("Image attached").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    attachedImage = nil
                    attachedPickerItem = nil
                    attachedPreviewData = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
        }
        #else
        EmptyView()
        #endif
    }

    private func loadPickedImage(from item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            return
        }
        attachedPreviewData = data
        #if canImport(UIKit)
        if let uiImage = UIImage(data: data), let cgImage = uiImage.cgImage {
            attachedImage = cgImage
        }
        #endif
    }

    private func send() async {
        guard let session = manager.session else { return }
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let imageForCall = attachedImage
        input = ""
        attachedImage = nil
        attachedPickerItem = nil
        attachedPreviewData = nil
        inFlight = true
        defer { inFlight = false }

        let promptDisplay = imageForCall == nil ? prompt : prompt + " 📎"
        entries.append(.init(kind: .prompt, content: promptDisplay))
        streamingText = ""

        let stream: ResponseStream<String>
        if let imageForCall {
            stream = session.streamResponse(
                to: prompt,
                image: imageForCall,
                options: GenerationOptions(temperature: 0.7, maximumResponseTokens: 256)
            )
        } else {
            stream = session.streamResponse(
                to: prompt,
                options: GenerationOptions(temperature: 0.7, maximumResponseTokens: 256)
            )
        }

        do {
            for try await snapshot in stream {
                streamingText = snapshot.content
            }
            let final = try await stream.collect()
            entries.append(.init(kind: .response, content: final.content))
        } catch {
            entries.append(.init(kind: .response, content: "Error: \(error)"))
        }
        streamingText = ""
    }
}

#Preview {
    ChatView(manager: ModelManager())
}
