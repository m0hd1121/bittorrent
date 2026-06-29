# BitFlow — Setup Guide

## Requirements

- Xcode 16+ (latest)
- iOS 18+ deployment target
- Swift 6
- macOS Sonoma or later (for development)

## Getting Started

### 1. Open in Xcode

```bash
open BitFlow.xcodeproj
```

If you need to create the Xcode project fresh from these sources:

1. Create a new iOS App project in Xcode
2. Set:
   - Product Name: BitFlow
   - Team: Your team
   - Bundle Identifier: com.bitflow.app
   - Interface: SwiftUI
   - Language: Swift
   - Minimum Deployments: iOS 18.0
3. Replace generated files with the sources in `BitFlow/`
4. Add all Swift files from the directory structure
5. Set Swift Language Version to Swift 6

### 2. Configure Signing

In the Signing & Capabilities tab:
- Enable "Automatic signing" with your Apple ID
- Add "Background Modes" capability:
  - [x] Background processing
  - [x] Background fetch

### 3. Build

Select your device or simulator and build (⌘B).

### 4. Run Tests

```bash
⌘U
```

Tests are in `BitFlowTests/Unit/` and `BitFlowTests/Performance/`.

## Key Files

| File | Purpose |
|------|---------|
| `Core/TorrentEngine/Torrent/Bencode.swift` | Bencode parser — the foundation |
| `Core/TorrentEngine/Torrent/TorrentMetadata.swift` | .torrent file parser |
| `Core/TorrentEngine/Engine/TorrentEngine.swift` | Main engine singleton |
| `Core/TorrentEngine/Engine/TorrentSession.swift` | Per-torrent download session |
| `Core/TorrentEngine/Peers/PeerConnection.swift` | Individual peer TCP connection |
| `Core/TorrentEngine/Pieces/PieceManager.swift` | Piece scheduling and verification |
| `Core/Background/BackgroundTaskManager.swift` | iOS background task registration |
| `Features/TorrentList/TorrentListView.swift` | Main UI |

## Architecture Notes

The project uses Swift 6 strict concurrency:
- `actor` for all engine components (no data races)
- `@MainActor` for all UI-facing types
- `Sendable` enforced on all cross-actor types

See `Documentation/ARCHITECTURE.md` for the full technical breakdown.
