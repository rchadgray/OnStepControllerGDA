import SwiftUI

// The main hand-controller screen. Provides directional movement buttons,
// a stop button, slew-rate selector, and quick-action buttons for tracking,
// parking, home, and tracking rate. All controls are disabled when the
// mount is not connected.
struct ControlView: View {
    @EnvironmentObject var telescope: OnStepManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ConnectionStatusBar()
                    CoordinatesBar()
                    DirectionalPad()
                        .padding(.vertical, 8)
                    SlewRatePicker()
                    ActionButtons()
                }
                .padding()
            }
            .navigationTitle("OnStep Control")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Connection Status Bar

// Shows a green/red dot for connection state, status tags for tracking/slewing/parked,
// and a connect/disconnect button — all in a compact pill at the top of the screen.
struct ConnectionStatusBar: View {
    @EnvironmentObject var telescope: OnStepManager
    @EnvironmentObject var bluetooth: BluetoothManager

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(telescope.isConnected ? Color.green : Color.red)
                .frame(width: 10, height: 10)

            Text(telescope.isConnected ? "Connected" : "Disconnected")
                .font(.subheadline).fontWeight(.medium)

            // Status tags only appear when the mount is in that state.
            if telescope.mountStatus.isTracking  { statusTag("Tracking",  .astroAmber) }
            if telescope.mountStatus.isSlewing   { statusTag("Slewing",   .orange)    }
            if telescope.mountStatus.isParked    { statusTag("Parked",    .astroRed)  }

            Spacer()

            if telescope.isConnected {
                Button("Disconnect") {
                    telescope.disconnect()
                    bluetooth.disconnect()
                }
                .font(.subheadline)
                .buttonStyle(.bordered)
                .tint(.astroRed)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .cornerRadius(12)
    }

    // Small coloured pill label used for mount state indicators.
    @ViewBuilder
    func statusTag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(4)
    }
}

// MARK: - Coordinates Bar

// Live RA/Dec/Alt/Az readout updated every second by OnStepManager's background poll.
struct CoordinatesBar: View {
    @EnvironmentObject var telescope: OnStepManager

    var body: some View {
        HStack(spacing: 0) {
            coordItem("RA",  telescope.mountStatus.ra)
            Divider().frame(height: 44)
            coordItem("DEC", telescope.mountStatus.dec)
            Divider().frame(height: 44)
            coordItem("ALT", telescope.mountStatus.alt)
            Divider().frame(height: 44)
            coordItem("AZ",  telescope.mountStatus.az)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.astroRed.opacity(0.08))
        .cornerRadius(12)
    }

    // A single labelled coordinate column.
    @ViewBuilder
    func coordItem(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value)
                .font(.system(.footnote, design: .monospaced)).fontWeight(.medium)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Directional Pad

// Four arrow buttons arranged in a cross pattern around a central stop button.
// Buttons send a move command on press and a stop command on release, matching
// the behaviour of a hardware hand controller.
struct DirectionalPad: View {
    @EnvironmentObject var telescope: OnStepManager

    var body: some View {
        VStack(spacing: 14) {
            DPadButton(icon: "chevron.up",    onPress: telescope.moveNorth, onRelease: telescope.stopNorth)
            HStack(spacing: 40) {
                DPadButton(icon: "chevron.left",  onPress: telescope.moveWest, onRelease: telescope.stopWest)
                stopButton
                DPadButton(icon: "chevron.right", onPress: telescope.moveEast, onRelease: telescope.stopEast)
            }
            DPadButton(icon: "chevron.down",  onPress: telescope.moveSouth, onRelease: telescope.stopSouth)
        }
        .disabled(!telescope.isConnected)
        .opacity(telescope.isConnected ? 1.0 : 0.4)
    }

    // Centre stop button — immediately halts all axis movement.
    private var stopButton: some View {
        Button { telescope.stopAll() } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.red.opacity(0.85))
                .clipShape(Circle())
                .shadow(color: .red.opacity(0.3), radius: 6)
        }
    }
}

// A single directional button. Uses DragGesture (minimumDistance: 0) rather
// than a standard Button so we can detect both press-down and release events —
// essential for the move-on-press, stop-on-release behaviour.
struct DPadButton: View {
    let icon: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isPressed = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 90, height: 90)
            .background(isPressed ? Color.astroRed.opacity(0.65) : Color.astroRed)
            .clipShape(Circle())
            .shadow(color: Color.astroRed.opacity(0.3), radius: 8, x: 0, y: 4)
            .scaleEffect(isPressed ? 0.94 : 1.0)
            .animation(.easeInOut(duration: 0.08), value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        onPress()
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
    }
}

