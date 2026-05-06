# OnStep Controller for iOS

A native iPhone app for controlling telescope mounts running the [OnStep](https://groups.io/g/onstep) open-source mount controller firmware. Built with SwiftUI, targeting iOS 17+.

---

## Features

### Connection
- Connect over **WiFi** (OnStep or OnStepX via SmartWebServer)
- Connect over **Bluetooth Low Energy** (OnStepX with BLE plugin required — iOS does not support Classic Bluetooth)

### Setup
- Send GPS coordinates, date, time, and UTC offset directly to the mount
- Compare mount site data against your iPhone's values side by side
- Find home position and park/unpark the mount

### Interactive Sky Chart
- Live star and deep-sky object chart projected for your exact location and time
- Pan (drag) and zoom (pinch) freely across the sky
- Horizon, overhead limit, and meridian flip limits drawn on the chart
- Milky Way overlay, cardinal direction labels, and FOV indicator
- Tap any object to see details and issue a GoTo command
- Cancel an in-progress GoTo at any time

### Visual Star Alignment
- 1–9 star alignment initiated from the Setup tab
- After each GoTo the alignment panel slides up automatically
- Fine-tune star centering with an on-screen D-pad
- Accept each star and proceed to the next directly from the sky chart
- Polar alignment residuals (altitude and azimuth error) shown on completion

### Mount Control
- N/S/E/W directional pad with four slew rates: Guide, Center, Find, Slew
- Toggle tracking on/off
- Switch between Sidereal, Lunar, and Solar tracking rates
- Live RA, Dec, Alt, Az coordinate readouts

### GoTo Catalog
- Built-in catalog of named stars, open clusters, globular clusters, nebulae, galaxies, and planetary nebulae
- Filter to objects currently above the horizon using your GPS location
- Search by name or catalog ID
- Manual coordinate entry for objects not in the catalog

### Designed for the Dark
- Forced dark mode throughout
- Deep red accent color to protect night vision at the eyepiece

---

## Requirements

- iPhone running **iOS 17** or later
- An **OnStep** or **OnStepX** telescope mount controller
- WiFi connection via SmartWebServer, or OnStepX with a BLE plugin for Bluetooth

---

## Building from Source

1. Install [Xcode 15](https://developer.apple.com/xcode/) or later
2. Clone this repository
3. Open `OnStep.xcodeproj`
4. Set your development team under **Signing & Capabilities**
5. Build and run on your iPhone or the iOS Simulator

No external dependencies — the project uses only Apple frameworks (SwiftUI, CoreBluetooth, CoreLocation, Network).

---

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, code style guidelines, and the pull request process.

---

## License

OnStep Controller is released under the [GNU General Public License v3.0](LICENSE).

---

## Acknowledgements

- [OnStep](https://groups.io/g/onstep) — the open-source telescope mount controller project by Howard Dutton and the OnStep community
- Star and DSO catalog data derived from open astronomical databases
