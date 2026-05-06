import SwiftUI

struct GoToView: View {
    @EnvironmentObject var telescope:       OnStepManager
    @EnvironmentObject var locationManager: LocationManager
    @Environment(AppState.self) var appState
    @State private var targetRA   = ""
    @State private var targetDec  = ""
    @State private var targetName = ""
    @State private var isSlewing  = false
    @State private var alertMessage = ""
    @State private var showAlert    = false
    @State private var searchText   = ""
    @State private var selectedType: SkyObjectType? = nil
    @FocusState private var focusedField: Field?

    enum Field { case ra, dec }

    private var canSlew: Bool {
        telescope.isConnected && !targetRA.isEmpty && !targetDec.isEmpty && !isSlewing
    }

    private var shouldShowList: Bool {
        selectedType != nil || searchText.count >= 3
    }

    private var filteredObjects: [SkyObject] {
        guard shouldShowList else { return [] }

        var pool = SkyCatalog.all
        pool = pool.filter { $0.type != .star || $0.magnitude <= 4.0 }

        // Exclude objects below 10° when a GPS fix is available.
        if locationManager.locationReceived {
            let lat = locationManager.latitude
            let lon = locationManager.longitude
            let now = Date()
            pool = pool.filter { altitudeDeg(ra: $0.ra, dec: $0.dec,
                                             lat: lat, lon: lon, date: now) >= 10.0 }
        }

        if let type = selectedType {
            pool = pool.filter { $0.type == type }
        }

        if searchText.count >= 3 {
            let q = searchText.lowercased()
            pool = pool.filter {
                $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q)
            }
        }