// MARK: - Slew Rate Picker

// Four buttons (Guide / Center / Find / Slew) that set the speed used by the
// directional pad. The currently active rate is highlighted in red.
struct SlewRatePicker: View {
    @EnvironmentObject var telescope: OnStepManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Slew Rate")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)

            HStack(spacing: 8) {
                ForEach(SlewRate.allCases) { rate in
                    Button { telescope.setSlewRate(rate) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: rate.icon).font(.system(size: 18))
                            Text(rate.rawValue).font(.caption2).fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        // Highlight the active rate.
                        .background(telescope.mountStatus.slewRate == rate ? Color.astroRed : Color.secondary.opacity(0.12))
                        .foregroundStyle(telescope.mountStatus.slewRate == rate ? Color.white : Color.primary)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .disabled(!telescope.isConnected)
        .opacity(telescope.isConnected ? 1.0 : 0.4)
    }
}

// MARK: - Action Buttons

// Quick-action buttons for common operations:
//   Tracking toggle — start/stop sidereal tracking
//   Park/Unpark     — move to/from the park position
//   Tracking Rate   — choose sidereal, lunar, or solar via a menu
//   Home            — slew back to the home position
struct ActionButtons: View {
    @EnvironmentObject var telescope: OnStepManager
    @State private var showParkConfirmation = false
    @State private var showHomeConfirmation = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // Tracking toggle — amber when on to make it easy to spot at a glance.
                Button {
                    telescope.mountStatus.isTracking ? telescope.trackingOff() : telescope.trackingOn()
                } label: {
                    Label(
                        telescope.mountStatus.isTracking ? "Tracking On" : "Tracking Off",
                        systemImage: telescope.mountStatus.isTracking ? "play.circle.fill" : "pause.circle.fill"
                    )
                    .frame(maxWidth: .infinity).padding()
                    .background(telescope.mountStatus.isTracking ? Color.astroAmber.opacity(0.12) : Color.secondary.opacity(0.12))
                    .foregroundStyle(telescope.mountStatus.isTracking ? Color.astroAmber : Color.primary)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)

                Button { showParkConfirmation = true } label: {
                    Label(
                        telescope.mountStatus.isParked ? "Unpark" : "Park",
                        systemImage: telescope.mountStatus.isParked ? "arrow.up.circle" : "parkingsign.circle"
                    )
                    .frame(maxWidth: .infinity).padding()
                    .background(Color.astroRed.opacity(0.12))
                    .foregroundStyle(Color.astroRed)
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    telescope.mountStatus.isParked ? "Unpark Mount?" : "Park Mount?",
                    isPresented: $showParkConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(telescope.mountStatus.isParked ? "Unpark" : "Park", role: .destructive) {
                        telescope.mountStatus.isParked ? telescope.unpark() : telescope.park()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(telescope.mountStatus.isParked
                         ? "The mount will leave its park position and resume tracking."
                         : "The mount will slew to its park position and stop tracking.")
                }
            }

            HStack(spacing: 10) {
                // Tracking rate menu — sidereal for stars, lunar for the Moon, solar for the Sun.
                Menu {
                    ForEach(TrackingRate.allCases) { rate in
                        Button(rate.rawValue) { telescope.setTrackingRate(rate) }
                    }
                } label: {
                    Label(telescope.mountStatus.trackingRate.rawValue, systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.secondary.opacity(0.12))
                        .foregroundStyle(Color.primary)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)

                Button { showHomeConfirmation = true } label: {
                    Label("Home", systemImage: "house")
                        .frame(maxWidth: .infinity).padding()
                        .background(Color.secondary.opacity(0.12))
                        .foregroundStyle(Color.primary)
                        .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    "Find Home Position?",
                    isPresented: $showHomeConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Find Home", role: .destructive) {
                        telescope.goHome()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The mount will slew to its home position. Your star alignment model will be preserved.")
                }
            }
        }
        .disabled(!telescope.isConnected)
        .opacity(telescope.isConnected ? 1.0 : 0.4)
    }
}
