import SwiftUI

struct SetupView: View {
    let isInitialSetup: Bool

    /// The saved connection being edited; nil adds a new one.
    let editing: R2Credentials?
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var accountId = ""
    @State private var accessKeyId = ""
    @State private var secret = ""
    @State private var bucket = ""
    @State private var folders: [FolderField] = []
    @State private var jurisdiction: R2Credentials.Jurisdiction = .standard
    @State private var buckets: [String] = []
    @State private var testing = false
    @State private var status: String?
    @State private var ok = false

    // Fields start from the saved connection here, not in onAppear, so a redraw of Settings
    // during the push (e.g. indexing progress after a bucket switch) can't leave them blank.
    init(isInitialSetup: Bool = false, editing: R2Credentials? = nil) {
        self.isInitialSetup = isInitialSetup
        self.editing = editing
        guard let c = editing else { return }
        _accountId = State(initialValue: c.accountId)
        _accessKeyId = State(initialValue: c.accessKeyId)
        _secret = State(initialValue: c.secretAccessKey)
        _bucket = State(initialValue: c.bucket)
        _jurisdiction = State(initialValue: c.jurisdiction)
        _folders = State(initialValue: c.prefixes.filter { !$0.isEmpty }.map { FolderField(path: String($0.dropLast())) })
    }

    /// One editable folder row; the id keeps rows stable when one is deleted.
    private struct FolderField: Identifiable {
        let id = UUID()
        var path = ""
    }

