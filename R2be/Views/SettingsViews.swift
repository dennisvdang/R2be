import SwiftUI

struct SetupView: View {
    var isInitialSetup = false
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var accountId = ""
    @State private var accessKeyId = ""
    @State private var secret = ""
    @State private var bucket = ""
    @State private var jurisdiction: R2Credentials.Jurisdiction = .standard
    @State private var buckets: [String] = []
    @State private var testing = false
    @State private var status: String?
    @State private var ok = false

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
                Text("Leave empty and tap Test to list buckets (needs an account-wide token).")
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
                    library.save(credentials: draft)
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
            if let c = library.credentials {
                accountId = c.accountId; accessKeyId = c.accessKeyId; secret = c.secretAccessKey
                bucket = c.bucket; jurisdiction = c.jurisdiction
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

struct SettingsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @AppStorage("thumbnailsEnabled") private var thumbnailsEnabled = true
    @AppStorage("presignHours") private var presignHours = 6.0
    @State private var confirmSignOut = false
    @State private var cleared = false

    var body: some View {
        @Bindable var player = player
        Form {
            Section("Connection") {
                LabeledContent("Bucket", value: library.activeBucket)
                LabeledContent("Account", value: String((library.credentials?.accountId ?? "").prefix(8)) + "…")
                NavigationLink("Edit connection / switch bucket") { SetupView() }
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
                Button("Disconnect & remove keys", role: .destructive) { confirmSignOut = true }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Remove the saved R2 keys from this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { player.stop(); library.signOut() }
        }
    }
}
