# Data collection — to explore

Status: idea, not started. Saved 2026-10-06.

## Goal

Collect user data, with permission, to improve the app and possibly to monetize it.

## Data to explore

| Data | Use | Notes |
|---|---|---|
| What people watch (titles, folders, watch time, completion) | Recommendations, product decisions, monetization | Most sensitive; file names are personal |
| Transcripts (from on-device subtitles) | Search, content insight, monetization | Content itself; currently never leaves the phone |
| Thumbnails / Vision feature prints | Content insight, "looks similar" tuning | Content itself |
| Feature usage counts | What to build or cut | Low risk without identifiers |
| Performance: time to first frame, stalls, index duration | Speed | Low risk |
| Buffering times | Streaming quality, R2 region choice | Low risk |
| Library shape (bucketed counts) | Sizing features | Low risk if bucketed |
| Error codes (R2 403/404, stream failures) | Setup and reliability fixes | Strip names from messages |
| Typed feedback | Direct requests | User-authored |

## Consent

- Opt-in screen at onboarding plus a Settings switch, default off, revocable.
- Granular choices: usage/performance vs. watch history vs. content (transcripts, thumbnails).
- Plain-language list of exactly what is sent, linked to a privacy policy.
- System prompts stay separate (speech, photos); App Tracking Transparency only if tracking across other companies' apps or ads.

## Constraints to check before building

- App Store: privacy policy URL, privacy nutrition label, `PrivacyInfo.xcprivacy` manifest (UserDefaults is a required-reason API; needed for TestFlight uploads too).
- Apple guideline 5.1.2: limits on sharing or selling personal data; no selling to data brokers.
- GDPR (EU): opt-in for non-essential data, access and deletion rights. CCPA (California): "do not sell or share".
- Current promise in the app and README: read-only, nothing leaves the phone except R2 requests. Changing it needs new copy.

## Possible stack

- Cloudflare Worker endpoint → Workers Analytics Engine (events) and R2/D1 (opted-in content data). Same account, free tier.
- Alternative for usage events: TelemetryDeck.
- Crash/energy reports: Xcode Organizer for TestFlight/App Store builds (no code).
