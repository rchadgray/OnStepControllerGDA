import SwiftUI
import CoreBluetooth

// One-time setup screen the user runs before an observing session.
//
// Sections:
//   1. Connection    — type picker (WiFi / Bluetooth) + credentials / scan
//   2. Site Setup    — location + date/time comparison, one send button
//   3. Mount Control — home and park shortcuts
//   4. Star Alignment — choose star count and begin the alignment wizard
//   5. Polar Alignment Error — residual error after star alignment
//   6. App            — version info
struct SetupView: View {
    @EnvironmentObject var telescope:       OnStepManager
    @EnvironmentObject var bluetooth:       BluetoothManager
    @EnvironmentObject var locationManager: LocationManager
    @Environment(AppState.self) var appState

    // LX200 convention: positive = hours behind UTC (West). Ohio EST = +5, EDT = +4.
    @State private var utcOffset: Double = {
        let iOSOffset = Double(TimeZone.current.secondsFromGMT()) / 3600.0
        return -iOSOffset
    }()

    @State private var alignStarCount        = 2
    @State private var showHoming            = false
    @State private var showHomeConfirmation  = false
    @State private var showBTScanSheet       = false
    @State private var showWiFiSheet         = false
    @State private var now                   = Date.now

    enum FeedbackState { case idle, sending, success, failure }
    @State private var setupFeedback: FeedbackState = .idle

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                siteSetupSection
                mountControlSection
                alignmentSection
                polarAlignmentSection
                appSection
            }
            .navigationTitle("Mount Setup")
            .task {
                locationManager.requestLocation()
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    now = Date.now
                    tick += 1
                    if telescope.isConnected {
                        if tick % 3  == 0 { telescope.querySiteInfo()   }
                        if tick % 10 == 0 { telescope.queryPolarError() }
                    }
                }
            }
            .sheet(isPresented: $showHoming) {
                HomingView(isPresented: $showHoming)
                    .environmentObject(telescope)
            }
            .sheet(isPresented: $showWiFiSheet) {
                WiFiConnectView()
                    .environmentObject(telescope)
            }
            .sheet(isPresented: $showBTScanSheet) {
                BluetoothScanView { peripheral in
                    showBTScanSheet = false
                    bluetooth.connect(to: peripheral)
                }
                .environmentObject(bluetooth)
            }
            .onChange(of: bluetooth.isConnected) { _, connected in
                if connected {
                    telescope.connectBluetooth(transport: bluetooth.makeTransport())
                }
            }
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section("Connection") {
            // Chips open a config sheet — green on whichever type is actually connected.
            HStack(spacing: 8) {
                connectionChip(type: .wifi,      label: "WiFi",      sheet: $showWiFiSheet)
                connectionChip(type: .bluetooth, label: "Bluetooth", sheet: $showBTScanSheet)
            }
            .listRowInsets(.init(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowBackground(Color.clear)

            if telescope.isConnected {
                Button(role: .destructive) {
                    telescope.disconnect()
                    bluetooth.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
                LabeledContent("Version", value: telescope.mountStatus.firmwareVersion)
            }
        }
    }

    @ViewBuilder
    private func connectionChip(type: ConnectionType, label: String, sheet: Binding<Bool>) -> some View {
        let activeType: ConnectionType = bluetooth.isConnected ? .bluetooth : .wifi
        let isConnected = telescope.isConnected && activeType == type
        let isDisabled  = telescope.isConnected && !isConnected
        Button {
            sheet.wrappedValue = true
        } label: {
            Text(label)
                .font(.subheadline).fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    isConnected ? Color.green.opacity(0.18) :
                    isDisabled  ? Color.secondary.opacity(0.07) :
                                  Color.secondary.opacity(0.15)
                )
                .foregroundStyle(
                    isConnected ? Color.green :
                    isDisabled  ? Color.secondary.opacity(0.4) :
                                  Color.primary
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isConnected ? Color.green.opacity(0.7) : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    // MARK: - Site Setup

    private var siteSetupSection: some View {
        Section {
            compareHeader

            compareRow("Latitude",
                mount: telescope.mountStatus.siteLatitude,
                phone: locationManager.locationReceived ? locationManager.lx200Latitude : "No GPS")

            compareRow("Longitude",
                mount: telescope.mountStatus.siteLongitude,
                phone: locationManager.locationReceived ? locationManager.lx200Longitude : "No GPS")

            compareRow("Date",
                mount: telescope.mountStatus.siteDate,
                phone: phoneDateFormatted)

            compareRow("Time",
                mount: telescope.mountStatus.siteTime,
                phone: phoneTimeFormatted)

            compareRow("UTC Offset",
                mount: telescope.mountStatus.siteUTCOffset,
                phone: phoneUTCOffsetFormatted)

            Stepper(value: $utcOffset, in: -13.0...14.0, step: 0.5) {
                LabeledContent("Adjust UTC Offset") {
                    Text(utcOffsetLabel)
                        .foregroundStyle(Color.astroAmber)
                        .fontWeight(.semibold)
                }
            }

            Button("Refresh GPS") {
                locationManager.requestLocation()
            }
            .font(.footnote)
            .foregroundStyle(Color.astroRed)

            Button(setupFeedback == .sending ? "Sending…" : "Send All to Mount") {
                sendAll()
            }
            .foregroundStyle(Color.astroRed)
            .disabled(!telescope.isConnected || !locationManager.locationReceived || setupFeedback == .sending)

            if setupFeedback != .idle {
                feedbackRow(state: setupFeedback)
            }

        } header: {
            Text("Site Setup")
        } footer: {
            Text("Latitude positive = North. Longitude positive = West.")
        }
    }

    // MARK: - Mount Control

    private var mountControlSection: some View {
        Section("Mount Control") {
            Button {
                showHomeConfirmation = true
            } label: {
                Label("Find Home Position", systemImage: "house")
            }
            .foregroundStyle(Color.astroRed)
            .disabled(!telescope.isConnected)

            Button {
                telescope.mountStatus.isParked ? telescope.unpark() : telescope.park()
            } label: {
                Label(
                    telescope.mountStatus.isParked ? "Unpark Mount" : "Park Mount",
                    systemImage: telescope.mountStatus.isParked ? "arrow.up.circle" : "parkingsign.circle"
                )
            }
            .foregroundStyle(Color.astroRed)
            .disabled(!telescope.isConnected)
        }
        .confirmationDialog(
            "Find Home Position?",
            isPresented: $showHomeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Find Home", role: .destructive) {
                telescope.goHome()
                showHoming = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The mount will slew to its home position. Your star alignment model will be preserved — re-alignment is only needed if the mount loses power or is physically moved.")
        }
    }

    // MARK: - Star Alignment

    private var alignmentSection: some View {
        Section {
            LabeledContent("Alignment Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(telescope.mountStatus.isAligned ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(telescope.isConnected
                         ? telescope.mountStatus.alignmentDescription
                         : "Not connected")
                        .foregroundStyle(telescope.mountStatus.isAligned ? Color.green : Color.astroAmber)
                        .fontWeight(.semibold)
                }
            }

            if !telescope.mountStatus.isAligned {
                Stepper(value: $alignStarCount, in: 1...9) {
                    LabeledContent("Alignment Stars") {
                        Text("\(alignStarCount)")
                            .foregroundStyle(Color.astroAmber)
                            .fontWeight(.semibold)
                    }
                }
                .disabled(telescope.mountStatus.alignmentInProgress)

                Button {
                    if telescope.mountStatus.alignmentInProgress {
                        appState.alignmentStarCount  = telescope.mountStatus.alignmentTotalStars
                        appState.alignmentTotalStars = telescope.mountStatus.alignmentTotalStars
                        appState.alignmentNextStar   = telescope.mountStatus.alignmentNextStar
                    } else {
                        appState.alignmentStarCount      = alignStarCount
                        appState.alignmentTotalStars     = 0
                        appState.alignmentNextStar       = 1
                        appState.alignmentUsedStarNames  = []
                        appState.alignmentIsComplete     = false
                        appState.alignmentCurrentStarName = ""
                        appState.alignmentCurrentRA      = ""
                        appState.alignmentCurrentDec     = ""
                        telescope.startAlignment(starCount: alignStarCount) {
                            telescope.queryAlignmentStatus { _, next, total in
                                appState.alignmentTotalStars = total > 0 ? total : alignStarCount
                                appState.alignmentNextStar   = max(1, next)
                            }
                        }
                    }
                    appState.isAligning  = true
                    appState.selectedTab = AppState.tabSky
                } label: {
                    Label(telescope.mountStatus.alignmentInProgress
                          ? "Continue Alignment…"
                          : "Begin Star Alignment…",
                          systemImage: "star.circle")
                }
                .foregroundStyle(Color.astroRed)
                .disabled(!canAlign)
            }
        } header: {
            Text("Star Alignment")
        } footer: {
            if !telescope.isConnected {
                Text("Connect to the mount to begin alignment.")
            } else if !locationManager.locationReceived {
                Text("GPS location required to determine visible stars.")
            } else if telescope.mountStatus.isAligned {
                Text("Alignment complete.")
            } else {
                Text("Home the mount first. GoTo each star, center it in the eyepiece, then accept.")
            }
        }
    }

    // MARK: - Polar Alignment Error

    private var polarAlignmentSection: some View {
        Section {
            LabeledContent("Altitude Error") {
                Text(telescope.mountStatus.polarAltError)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(telescope.isConnected ? Color.primary : Color.secondary)
            }
            LabeledContent("Azimuth Error") {
                Text(telescope.mountStatus.polarAzError)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(telescope.isConnected ? Color.primary : Color.secondary)
            }
        } header: {
            Text("Polar Alignment Error")
        } footer: {
            Text("Complete star alignment first. Return here to check the remaining polar error — adjust the mount's alt/az bolts to reduce both values toward zero.")
        }
    }

    // MARK: - App

    private var appSection: some View {
        Section("App") {
            LabeledContent("Version", value: "1.0")
        }
    }

    // MARK: - Send All

    private func sendAll() {
        setupFeedback = .sending
        telescope.setSiteLocation(
            latitude:  locationManager.lx200Latitude,
            longitude: locationManager.lx200Longitude
        ) { locationSuccess in
            guard locationSuccess else {
                setupFeedback = .failure
                Task { try? await Task.sleep(for: .seconds(3)); setupFeedback = .idle }
                return
            }
            telescope.setSiteDateTime(utcOffsetHours: utcOffset) { dateTimeSuccess in
                setupFeedback = dateTimeSuccess ? .success : .failure
                if dateTimeSuccess { telescope.querySiteInfo() }
                Task { try? await Task.sleep(for: .seconds(3)); setupFeedback = .idle }
            }
        }
    }

    // MARK: - Comparison Table Helpers

    private var compareHeader: some View {
        HStack(spacing: 0) {
            Text("")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Mount")
                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
            Text("Phone/iPad")
                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func compareRow(_ label: String, mount: String, phone: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(mount)
                .font(.system(.subheadline, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .center)
                .foregroundStyle(telescope.isConnected ? Color.primary : Color.secondary)
            Text(phone)
                .font(.system(.subheadline, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .center)
                .foregroundStyle(Color.astroAmber)
        }
    }

    // MARK: - Phone Formatting Helpers

    private var phoneDateFormatted: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM/dd/yy"
        return fmt.string(from: now)
    }

    private var phoneTimeFormatted: String {
        let fmt = DateFormatter()
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: now)
    }

    private var phoneUTCOffsetFormatted: String {
        let sign = utcOffset >= 0 ? "+" : "-"
        let h    = Int(abs(utcOffset))
        let frac = Int((abs(utcOffset) - Double(h)) * 10.0)
        return frac == 0
            ? String(format: "%@%02d", sign, h)
            : String(format: "%@%02d.%d", sign, h, frac)
    }

    // MARK: - Shared Helpers

    @ViewBuilder
    private func feedbackRow(state: FeedbackState) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .sending:
                ProgressView().controlSize(.small)
                Text("Sending…").foregroundStyle(.secondary)
            case .success:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Sent successfully").foregroundStyle(.secondary)
            case .failure:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.astroRed)
                Text("Failed — check connection").foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        }
        .font(.caption)
    }

    private var canAlign: Bool {
        telescope.isConnected && locationManager.locationReceived
    }

    private var utcOffsetLabel: String {
        let sign = utcOffset >= 0 ? "+" : ""
        let h    = Int(utcOffset)
        let frac = utcOffset - Double(h)
        return frac == 0 ? "\(sign)\(h)h" : "\(sign)\(h).5h"
    }
}

