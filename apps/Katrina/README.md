# Katrina for iPhone, iPad and Mac

One SwiftUI app for iOS 17+ and macOS 14+.

| Tab | What it does | Uses tokens? |
| --- | --- | --- |
| Today | What needs you on both Macs, which Mac checked in when, latest decisions, last night's report | No |
| Ask | Ask Katrina anything about your projects; she answers from the Macs' summaries and can keep a note | Yes, with an API key |
| Projects | Every project on both Macs, loose work, and what each one is tied to | No |
| Notes | Keep a decision from your phone; both Macs pick it up within the hour | No |
| Settings | Brain folder, API key (Keychain), model, theme | No |

The app reads `iCloud Drive/PMPBrain` (the summaries `brain.py` writes every hour) and writes notes
to `PMPBrain/inbox`. Nothing else leaves the device. Notes that look like patient detail are refused.

## Build it (on a Mac that runs Xcode 26)

```bash
brew install xcodegen
cd ~/pmp-brain-src/apps/Katrina && xcodegen
open Katrina.xcodeproj
```

In Xcode: Signing & Capabilities > Team = your Apple Developer team. Pick "My Mac" or your iPhone and
press Run. For your phone without a cable: Product > Archive > Distribute > TestFlight.

Add a 1024 × 1024 icon to `Katrina/Assets.xcassets/AppIcon.appiconset` before submitting to the App Store.

## Asking Katrina

Needs an Anthropic API key from console.anthropic.com (billed per use, separate from the Claude
subscription). Default model Opus 5.5 at low effort; Sonnet 5.5 and Haiku 5.5 are cheaper choices in
Settings. The system prompt is cached, and the Macs' digest means most answers need no tool calls.
