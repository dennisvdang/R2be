# R2be

An iPhone app that turns a Cloudflare R2 bucket into a personal media server. You browse it like Google Drive and watch it like YouTube. Every video plays inside the app, never in Safari.

**Read-only by design:** the app only lists and streams your files. Playlists, watch progress and thumbnails are stored on the phone. Nothing in your bucket is created, moved, renamed or deleted.

## Features

| Area | What you get |
|---|---|
| **Library** | Folder browser built from your bucket's `/` prefixes. Four layouts: List, Small grid (3-up), Grid (2-up) and Feed cards (YouTube-style). Sort by name, date, size or random. Folder tiles show a cover frame and a video count. |
| **Search** | Searches file names in **This folder** or **Everywhere**. Ignores case and accents, and treats `_`, `-` and `.` as spaces. |
| **Player** | Built-in AVPlayer with custom controls: ±30 s buttons, **double-tap left/right for ±30 s**, previous/next, a scrubber, speed (0.5–2×) and AirPlay. Switch between fill and fit, or force landscape. Swipe down to minimise. Swipe left/right on the video to skip. |
| **Autoplay / shuffle** | Autoplay next (on by default). Shuffle on any folder, playlist or search result picks a random video first, then keeps shuffling without repeats. You can also reshuffle and loop the queue. |
| **Up Next** | In portrait the video sits on top and the queue sits underneath. Tap a row to jump to it, swipe to remove it. Long-press any video to choose **Play Next** or **Add to Queue**. |
| **Feed tab** | Full-screen vertical feed you swipe through (Shorts/Reels style) over All videos, Recently added, any top-level folder or any playlist. Shows the current video with −30/+30, Save, Share and Expand buttons. The feed advances on its own when a video ends. |
| **Playlists** | Stored on the phone. Add single videos, or add folders as **live sources** (with or without subfolders), so new uploads appear automatically. You can mix sources from any subfolder, reorder, rename, duplicate, and combine several playlists into a new one. |
| **Mini player** | Keeps playing while you browse, YouTube-style. Lock screen and Control Center controls work too: play/pause, ±30 s and scrubbing. |
| **Thumbnails** | Grabbed from a frame about 10% into each video and only the bytes needed are streamed. They're cached on the phone. If you put `clip.jpg` (or `clip.mp4.jpg`, or `thumbs/clip.jpg`) next to `clip.mp4`, the app uses that image instead. |
| **Resume** | Remembers where you stopped in each video. A red progress bar shows on the thumbnails. |

**Formats:** MP4, MOV and M4V (H.264/HEVC), HLS `.m3u8`, and MP3/M4A. iOS can't play MKV, AVI or WebM natively, so those are hidden. You can convert them with `ffmpeg -i in.mkv -c copy -movflags +faststart out.mp4`. The `+faststart` flag also makes seeking and thumbnails faster for any MP4.

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
2. The push starts **Actions → "Build unsigned IPA"**. It takes about 5–8 minutes on GitHub's free macOS runner. You can also start it by hand with **Run workflow**.
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

## Project layout

```
project.yml                     XcodeGen spec (the workflow turns it into R2be.xcodeproj)
.github/workflows/build-ipa.yml macOS CI → unsigned .ipa
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