// MARK: - WiFi Connect Sheet

struct WiFiConnectView: View {
    @EnvironmentObject var telescope: OnStepManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Host") {
                        TextField("IP Address", text: $telescope.wifiHost)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    LabeledContent("Port") {
                        TextField("Port", value: $telescope.wifiPort, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("WiFi Settings")
                } footer: {
                    Text("Default: host 192.168.0.1 port 9998")
                }

                Section {
                    Button {
                        telescope.saveSettings()
                        if telescope.isConnected { telescope.disconnect() }
                        telescope.connect()
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Connect to WiFi", systemImage: "wifi")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .foregroundStyle(Color.astroRed)
                }
            }
            .navigationTitle("WiFi Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Bluetooth Scan Sheet

struct BluetoothScanView: View {
    @EnvironmentObject var bluetooth: BluetoothManager
    let onSelect: (CBPeripheral) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.astroAmber)
                            .padding(.top, 2)
                        Text("Your OnStep controller must have the **Bluetooth Low Energy (BLE)** plugin installed. iOS cannot connect to Classic Bluetooth devices.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if bluetooth.isScanning && bluetooth.discoveredDevices.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Scanning for devices…").foregroundStyle(.secondary)
                    }
                }

                ForEach(bluetooth.discoveredDevices, id: \.identifier) { peripheral in
                    Button {
                        onSelect(peripheral)
                    } label: {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.blue)
                            Text(peripheral.name ?? peripheral.identifier.uuidString)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(bluetooth.isScanning ? "Stop" : "Scan") {
                        bluetooth.isScanning ? bluetooth.stopScanning() : bluetooth.startScanning()
                    }
                }
            }
            .onAppear    { bluetooth.startScanning() }
            .onDisappear { bluetooth.stopScanning()  }
        }
    }
}
