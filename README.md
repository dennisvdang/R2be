# R2be

An iPhone app that turns a Cloudflare R2 bucket into a personal media server. You browse it like Google Drive and watch it like YouTube. Every video plays inside the app, never in Safari.

**Read-only by design:** the app only lists and streams your files. Playlists, watch progress and thumbnails are stored on the phone. Nothing in your bucket is created, moved, renamed or deleted.

## Features

| Area | What you get |
|---|---|
| **Library** | Folder browser built from your bucket's `/` prefixes. Four layouts: List, Small grid (3-up), Grid (2-up) and Feed cards (YouTube-style). Sort by name, date, size or random. Folder tiles show a cover frame and a video count. |
| **Search** | Searches file names in **This folder** or **Everywhere**. Ignores case and accents, and treats `_`, `-` and `.` as spaces. |
| **Player** | Built-in AVPlayer with custom controls: ±30 s buttons, **double-tap left/right for ±30 s**, previous/next, a scrubber, speed (0.5–2×) and AirPlay. **Expand** goes fullscreen landscape even while the phone is upright (then turn the phone); in fullscreen you can switch between fill and fit. Swipe down to minimise. Swipe left/right on the video to skip. Leave the player while a video plays and it keeps going in a floating window you can drag anywhere; leave the app and the system Picture in Picture window takes over. Top right: autoplay switch, shuffle, AirPlay and ⚙︎ (speed, loop, sleep timer, zoom, media source). **Sleep timer** (🌙): pause after 5 min–2 h or at the end of the current video. |
| **Autoplay / shuffle** | Autoplay next (on by default). Shuffle on any folder, playlist or search result picks a random video first, then keeps shuffling without repeats. The queue loops by default, so Up Next always lists the rest of the queue — even from the last video. You can reshuffle or turn looping off. Next to Up Next, **Related** lists the other parts of the current video: files with the same name ending in `-pt1`, `pt 2`, `part 3`, `ep 4`, `(5)` and so on. |
| **Up Next** | In portrait the video sits on top and the queue sits underneath. Tap a row to jump to it, swipe to remove it. Long-press any video to choose **Play Next** or **Add to Queue**. |
| **Downloads** | Long-press a video → **Download**, select several in the Library and tap ↓, or use the player's ⚙︎ → Media source. Downloads keep going in the background, play without a connection (Downloads tab, or anywhere a downloaded video appears), and are kept out of iCloud backup. |
| **Feed tab** | Full-screen vertical feed you swipe through (Shorts/Reels style) over All videos, Recently added, any top-level folder or any playlist. Shows the current video with −30/+30, Save, Share and Expand buttons. The feed advances on its own when a video ends. |
| **Playlists** | Stored on the phone, with a built-in **Favorites** playlist. Tap ☑︎ in the Library (also while searching) to pick several videos and add them to a playlist at once, or use **Add videos…** in a playlist to browse folders and tick individual videos. A video is never added to the same playlist twice. You can reorder, rename, duplicate, and combine several playlists into a new one. |
| **Mini player** | Keeps playing while you browse, YouTube-style. Lock screen and Control Center controls work too: play/pause, ±30 s and scrubbing. |
| **Thumbnails** | Grabbed from a frame about 10% into each video and only the bytes needed are streamed. They're cached on the phone. If you put `clip.jpg` (or `clip.mp4.jpg`, or `thumbs/clip.jpg`) next to `clip.mp4`, the app uses that image instead. Long-press a folder → **Set Cover Image…** to use a photo from your iPhone as that folder's cover (stored on the phone only). |
| **Resume** | Remembers where you stopped in each video. A red progress bar shows on the thumbnails. |

**Formats:** only video and audio files are indexed and shown: MP4, MOV, M4V and 3GP (H.264/HEVC), HLS `.m3u8`, and MP3, M4A, FLAC and WAV. Everything else in the bucket (documents, archives, …) is skipped. You can also limit indexing to the folders that hold your media (**Settings → Edit connection → Folders to index**). iOS can't play MKV, AVI or WebM natively, so those are hidden too. You can convert them with `ffmpeg -i in.mkv -c copy -movflags +faststart out.mp4`. The `+faststart` flag also makes seeking and thumbnails faster for any MP4.

---

## 1. Create a read-only R2 token

1. Open the Cloudflare dashboard → **R2** → **Manage R2 API Tokens** → **Create API token**.
2. Set Permissions to **Object Read only**. Scope it to your video bucket, or to all buckets if you want the app to list them.
3. Copy the **Access Key ID**, the **Secret Access Key** and your **Account ID**. The Account ID is in the endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

You can save several buckets, each with its own token, under **Settings → Buckets → Add bucket**. Tap a bucket there to switch the library to it. Playlists can mix videos from any saved bucket.

You don't need to set up CORS. The app talks to R2 directly over the S3 API with signed requests, not through a browser.

## 2. Build the app without a Mac (GitHub Actions)

You run all of these steps on Windows, in a browser.

1. Create a **private** GitHub repo and upload this whole folder. You can drag the files into the GitHub web UI, or use **Windows Terminal / PowerShell** (no admin needed) with git installed:
   ```powershell
   # PowerShell, inside the unzipped R2be folder — no admin needed
   git init; git add .; git commit -m "R2be"
   git branch -M main
   git remote add origin https://github.com/<you>/r2be.git
   git push -u origin main
   ```
2. Open **Actions → "Build unsigned IPA" → Run workflow**. It takes about 5–8 minutes on GitHub's free macOS runner. (It only runs by hand, because pushes to `main` go to TestFlight instead — see section 4.)
3. When it turns green, open the run and download the **R2be-ipa** artifact. It's a zip containing `R2be.ipa`, so extract it.

