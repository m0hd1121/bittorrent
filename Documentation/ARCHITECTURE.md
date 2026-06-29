# BitFlow — Architecture & Technical Documentation

## 1. Project Structure

```
BitFlow/
├── App/
│   ├── BitFlowApp.swift          # SwiftUI @main entry point
│   ├── AppDelegate.swift          # UIApplicationDelegate (background tasks, appearance)
│   └── AppCoordinator.swift       # Root coordinator / DI root
│
├── Core/                          # Pure Swift, no UI dependencies
│   ├── TorrentEngine/
│   │   ├── Engine/
│   │   │   ├── TorrentEngine.swift        # Singleton engine, session management
│   │   │   ├── TorrentSession.swift       # Per-torrent session + stats
│   │   │   └── MetadataFetcher.swift      # BEP 9 ut_metadata fetcher
│   │   │
│   │   ├── Torrent/
│   │   │   ├── Bencode.swift              # Bencode encoder/decoder
│   │   │   ├── InfoHash.swift             # SHA1 (v1) and SHA256 (v2) info hashes
│   │   │   ├── MagnetLink.swift           # Magnet URI parser (btih + btmh)
│   │   │   └── TorrentMetadata.swift      # .torrent parser, file layout
│   │   │
│   │   ├── Pieces/
│   │   │   └── PieceManager.swift         # Rarest-first scheduling, verification, bitfield
│   │   │
│   │   ├── Protocol/
│   │   │   ├── PeerMessage.swift          # Wire protocol encode/decode, handshake
│   │   │   └── ExtensionProtocol.swift    # BEP 10 extensions, ut_metadata, PEX
│   │   │
│   │   ├── Peers/
│   │   │   ├── PeerConnection.swift       # NWConnection-based peer, pipeline management
│   │   │   └── PeerManager.swift          # Connection pooling, choking, scoring
│   │   │
│   │   ├── Trackers/
│   │   │   └── TrackerManager.swift       # HTTP + UDP tracker announce (BEP 15)
│   │   │
│   │   ├── DHT/
│   │   │   └── DHTNode.swift              # Kademlia DHT (BEP 5), routing table
│   │   │
│   │   ├── PEX/
│   │   │   └── (in ExtensionProtocol.swift)
│   │   │
│   │   └── LSD/
│   │       └── LocalServiceDiscovery.swift # BEP 14 multicast peer discovery
│   │
│   ├── Networking/
│   │   └── NetworkMonitor.swift           # NWPathMonitor, Low Data Mode, VPN
│   │
│   ├── Storage/
│   │   └── StorageManager.swift           # File pre-allocation, piece writes, verification
│   │
│   └── Background/
│       └── BackgroundTaskManager.swift    # BGProcessingTask + BGAppRefreshTask
│
├── Features/
│   ├── TorrentList/
│   │   └── TorrentListView.swift          # Home screen, torrent list, swipe actions
│   ├── TorrentDetail/
│   │   └── TorrentDetailView.swift        # Detail: overview, files, peers, trackers, pieces
│   ├── AddTorrent/
│   │   └── AddTorrentView.swift           # Magnet input + .torrent file picker
│   ├── Settings/
│   │   └── SettingsView.swift             # Settings, background info, logs viewer
│   └── StorageManager/
│       └── (in SettingsView.swift)
│
├── ViewModels/
│   ├── TorrentListViewModel.swift
│   └── SettingsViewModel.swift
│
├── Utilities/
│   └── LogManager.swift                   # In-memory structured log ring buffer
│
└── Resources/
    └── Info.plist                         # Background modes, URL schemes, document types
```

---

## 2. Architecture Pattern

**MVVM + Clean Architecture with actor-based concurrency**

```
UI Layer (SwiftUI Views + ViewModels)
    ↓ @Published / ObservableObject
Engine Layer (TorrentEngine @MainActor singleton)
    ↓ async/await
Session Layer (TorrentSession — per torrent, @MainActor)
    ↓
Actor Layer (TorrentSessionActor — all networking work)
    ↓
Protocol Layer (PeerConnection actor, TrackerManager actor, etc.)
    ↓
Foundation Layer (Bencode, Bitfield, PieceManager — value types)
```

Key design decisions:
- **All engine work runs in actors** — no locks, no data races (Swift 6 strict concurrency)
- **@MainActor on UI-facing types** — SwiftUI bindings are always on main thread
- **Sendable everywhere** — enforced by Swift 6 compiler

---

## 3. BitTorrent Protocol Implementation

### Version Support
| Feature | Supported |
|---------|-----------|
| BT v1 (SHA1) | ✅ |
| BT v2 (SHA256) | ✅ (piece layer structure, full verification in progress) |
| Hybrid torrents | ✅ |
| Magnet v1 (btih) | ✅ |
| Magnet v2 (btmh) | ✅ |

### Peer Discovery
| Method | Implementation |
|--------|----------------|
| HTTP Trackers | URLSession with compact peer format |
| HTTPS Trackers | Same — ATS allows arbitrary loads for tracker comms |
| UDP Trackers | NWConnection UDP (BEP 15) |
| DHT (BEP 5) | Kademlia K-bucket routing table, get_peers |
| PEX (BEP 11) | ut_pex extension message parsing |
| LSD (BEP 14) | UDP multicast 239.192.152.143:6771 |

### Wire Protocol (BEP 3)
All 12 standard messages implemented: keepalive, choke, unchoke, interested, not-interested, have, bitfield, request, piece, cancel, port, extended.

Extension Protocol (BEP 10): handshake with `m` dict, ut_metadata, ut_pex.