        return pool
    }

    private static let typeOrder: [SkyObjectType] = [
        .star, .openCluster, .globularCluster, .nebula, .planetaryNebula, .galaxy
    ]

    private var objectsByType: [(SkyObjectType, [SkyObject])] {
        if let type = selectedType {
            let sorted = filteredObjects.sorted { $0.magnitude < $1.magnitude }
            return sorted.isEmpty ? [] : [(type, sorted)]
        }
        return Self.typeOrder.compactMap { type in
            let objects = filteredObjects.filter { $0.type == type }
                                         .sorted { $0.magnitude < $1.magnitude }
            return objects.isEmpty ? nil : (type, objects)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Coordinate entry ──────────────────────────────────────────
                Section("Target Coordinates") {
                    if !targetName.isEmpty {
                        LabeledContent("Object") {
                            Text(targetName)
                                .foregroundStyle(Color.astroAmber)
                                .fontWeight(.semibold)
                        }
                    }
                    HStack {
                        Text("RA").frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
                        TextField("HH:MM:SS", text: $targetRA)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focusedField, equals: .ra)
                    }
                    HStack {
                        Text("Dec").frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
                        TextField("±DD:MM:SS", text: $targetDec)
                            .font(.system(.body, design: .monospaced))
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focusedField, equals: .dec)
                    }
                    Button("Use Current Position") {
                        targetRA   = telescope.mountStatus.ra
                        targetDec  = telescope.mountStatus.dec
                        targetName = ""
                    }
                    .disabled(!telescope.isConnected)

                    Button {
                        focusedField = nil
                        slewToTarget()
                    } label: {
                        HStack {
                            Spacer()
                            if isSlewing { ProgressView().padding(.trailing, 6) }
                            Label(isSlewing ? "Slewing…" : "GoTo",
                                  systemImage: "location.north.line.fill")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .foregroundStyle(canSlew ? Color.astroRed : Color.secondary)
                        .opacity(canSlew ? 1.0 : 0.5)
                    }
                    .disabled(!canSlew)
                }

                // ── Search + filter ───────────────────────────────────────────
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search objects…", text: $searchText)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Self.typeOrder, id: \.rawValue) { type in
                                categoryChip(type)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(.init())
                    .listRowBackground(Color.clear)
                } header: {
                    Text("Search & Filter")
                } footer: {
                    if locationManager.locationReceived {
                        Text("Showing objects currently above 10° at your location.")
                    } else {
                        Text("Enable location access to filter by visibility.")
                    }
                }

                // ── Results ───────────────────────────────────────────────────
                if shouldShowList {
                    ForEach(objectsByType, id: \.0.rawValue) { (type, objects) in
                        Section(selectedType == nil ? type.displayName : "") {
                            ForEach(objects) { obj in
                                objectRow(obj)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("Select a category above or type at least 3 characters to search.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("GoTo")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    trackingIndicator
                }
            }
            .alert("GoTo Error", isPresented: $showAlert) {
                Button("OK") {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    // MARK: - Tracking Indicator

    private var trackingIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: telescope.isConnected && telescope.mountStatus.isTracking
                  ? "circle.fill" : "circle.slash")
                .font(.system(size: 10))
            Text(telescope.isConnected && telescope.mountStatus.isTracking
                 ? "Tracking" : "No Track")
                .font(.caption2).fontWeight(.semibold)
        }
        .foregroundStyle(telescope.isConnected && telescope.mountStatus.isTracking
                         ? Color.astroAmber : Color.secondary)
    }

    // MARK: - Object Row

    @ViewBuilder
    private func objectRow(_ obj: SkyObject) -> some View {
        Button {
            focusedField = nil
            targetName = obj.name
            targetRA   = formatRA(obj.ra)
            targetDec  = formatDec(obj.dec)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(obj.name).foregroundStyle(Color.primary)
                    Text(String(format: "mag %.1f", obj.magnitude))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "scope")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Altitude Calculation

    private func altitudeDeg(ra: Double, dec: Double,
                              lat: Double, lon: Double, date: Date) -> Double {
        let jd = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        let d  = jd - 2451545.0
        let gmst = (280.46061837 + 360.98564736629 * d)
            .truncatingRemainder(dividingBy: 360.0)
        var lst = ((gmst + lon) / 15.0).truncatingRemainder(dividingBy: 24.0)
        if lst < 0 { lst += 24.0 }
        let haRad  = (lst - ra) * 15.0 * .pi / 180.0
        let latRad = lat * .pi / 180.0
        let decRad = dec * .pi / 180.0
        let sinAlt = sin(latRad) * sin(decRad) + cos(latRad) * cos(decRad) * cos(haRad)
        return asin(max(-1.0, min(1.0, sinAlt))) * 180.0 / .pi
    }

    // MARK: - Category Chip

    @ViewBuilder
    private func categoryChip(_ type: SkyObjectType) -> some View {
        let selected = selectedType == type
        Button {
            selectedType = selected ? nil : type
        } label: {
            Text(chipLabel(type))
                .font(.caption).fontWeight(.semibold)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? Color.astroRed : Color.secondary.opacity(0.2))
                .foregroundStyle(selected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(_ type: SkyObjectType) -> String {
        switch type {
        case .star:              return "Bright Stars"
        case .openCluster:       return "Open Cluster"
        case .globularCluster:   return "Glob Cluster"
        case .nebula:            return "Nebula"
        case .galaxy:            return "Galaxy"
        case .planetaryNebula:   return "Planetary Neb"
        }
    }

    // MARK: - Slew

    private func slewToTarget() {
        isSlewing = true
        telescope.slewToTarget(ra: targetRA, dec: targetDec) { error in
            isSlewing = false
            if let error {
                alertMessage = error
                showAlert    = true
            } else {
                // Switch to Sky tab so the user can watch the mount move.
                appState.selectedTab = AppState.tabSky
            }
        }
    }

    // MARK: - Coordinate Formatting

    private func formatRA(_ hours: Double) -> String {
        let h     = hours < 0 ? hours + 24.0 : hours
        let total = Int((h * 3600.0).rounded())
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func formatDec(_ degrees: Double) -> String {
        let sign  = degrees >= 0 ? "+" : "-"
        let total = Int((abs(degrees) * 3600.0).rounded())
        return String(format: "%@%02d*%02d:%02d", sign, total / 3600, (total % 3600) / 60, total % 60)
    }
}