## 3. Install on your iPhone with a free Apple ID (Sideloadly)

1. On Windows, install **iTunes** and **iCloud** from Apple's website. Sideloadly needs the classic installers, not the Microsoft Store versions.
2. Install **Sideloadly** from sideloadly.io and plug in your iPhone. Tap **Trust** on the phone when it asks.
3. Drag `R2be.ipa` into Sideloadly, enter your Apple ID and click **Start**. Sideloadly signs the app with a free development certificate and gives it a unique bundle ID automatically.
4. On the iPhone:
   - **Settings → Privacy & Security → Developer Mode → On**, then restart (iOS 16+).
   - **Settings → General → VPN & Device Management →** your Apple ID **→ Trust**.
5. Open **R2be**. Enter your Account ID, Access Key and Secret, tap **Test connection**, then **Save**.

**Free-account limits:**
- The app expires after **7 days**. Re-run Sideloadly to refresh it; your data is kept. Sideloadly's auto-refresh can do this over Wi-Fi.
- You can have at most 3 sideloaded apps at a time.
- No App Store or TestFlight distribution.
- Background audio and AirPlay work with a free account.

## 4. TestFlight with a paid Apple Developer account

With a paid account, every push to `main` builds a signed app and uploads it to TestFlight (**Actions → "TestFlight"**). You install and update it from the TestFlight app. You don't need Sideloadly, a cable or Developer Mode, and each build lasts 90 days. Apple signs it in the cloud, so you don't need a Mac or a certificate file either.

One-time setup, all in a browser:

1. **Register the bundle ID.** Go to [developer.apple.com/account](https://developer.apple.com/account) → **Certificates, IDs & Profiles** → **Identifiers** → **+** → **App IDs** → **App**. Enter the description `R2be` and an **Explicit** bundle ID such as `com.yourname.r2be`, then **Register**. You don't need any capabilities.
2. **Create the app record.** Go to [App Store Connect](https://appstoreconnect.apple.com) → **Apps** → **+** → **New App**. Choose iOS, enter a name (it must be unique on the App Store, e.g. `R2be Player`; the home-screen name stays R2be), pick the bundle ID from step 1, set SKU to `r2be` and keep **Full Access** → **Create**.
3. **Create an API key.** In App Store Connect → **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys**, click **Request Access** if you see it. Then click **+**, name the key `GitHub Actions`, set Access to **Admin** (cloud signing needs it) and click **Generate**. Download the `.p8` file (Apple only lets you do this once). Note the **Key ID** and the **Issuer ID** shown above the table.
4. **Find your Team ID.** It's on [developer.apple.com/account](https://developer.apple.com/account) under **Membership details**.
5. **Add GitHub secrets.** In your repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**, add:

   | Name | Value |
   |---|---|
   | `APPLE_TEAM_ID` | Team ID from step 4 |
   | `APP_BUNDLE_ID` | bundle ID from step 1 |
   | `ASC_KEY_ID` | Key ID from step 3 |
   | `ASC_ISSUER_ID` | Issuer ID from step 3 |
   | `ASC_KEY_P8` | Open the `.p8` in Notepad and paste all of it, including the `BEGIN`/`END` lines |

6. **Run it.** Go to **Actions** → **TestFlight** → **Run workflow**. After it turns green, Apple takes another 5–30 minutes to process the build. It then shows under your app → **TestFlight**.
7. **Add yourself as a tester.** In your app → **TestFlight** → **Internal Testing** → **+**, create a group (e.g. `Me`), turn on automatic distribution and add yourself.
8. **Install.** On the iPhone, install [TestFlight](https://apps.apple.com/app/testflight/id899247664) and sign in with the same Apple ID. R2be appears there; tap **Install**. Future pushes to `main` show up as updates.

Notes:
- The build number is the workflow's run number, so every run uploads a new build. Re-running the *same* run is rejected as a duplicate; start a new run instead.
- Apple creates a "Created via API" development certificate the first time it signs on a new runner. You can revoke old ones under **Certificates** at any time.
- If a run fails, download the **testflight-log** artifact from that run.

## Project layout

```
project.yml                     XcodeGen spec (the workflow turns it into R2be.xcodeproj)
.github/workflows/build-ipa.yml macOS CI → unsigned .ipa (manual)
.github/workflows/testflight.yml signed build → TestFlight (on push to main)
R2be/
  App/R2beApp.swift         App entry, tab bar, full-screen player presentation
  R2/SigV4.swift                AWS Signature V4 (header auth + presigned URLs), checked against AWS test vectors
  R2/R2Client.swift             ListObjectsV2 / ListBuckets / presigned stream URLs (read-only)
  R2/S3XMLParsers.swift         S3 XML responses
  R2/KeychainStore.swift        Credentials in the iOS Keychain
  Models/Models.swift           VideoItem, Playlist(+entries), sort/layout enums, search
  Services/LibraryStore.swift   Bucket index (cached), folder tree, search, playlist resolution
  Services/PlaylistStore.swift  App-side playlists (JSON in Application Support)
  Services/PlayerController.swift  Shared AVPlayer, queue/shuffle/autoplay, ±30 s, lock screen
  Services/ThumbnailService.swift  Frame grabbing + disk/memory cache, 3 at a time
  Services/ResumeStore.swift    Per-video position and duration
  Views/…                       Library, Feed, Player, Mini player, Playlists, Settings
```

**How the library works:** on launch (and at most every 15 min, or when you pull to refresh), the app lists the whole bucket at 1,000 keys per request and caches the list on the phone. Browsing, search and playlist expansion then run locally, so they're instant and don't add R2 operations. Video bytes are streamed with presigned URLs (6 h by default; you can change this in Settings). R2 supports Range requests, so seeking only downloads what you watch.
