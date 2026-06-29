# Xcode Project Setup Guide

## Problem

When you create a new Xcode project from the template it generates two placeholder files:
- `BitFlow/BitFlowApp.swift`
- `BitFlow/ContentView.swift`

These now exist in the repo at `BitFlow/BitFlow/` to satisfy the default project references.
Our real implementation is in subdirectories (`App/`, `Core/`, `Features/`, etc.).
Xcode doesn't automatically know about those files — you must add them to the target.

---

## Step-by-step Fix

### 1. Pull latest from git

```bash
cd ~/Desktop/BitFlow
git pull origin claude/ios-bittorrent-client-fetooh
```

### 2. Open the project

```bash
open BitFlow.xcodeproj
```

### 3. Add source groups to the Xcode target

In the **Project Navigator** (left panel):

1. Right-click on the `BitFlow` folder (the blue folder under your project root)
2. Choose **"Add Files to 'BitFlow'..."**
3. Navigate to your `BitFlow/` folder
4. Select **all of these folders** (hold ⌘ to multi-select):
   - `App`
   - `Core`
   - `Features`
   - `ViewModels`
   - `Utilities`
5. Make sure:
   - ✅ "Copy items if needed" is **unchecked** (files are already in place)
   - ✅ "Create groups" is selected (not folder references)
   - ✅ Target `BitFlow` is checked under "Add to targets"
6. Click **Add**

### 4. Remove the placeholder stubs

After adding the real source, these two stub files are no longer needed:
- In the navigator, select `BitFlow/BitFlowApp.swift` (the one in the flat `BitFlow/BitFlow/` folder)
- Select `BitFlow/ContentView.swift` (same flat folder)
- Press **Delete** → "Move to Trash"

The real entry point is now `BitFlow/App/BitFlowApp.swift`.

### 5. Update Info.plist path (if needed)

If Xcode shows an Info.plist error:
1. Select the **BitFlow** project in the navigator → **BitFlow** target → **Build Settings**
2. Search for `INFOPLIST_FILE`
3. Set it to: `BitFlow/Resources/Info.plist`

### 6. Add Capabilities

In the BitFlow target → **Signing & Capabilities**:
- Click **+ Capability**
- Add **Background Modes**
- Check:
  - [x] Background processing
  - [x] Background fetch

### 7. Build & Run

Select your simulator or device and press **⌘R**.

---

## Compile Order / Dependencies

The files compile in any order since Swift handles forward references. The key dependency graph is:

```
Bencode ← InfoHash ← TorrentMetadata ← TorrentSession ← TorrentEngine
                    ↑
                 MagnetLink
                 
PeerMessage ← PeerConnection ← PeerManager ← TorrentSessionActor
ExtensionProtocol ↗

Bitfield ← PieceManager ← TorrentSessionActor

TrackerManager ← TorrentSessionActor
DHTNode ← TorrentSessionActor
LocalServiceDiscovery ← TorrentSessionActor

StorageManager ← TorrentSessionActor

BackgroundTaskManager ← AppDelegate
NetworkMonitor ← (global singleton)
```

---

## Common Build Errors

### "Cannot find type 'X' in scope"
→ The file defining X hasn't been added to the target. Use "Add Files to 'BitFlow'" for the group containing it.

### "Redeclaration of 'BitFlowApp'"
→ You have both `BitFlow/BitFlow/BitFlowApp.swift` AND `BitFlow/App/BitFlowApp.swift` in the target. Delete the one in the flat folder.

### "Redeclaration of 'ContentView'"
→ Same issue — delete `BitFlow/BitFlow/ContentView.swift` from the target.

### Swift 6 concurrency warnings
→ In **Build Settings**, set **Swift Language Version** to **Swift 6**. All actors and Sendable conformances are already correct.

### "Missing AppIcon"
→ The `Assets.xcassets/AppIcon.appiconset/Contents.json` is set up for a universal 1024×1024 icon with no image file required (Xcode accepts this for simulators). For device builds, add a 1024×1024 PNG.
