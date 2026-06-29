import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentView: View {
    @EnvironmentObject var vm: TorrentListViewModel
    @Environment(\.dismiss) var dismiss
    @State private var magnetURL = ""
    @State private var selectedTab = AddTab.magnet
    @State private var showDocumentPicker = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var previewMetadata: TorrentMetadata?

    enum AddTab: String, CaseIterable {
        case magnet = "Magnet"
        case file = "File"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Add method", selection: $selectedTab) {
                    ForEach(AddTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                switch selectedTab {
                case .magnet:
                    MagnetInputView(
                        magnetURL: $magnetURL,
                        isLoading: $isLoading,
                        errorMessage: $errorMessage,
                        onAdd: addMagnet
                    )

                case .file:
                    FilePickerView(
                        showPicker: $showDocumentPicker,
                        previewMetadata: $previewMetadata,
                        onAdd: addTorrentFile
                    )
                }

                Spacer()

                // Preview card
                if let meta = previewMetadata {
                    TorrentPreviewCard(metadata: meta)
                        .padding()
                }
            }
            .navigationTitle("Add Torrent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showDocumentPicker) {
                TorrentDocumentPicker { url in
                    Task { await loadTorrentFile(url: url) }
                }
            }
            .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                if let err = errorMessage { Text(err) }
            }
        }
    }

    private func addMagnet() {
        guard let url = URL(string: magnetURL), url.scheme == "magnet" else {
            errorMessage = "Invalid magnet link"
            return
        }
        do {
            let magnet = try MagnetLink(url: url)
            Task {
                _ = await vm.engine.addTorrent(magnet: magnet)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addTorrentFile() {
        guard let meta = previewMetadata else { return }
        Task {
            // Re-parse from saved data — in production, save the file
            dismiss()
        }
    }

    private func loadTorrentFile(url: URL) async {
        isLoading = true
        defer { isLoading = false }

        do {
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            let meta = try TorrentParser.parse(data: data)
            previewMetadata = meta
            selectedTab = .file
        } catch {
            errorMessage = "Failed to parse torrent: \(error.localizedDescription)"
        }
    }
}

// MARK: - Magnet Input

struct MagnetInputView: View {
    @Binding var magnetURL: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse)

            Text("Paste a magnet link")
                .font(.headline)

            TextEditor(text: $magnetURL)
                .font(.caption.monospaced())
                .frame(height: 80)
                .padding(8)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .overlay(alignment: .topLeading) {
                    if magnetURL.isEmpty {
                        Text("magnet:?xt=urn:btih:...")
                            .foregroundStyle(.tertiary)
                            .font(.caption.monospaced())
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal)

            // Paste from clipboard
            if let clipboard = UIPasteboard.general.string, clipboard.hasPrefix("magnet:") {
                Button {
                    magnetURL = clipboard
                } label: {
                    Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                }
                .tint(.secondary)
            }

            Button {
                onAdd()
            } label: {
                Label("Add Magnet", systemImage: "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(magnetURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            .padding(.horizontal)

            if isLoading {
                ProgressView("Fetching metadata...")
                    .font(.caption)
            }
        }
        .padding()
    }
}

// MARK: - File Picker

struct FilePickerView: View {
    @Binding var showPicker: Bool
    @Binding var previewMetadata: TorrentMetadata?
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            if previewMetadata == nil {
                Image(systemName: "doc.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)

                Text("Select a .torrent file")
                    .font(.headline)

                Button {
                    showPicker = true
                } label: {
                    Label("Browse Files", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            } else {
                Button {
                    onAdd()
                } label: {
                    Label("Add Torrent", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                Button { previewMetadata = nil } label: {
                    Text("Choose Different File")
                        .font(.subheadline)
                }
                .tint(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Torrent Preview Card

struct TorrentPreviewCard: View {
    let metadata: TorrentMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(metadata.name, systemImage: "arrow.down.doc.fill")
                .font(.subheadline.bold())
                .lineLimit(2)

            HStack {
                Text(metadata.totalLength.byteCountString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.secondary)
                Text("\(metadata.files.count) file\(metadata.files.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.secondary)
                Text("\(metadata.pieceCount) pieces")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let comment = metadata.comment {
                Text(comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Document Picker

struct TorrentDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types = [UTType(filenameExtension: "torrent") ?? .item]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