    private var draft: R2Credentials {

        // Bucket names can't hold "/", so "bucket/some/folder" splits into bucket + folder.
        let path = bucket.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", maxSplits: 1)
        let typedFolder = path.count > 1 ? String(path[1]) : ""
        let listed = folders.map(\.path).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return R2Credentials(accountId: accountId.trimmingCharacters(in: .whitespacesAndNewlines),
                             accessKeyId: accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
                             secretAccessKey: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                             bucket: path.first.map(String.init) ?? "",
                             jurisdiction: jurisdiction,
                             folder: ([typedFolder] + listed).filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    var body: some View {
        Form {
            if isInitialSetup {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "play.rectangle.on.rectangle.fill").font(.system(size: 44)).foregroundStyle(.red)
                        Text("Connect your R2 bucket").font(.title2.bold())
                        Text("Create a token in Cloudflare → R2 → Manage API tokens with **Object Read only** permission. The app only ever reads — it never changes your files.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            Section("Cloudflare account") {
                TextField("Account ID", text: $accountId)
                Picker("Jurisdiction", selection: $jurisdiction) {
                    ForEach(R2Credentials.Jurisdiction.allCases, id: \.self) { Text($0.label) }
                }
            }
            Section {
                TextField("Access Key ID", text: $accessKeyId)
                SecureField("Secret Access Key", text: $secret)
            } header: { Text("R2 API token (S3 credentials)") } footer: {
                Text("Stored only in this iPhone's Keychain.")
            }
            Section {
                TextField("Bucket name", text: $bucket)
                if !buckets.isEmpty {
                    Picker("Pick a bucket", selection: $bucket) {
                        ForEach(buckets, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: { Text("Bucket") } footer: {
                Text("Leave the bucket empty and tap Test to list buckets (needs an account-wide token).")
            }
            Section {
                ForEach($folders) { $f in
                    TextField("Folder, e.g. videos/movies", text: $f.path)
                }
                .onDelete { folders.remove(atOffsets: $0) }
                Button { folders.append(FolderField()) } label: { Label("Add folder", systemImage: "plus") }
            } header: { Text("Folders (optional)") } footer: {
                Text("Only these folders are indexed; everything else in the bucket is skipped when refreshing. With none, the whole bucket is indexed. Swipe left on a folder to remove it.")
            }
            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Test connection")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || accountId.isEmpty || accessKeyId.isEmpty || secret.isEmpty)
                if let status {
                    Label(status, systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(ok ? Color.green : Color.red).font(.footnote)
                }
            }
            Section {
                Button("Save & open library") {
                    library.save(credentials: draft, replacing: editing?.bucket)
                    if !isInitialSetup { dismiss() }
                }
                .bold()
                .disabled(draft.bucket.isEmpty || accountId.isEmpty || accessKeyId.isEmpty || secret.isEmpty)
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle(isInitialSetup ? "Welcome" : editing == nil ? "Add bucket" : "Edit connection")
        .onAppear {

            // A new bucket usually lives in the same account; its token may differ.
            if editing == nil, accountId.isEmpty, let c = library.credentials {
                accountId = c.accountId; jurisdiction = c.jurisdiction
            }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let client = R2Client(credentials: draft)
        do {
            if draft.bucket.isEmpty {
                buckets = try await client.listBuckets()
                ok = true
                status = buckets.isEmpty ? "Connected, but no buckets visible." : "Found \(buckets.count) bucket(s). Pick one."
                if let first = buckets.first { bucket = first }
            } else {
                var empty: [String] = []
                for p in draft.prefixes {
                    let page = try await client.listObjects(bucket: draft.bucket, prefix: p, maxKeys: 1)
                    if page.objects.isEmpty { empty.append(p.isEmpty ? "bucket" : p) }
                }
                ok = true
                status = "Connected to \(draft.bucket)" + (empty.isEmpty ? "" : ". Empty: " + empty.joined(separator: ", "))
            }
        } catch {
            ok = false
            status = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @AppStorage("thumbnailsEnabled") private var thumbnailsEnabled = true
    @AppStorage("presignHours") private var presignHours = 6.0
    @State private var confirmSignOut = false
    @State private var cleared = false
    @State private var editing: R2Credentials?
    @State private var pendingRemove: String?

    var body: some View {
        @Bindable var player = player
        Form {
            Section {
                ForEach(library.connections, id: \.bucket) { c in
                    Button { library.select(bucket: c.bucket) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.bucket).foregroundStyle(.primary)
                                Text("Account \(c.accountId.prefix(8))…" + (c.prefixes == [""] ? "" : " · \(c.prefixes.count) folder\(c.prefixes.count == 1 ? "" : "s")"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.bucket == library.activeBucket { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { pendingRemove = c.bucket }
                        Button("Edit") { editing = c }.tint(.blue)
                    }
                }
                NavigationLink { SetupView() } label: { Label("Add bucket", systemImage: "plus") }
            } header: { Text("Buckets") } footer: {
                Text("Tap a bucket to open it. Swipe left to edit its token or remove it.")
            }
            Section {
                LabeledContent("Videos indexed", value: "\(library.allVideos.count)")
                if let built = library.activeIndex?.builtAt {
                    LabeledContent("Last indexed", value: Format.relative(built))
                }
                Button {
                    library.refresh()
                } label: {
                    HStack {
                        Text("Re-index bucket now")
                        Spacer()
                        if library.isIndexing { ProgressView(); Text("\(library.indexProgress)").font(.caption) }
                    }
                }
                .disabled(library.isIndexing)
                if let err = library.lastError { Text(err).font(.caption).foregroundStyle(.red) }
            } header: { Text("Library") } footer: {
                Text("The key list is cached on-device and refreshed automatically every 15 minutes when the app opens, or by pulling down in Library.")
            }
            Section("Playback") {
                Toggle("Autoplay next video", isOn: $player.autoplay)
                Toggle("Shuffle", isOn: $player.shuffle)
                Toggle("Loop queue at the end", isOn: $player.loopQueue)
                Picker("Skip by", selection: $player.skipUnit) {
                    Text("Seconds").tag(PlayerController.SkipUnit.seconds)
                    Text("Keyframes").tag(PlayerController.SkipUnit.keyframes)
                }
                skipSlider("Rewind", value: $player.rewindAmount)
                skipSlider("Fast forward", value: $player.forwardAmount)
                Stepper("Stream link lifetime: \(Int(presignHours)) h", value: $presignHours, in: 1...72, step: 1)
            }
            Section {
                Toggle("Generate thumbnails", isOn: $thumbnailsEnabled)
                Button("Clear thumbnail cache") {
                    Task { await ThumbnailService.shared.clearCache(); cleared = true }
                }
                Button("Clear watch progress") { ResumeStore.clearAll() }
            } header: { Text("Thumbnails & storage") } footer: {
                Text(cleared ? "Thumbnail cache cleared." :
                        "Thumbnails are grabbed from a frame ~10% into each video. To skip that, upload a JPG with the same name next to the video (clip.mp4 → clip.jpg).")
            }
            Section {
                Button("Remove all buckets & keys", role: .destructive) { confirmSignOut = true }
            }
        }
        .navigationTitle("Settings")
        .navigationDestination(item: $editing) { SetupView(editing: $0) }
        .confirmationDialog("Remove all saved R2 keys from this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { player.stop(); library.signOut() }
        }
        .confirmationDialog("Remove \(pendingRemove ?? "") and its keys from this iPhone?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let b = pendingRemove else { return }
                if player.current?.bucket == b || library.connections.count == 1 { player.stop() }
                library.remove(bucket: b)
            }
        }
    }

    private func skipSlider(_ title: String, value: Binding<Double>) -> some View {
        let n = Int(value.wrappedValue)
        let unit = player.skipUnit == .seconds ? "s" : n == 1 ? " keyframe" : " keyframes"
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: "\(n)\(unit)")
            Slider(value: value, in: 1...30, step: 1)
        }
    }
}
