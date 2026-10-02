import SwiftUI

struct SetupView: View {
    var isInitialSetup = false
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var accountId = ""
    @State private var accessKeyId = ""
    @State private var secret = ""
    @State private var bucket = ""
    @State private var folders: [String] = []
    @State private var jurisdiction: R2Credentials.Jurisdiction = .standard
    @State private var buckets: [String] = []
    @State private var testing = false
    @State private var status: String?
    @State private var ok = false
    @State private var loaded = false

    private var draft: R2Credentials {
        R2Credentials(accountId: accountId.trimmingCharacters(in: .whitespacesAndNewlines),
                      accessKeyId: accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
                      secretAccessKey: secret.trimmingCharacters(in: .whitespacesAndNewlines),
                      bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                      jurisdiction: jurisdiction)
    }

    var body: some View {
        Form {
            if isInitialSetup {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "play.rectangle.on.rectangle.fill").font(.system(size: 44)).foregroundStyle(.red)
                        Text("Connect your R2 bucket").font(.title2.bold())
                        Text("You'll need four values from your Cloudflare dashboard. The app only ever reads — it never changes your files.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
            Section {
                Link(destination: R2Links.overview) {
                    Label("1. Account ID & bucket name", systemImage: "arrow.up.forward.square")
                }
                Link(destination: R2Links.apiTokens) {
                    Label("2. Create an API token (Access Key ID & Secret)", systemImage: "arrow.up.forward.square")
                }
                NavigationLink {
                    R2SetupHelpView()
                } label: {
                    Label("How do I create the API token?", systemImage: "questionmark.circle")
                }
            } header: { Text("Where to find these") } footer: {
                Text("Links open the Cloudflare dashboard in Safari. Copy each value, then switch back here to paste it.")
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
                Text("Exactly as shown in Cloudflare → R2 → Overview.")
            }
            Section {
                NavigationLink {
                    FolderSelectionView(client: R2Client(credentials: draft), bucket: draft.bucket, selection: $folders)
                } label: {
                    LabeledContent("Folders to index", value: FolderSelectionView.summary(folders))
                }
                .disabled(draft.bucket.isEmpty || accountId.isEmpty || accessKeyId.isEmpty || secret.isEmpty)
            } footer: {
                Text("If your media is only in some folders, pick just those. Indexing then skips the rest of the bucket and is much faster.")
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
                    library.save(credentials: draft, folders: folders)
                    if !isInitialSetup { dismiss() }
                }
                .bold()
                .disabled(draft.bucket.isEmpty || accountId.isEmpty || accessKeyId.isEmpty || secret.isEmpty)
            }
        }
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle(isInitialSetup ? "Welcome" : "R2 Connection")
        .onAppear {
            // Runs again when popping back from a pushed screen; don't overwrite unsaved edits.
            guard !loaded else { return }
            loaded = true
            if let c = library.credentials {
                accountId = c.accountId; accessKeyId = c.accessKeyId; secret = c.secretAccessKey
                bucket = c.bucket; jurisdiction = c.jurisdiction
            }
            folders = LibraryStore.indexFolders(for: draft.bucket)
        }
        .onChange(of: bucket) { folders = LibraryStore.indexFolders(for: draft.bucket) }
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
                let page = try await client.listObjects(bucket: draft.bucket, maxKeys: 5)
                ok = true
                status = "Connected to \(draft.bucket)" + (page.objects.isEmpty && page.commonPrefixes.isEmpty ? " (empty)" : "")
            }
        } catch {
            ok = false
            status = error.localizedDescription
        }
    }
}

/// Pick which folders of a bucket get indexed. Tap a row to select it (which covers everything
/// inside it); tap the chevron to open it and pick subfolders instead.
struct FolderSelectionView: View {
    let client: R2Client
    let bucket: String
    var prefix: String = ""
    @Binding var selection: [String]

    @State private var folders: [String]?
    @State private var error: String?
    @State private var openFolder: String?

    static func summary(_ folders: [String]) -> String {
        switch folders.count {
        case 0: return "Whole bucket"
        case 1: return String(folders[0].dropLast())
        default: return "\(folders.count) folders"
        }
    }

