# Contributing to OnStep Controller

Thank you for your interest in contributing! This document explains how to set up the project locally, make changes, and submit them for review so they can be tested and published to the App Store.

---

## Requirements

- Mac running macOS 14 (Sonoma) or later
- Xcode 15 or later (free from the Mac App Store)
- An iPhone running iOS 17 or later for on-device testing
- An OnStep or OnStepX telescope mount controller (optional but helpful for full testing)

---

## Getting Started

### 1. Fork the repository

Click **Fork** on the GitHub repository page. This creates your own copy of the project under your GitHub account.

### 2. Clone your fork

```bash
git clone https://github.com/YOUR_USERNAME/OnStep.git
cd OnStep
```

### 3. Open in Xcode

Double-click `OnStep.xcodeproj` to open the project in Xcode. No additional dependencies or package manager setup is required — the project uses only Apple frameworks.

### 4. Set a development team

To run on a physical iPhone you need a free Apple Developer account:
1. In Xcode, click the **OnStep** project in the Navigator
2. Select the **OnStep** target → **Signing & Capabilities**
3. Set **Team** to your personal Apple ID
4. Change the **Bundle Identifier** to something unique (e.g. `com.yourname.onstep`)

You can run in the iOS Simulator without a developer account.

---

## Project Structure

```
OnStep/
├── OnStepManager.swift      # All mount communication (LX200 protocol, WiFi/BT transports)
├── BluetoothManager.swift   # CoreBluetooth BLE scanning and connection
├── LocationManager.swift    # GPS location access
├── ContentView.swift        # App entry, tab layout, shared AppState
├── SetupView.swift          # Connection, site setup, alignment start
├── ControlView.swift        # D-pad, slew rates, tracking, park
├── GoToView.swift           # Catalog search and coordinate entry
├── SkyChartView.swift       # Interactive star chart with GoTo and alignment flow
├── SkyChartViewModel.swift  # Projection math and chart state
├── AlignmentView.swift      # Nudge/accept panel shown during alignment
├── HomingView.swift         # Home search progress sheet
├── SkyCatalog.swift         # Messier and DSO catalog data
├── StarCatalog.swift        # Named star catalog data
└── AstroColors.swift        # App color palette (astroRed, astroAmber)
```

---

## Making Changes

### Branch naming

Create a branch from `main` with a short descriptive name:

```bash
git checkout -b feature/my-new-feature
# or
git checkout -b fix/descriptive-bug-name
```

### Code style

- SwiftUI views only — no UIKit
- `@Observable` + `@Environment` for shared state (iOS 17+)
- `async`/`await` preferred over Combine
- 4-space indentation
- No comments that describe *what* the code does — only *why* when it's non-obvious
- Dark mode only — use `Color.astroRed` and `Color.astroAmber` from `AstroColors.swift` for accent colors

### Testing

- Build with **Product → Build** (⌘B) before submitting
- Test on a physical device if possible — Bluetooth and some WiFi behaviours differ in the simulator
- If you have an OnStep mount, test the specific flow your change touches end-to-end

---

## Submitting a Pull Request

1. Push your branch to your fork:

```bash
git push origin feature/my-new-feature
```

2. Go to the original repository on GitHub and click **Compare & pull request**

3. Fill in the PR description:
   - What does this change do?
   - How did you test it?
   - Any known limitations or follow-up work?

4. Submit the PR — the maintainer will review it, request changes if needed, and merge when it's ready

---

## What Happens After Merge

Once a PR is merged into `main`:

1. The maintainer reviews the merged code on a physical device
2. The app is archived in Xcode (**Product → Archive**) and uploaded to Apple via **Distribute App**
3. Apple reviews the build (typically 1–3 days)
4. The update is released on the App Store

Contributors are credited in the release notes.

---

## Reporting Bugs

Open a GitHub Issue with:
- What you expected to happen
- What actually happened
- Your iOS version and connection type (WiFi / Bluetooth)
- Your OnStep firmware version if known

---

## License

By contributing you agree that your code will be released under the [GNU General Public License v3.0](LICENSE).