### Piece Scheduling
1. **Rarest-first**: Pieces sorted by availability count across all peers
2. **End-game mode**: Activated when <5% pieces remain; blocks requested from multiple peers simultaneously, duplicates cancelled on receipt
3. **Pipeline**: Up to 16 outstanding block requests per peer
4. **Block size**: 16 KiB (standard)

### Choking (BEP 3)
- 4 unchoke slots + 1 optimistic unchoke
- 10-second algorithm cycle (3x = 30s optimistic rotation)
- Tit-for-tat: unchoke peers who upload most to us
- Seeding: score by upload reciprocity

---

## 4. Background Execution Strategy

### What's Possible on iOS

| Mechanism | Works for BT? | Notes |
|-----------|---------------|-------|
| BGProcessingTask | ⚠️ Partial | System discretion; ~1-30 min; requires network |
| BGAppRefreshTask | ⚠️ Short | ~30 sec; state persistence only |
| URLSession Background | ❌ No | HTTP/HTTPS only — not for raw sockets |
| VoIP / PushKit | ❌ No | Requires server to send push |
| Network Extension | ❌ No | Needs Apple entitlement; wrong use case |
| Continuous Background | ❌ Impossible | iOS kills sockets within ~30s of backgrounding |

### Our Implementation
```
Foreground: Full-speed downloads, all connections active
Background: 
  - iOS suspends network sockets immediately
  - BGProcessingTask registered — iOS may grant 1-30 min opportunistically
  - All download state (bitfield) persisted to UserDefaults/disk on background
  - On foreground: instant resume from exact point
```

This is the **maximum achievable** behavior without jailbreak or Apple special entitlements.

---

## 5. Networking Layer

**NWConnection** (Network framework) used for all TCP/UDP:
- TCP for peer connections
- UDP for DHT, UDP trackers, LSD
- Automatic IPv4/IPv6 selection
- VPN-transparent (NWConnection routes through current path)
- Low Data Mode awareness via NWPathMonitor `isConstrained`

**Connection Pool**: PeerManager manages up to 200 connections (configurable), with 30 half-open limit.

**Network Path Monitoring**: NetworkMonitor observes path changes; auto-pauses on disconnect, adapts to cellular vs WiFi.

---

## 6. Storage Layer

**StorageManager** handles:
- File pre-allocation via FileHandle.truncate (avoids fragmentation)
- Piece-to-file mapping across multi-file torrents
- Memory: pieces are written to disk immediately after verification (no full-torrent buffering)
- Verification: SHA1 per piece against metadata's `pieces` field
- Files app integration via document directory (`.documentDirectory`)
- Security-scoped bookmarks for user-selected locations (future)

**Piece Cache**: 32 MB in-memory cache for blocks before they're assembled into pieces. Flushed immediately after verification.

---

## 7. Performance Optimizations

| Technique | Implementation |
|-----------|----------------|
| Rarest-first scheduling | `pieceAvailability` array, O(n log n) sort |
| End-game mode | Last 5% of pieces; multi-peer requests |
| Request pipeline | 16 outstanding requests/peer |
| Connection pool | Max 200 connections, LRU eviction |
| Async/await | All I/O non-blocking, no threads blocked |
| Actor isolation | Zero locks, zero data races |
| Compact peer format | Binary 6/18 byte peer representations |
| Pre-allocated files | Avoids repeated seek+write overhead |
| Adaptive update rate | Stats update 1/sec foreground, less background |
| Low Data Mode | `isConstrained` → pause cellular seeding |

---

## 8. Security

- All operations in App Sandbox
- No private APIs
- No jailbreak requirement
- Malformed torrent protection: TorrentParser validates all fields, throws on invalid data
- No arbitrary code execution paths from torrent metadata
- File paths sanitized (no path traversal)
- Peer IDs validated (must be 20 bytes)
- Handshake validates info hash before accepting connection

---

## 9. Known iOS Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| Background socket suspension | Downloads stop when app is backgrounded | BGProcessingTask opportunistic downloads |
| No background URLSession for BT | Cannot use iOS daemon for downloads | None possible |
| App Store restricts VoIP entitlement | Can't keep sockets alive via VoIP | Not applicable |
| 6881 port may be blocked by ISP | Peers can't connect to us | Port is configurable; use NAT-PMP/UPnP (future) |
| No NAT traversal APIs | Peers behind NAT may fail | DHT + tracker relaying helps |
| Thermal throttling | iOS reduces performance on hot devices | Thermal state monitoring (future) |

---

## 10. App Store Compliance

✅ Uses only public APIs  
✅ Follows App Sandbox guidelines  
✅ Background modes declared in Info.plist  
✅ No private entitlements  
✅ File access via standard document directory  
✅ URL scheme declared for magnet: links  
✅ Document type declared for .torrent files  

**Potential App Store concern**: Apple has historically rejected torrent clients from the App Store (even legitimate ones). Framing the app as a general-purpose file downloader with BitTorrent protocol support may improve chances. A future version should also include content filtering to prevent copyright infringement promotion.

---

## 11. Future Improvements

- [ ] NAT-PMP / UPnP for port forwarding
- [ ] Web seed support (BEP 19)
- [ ] Encryption (RC4/AES — BEP 8)
- [ ] µTP (uTorrent Transport Protocol — BEP 29) for congestion control
- [ ] RSS feed subscriptions
- [ ] Sequential download mode (file-first ordering)
- [ ] Per-file priority
- [ ] Bandwidth scheduler (time-of-day limits)
- [ ] Proxy support (SOCKS5/HTTP)
- [ ] Full BT v2 piece layer verification
- [ ] Share Sheet extension
- [ ] Files app provider extension
- [ ] Widget for active downloads
- [ ] Siri Shortcuts integration