    var body: some View {
        List {
            if prefix.isEmpty {
                Section {
                    Button { selection = [] } label: { checkRow("Whole bucket", checked: selection.isEmpty) }
                } footer: {
                    Text("Or pick one or more folders below.")
                }
            }
            Section {
                if let folders {
                    if folders.isEmpty {
                        Text("No subfolders").foregroundStyle(.secondary)
                    }
                    ForEach(folders, id: \.self) { folderRow($0) }
                } else if let error {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.footnote)
                } else {
                    HStack { ProgressView(); Text("Loading folders…").foregroundStyle(.secondary) }
                }
            } header: {
                Text(prefix.isEmpty ? bucket : prefix)
            }
        }
        .navigationTitle(prefix.isEmpty ? "Folders to index" : name(of: prefix))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $openFolder) { sub in
            FolderSelectionView(client: client, bucket: bucket, prefix: sub, selection: $selection)
        }
        .task { await load() }
    }

    private func folderRow(_ folder: String) -> some View {
        let coveredByParent = selection.contains { $0 != folder && folder.hasPrefix($0) }
        return HStack {
            Button { toggle(folder) } label: {
                checkRow(name(of: folder), checked: coveredByParent || selection.contains(folder))
            }
            .buttonStyle(.borderless)
            .disabled(coveredByParent)
            Button { openFolder = folder } label: {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.leading, 12)
            }
            .buttonStyle(.borderless)
        }
    }

    private func checkRow(_ title: String, checked: Bool) -> some View {
        HStack {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
            Text(title).foregroundStyle(Color.primary)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func toggle(_ folder: String) {
        if let i = selection.firstIndex(of: folder) {
            selection.remove(at: i)
        } else {
            selection.removeAll { $0.hasPrefix(folder) }   // a parent covers its subfolders
            selection.append(folder)
            selection.sort()
        }
    }

    private func name(of folder: String) -> String {
        String(folder.dropLast().split(separator: "/").last ?? "")
    }

    private func load() async {
        guard folders == nil else { return }
        do {
            folders = try await client.listFolders(bucket: bucket, prefix: prefix)
                .filter { !name(of: $0).hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum R2Links {
    static let overview = URL(string: "https://dash.cloudflare.com/?to=/:account/r2/overview")!
    static let apiTokens = URL(string: "https://dash.cloudflare.com/?to=/:account/r2/api-tokens")!
}

/// Step-by-step help for finding the values SetupView asks for.
struct R2SetupHelpView: View {
    var body: some View {
        List {
            Section {
                Link(destination: R2Links.overview) {
                    Label("Open R2 Overview", systemImage: "arrow.up.forward.square")
                }
                step(1, "Sign in to Cloudflare and pick your account if asked.")
                step(2, "**Account ID** is under **Account Details** (you may need to scroll). Tap the copy icon.")
                step(3, "**Bucket name** is in the list of buckets. Copy it exactly as shown.")
            } header: { Text("Step 1 · Account ID & bucket name") }

            Section {
                Link(destination: R2Links.apiTokens) {
                    Label("Open R2 API Tokens", systemImage: "arrow.up.forward.square")
                }
                step(1, "Tap **Create API token** (or **Create Account API token**).")
                step(2, "Give it a name, e.g. **R2be**.")
                step(3, "Under **Permissions**, choose **Object Read only**.")
                step(4, "Under **Specify bucket(s)**, pick your video bucket.")
                step(5, "Leave the other options as they are and tap **Create API Token**.")
                step(6, "Copy **Access Key ID** and **Secret Access Key** into this app. The secret is shown only once — if you lose it, create a new token.")
            } header: { Text("Step 2 · API token") } footer: {
                Text("Ignore the Token value and the S3 endpoint shown on that page. The app builds the endpoint from your Account ID.")
            }

            Section {
                Text("Leave **Jurisdiction** on **Default** unless you created the bucket with the EU or FedRAMP jurisdiction.")
                Text("Then tap **Test connection**, and **Save & open library** once it says Connected.")
            } header: { Text("Step 3 · Finish in the app") }
        }
        .navigationTitle("Cloudflare R2 setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }
}

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @AppStorage("thumbnailsEnabled") private var thumbnailsEnabled = true
    @AppStorage("presignHours") private var presignHours = 6.0
    @AppStorage("disableShare") private var disableShare = true
    @AppStorage("rewindCache") private var rewindCache = true
    @State private var downloads = DownloadStore.shared
    @State private var confirmRemoveDownloads = false
    @State private var confirmSignOut = false
    @State private var cleared = false

    var body: some View {
        @Bindable var player = player
        Form {
            Section("Connection") {
                LabeledContent("Bucket", value: library.activeBucket)
                LabeledContent("Account", value: String((library.credentials?.accountId ?? "").prefix(8)) + "…")
                LabeledContent("Folders indexed", value: FolderSelectionView.summary(LibraryStore.indexFolders(for: library.activeBucket)))
                NavigationLink("Edit connection / folders / bucket") { SetupView() }
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
                        if library.isIndexing { ProgressView(); Text("\(library.indexMatches.formatted()) found").font(.caption) }
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
                Stepper("Stream link lifetime: \(Int(presignHours)) h", value: $presignHours, in: 1...72, step: 1)
                Toggle("Instant rewind", isOn: $rewindCache)
            }
            Section {
                Toggle("Disable share button", isOn: $disableShare)
            } footer: {
                Text("Hides every Share button and \"Share 24h Link\" in the app. On by default.")
            }
            Section {
                LabeledContent("Downloaded", value: "\(downloads.entries.count) videos · \(Format.bytes(downloads.totalBytes))")
                Button("Remove all downloads", role: .destructive) { confirmRemoveDownloads = true }
                    .disabled(downloads.entries.isEmpty)
            } header: { Text("Downloads") } footer: {
                Text("Downloaded videos play without a connection, from the Downloads tab or anywhere in the app.")
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
                Button("Disconnect & remove keys", role: .destructive) { confirmSignOut = true }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Remove all downloads from this iPhone?", isPresented: $confirmRemoveDownloads, titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { downloads.removeAll() }
        }
        .confirmationDialog("Remove the saved R2 keys from this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { player.stop(); library.signOut() }
        }
    }
}
