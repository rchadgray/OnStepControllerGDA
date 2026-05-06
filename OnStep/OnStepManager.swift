import Foundation
import Network
import SwiftUI
import Combine

// ═════════════════════════════════════════════════════════════════════════════
// OnStepManager — complete communication layer for an OnStep telescope controller
//
// OnStep is an open-source GoTo mount controller that speaks the Meade LX200
// ASCII protocol over TCP (WiFi) or BLE (Bluetooth).
//
// Every command sent to the mount follows the same pattern:
//   1. App sends a command string ending with '#'  e.g.  ":GR#"
//   2. Mount responds with a string ending with '#' e.g.  "05:34:12#"
//      (or a bare "0"/"1" with no '#' for some set commands)
//
// Because TCP is a byte stream, multiple commands can be in-flight simultaneously
// and their responses can arrive in any order — or even in the same TCP packet.
// To prevent this, all commands go through a SERIAL QUEUE: only one command is
// in-flight at a time. The next command is not sent until the current one either
// receives a response or times out after 3 seconds.
// ═════════════════════════════════════════════════════════════════════════════


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Enums & Models
// ─────────────────────────────────────────────────────────────────────────────

// How fast the mount moves when the user holds down an arrow button.
// The rate is set with :R_# before the move, not during it.
enum SlewRate: String, CaseIterable, Identifiable, Equatable {
    case guide  = "Guide"   // slowest  — for autoguider corrections (~1x sidereal)
    case center = "Center"  // slow     — for centering in the eyepiece
    case find   = "Find"    // medium   — for searching a field
    case slew   = "Slew"    // fastest  — for moving between targets

    var id: String { rawValue }

    // The LX200 command that sets this rate on the mount.
    var command: String {
        switch self {
        case .guide:  return ":RG#"
        case .center: return ":RC#"
        case .find:   return ":RM#"
        case .slew:   return ":RS#"
        }
    }

    // SF symbol name for the rate picker buttons.
    var icon: String {
        switch self {
        case .guide:  return "tortoise"
        case .center: return "scope"
        case .find:   return "binoculars"
        case .slew:   return "hare"
        }
    }
}

// How fast the mount moves to compensate for Earth's rotation.
// Sidereal tracks stars; Lunar is ~2.7% slower; Solar is between the two.
enum TrackingRate: String, CaseIterable, Identifiable {
    case sidereal = "Sidereal"
    case lunar    = "Lunar"
    case solar    = "Solar"

    var id: String { rawValue }

    var command: String {
        switch self {
        case .sidereal: return ":TQ#"
        case .lunar:    return ":TL#"
        case .solar:    return ":TS#"
        }
    }
}

// The physical link between the app and OnStep.
// WiFi uses a direct TCP socket (usually port 9998).
// Bluetooth uses BLE UART (Nordic UART Service).
enum ConnectionType: String, CaseIterable, Identifiable {
    case wifi      = "WiFi"
    case bluetooth = "Bluetooth"
    var id: String { rawValue }
}

// ─────────────────────────────────────────────────────────────────────────────
// MountStatus — a value-type snapshot of everything we know about the mount.
//
// OnStepManager updates this struct (published on the main thread) roughly
// once per second. SwiftUI views observe it via @Published and re-render
// automatically when anything changes.
// ─────────────────────────────────────────────────────────────────────────────
struct MountStatus {

    // ── Live pointing position ────────────────────────────────────────────────
    // Updated every second by the background polling loop.
    var ra:           String = "--:--:--"      // Right Ascension  — :GR# → "HH:MM:SS"
    var dec:          String = "---°--'--\""   // Declination      — :GD# → "±DD°MM'SS\""
    var alt:          String = "--°--'"         // Altitude         — :GA# → "DD°MM'"
    var az:           String = "---°--'"        // Azimuth          — :GZ# → "DDD°MM'"
    var siderealTime: String = "--:--:--"      // Local Sidereal   — :GS# → "HH:MM:SS"

    // ── Mount motion state ────────────────────────────────────────────────────
    var isTracking: Bool         = false        // 'n' absent in :GU# → tracking on
    var isSlewing:  Bool         = false        // reserved (not yet used — see isMoving)
    var isParked:   Bool         = false        // 'P' present in :GU# without 'p'

    // ── Rate settings ─────────────────────────────────────────────────────────
    var slewRate:     SlewRate     = .guide      // current arrow-button speed
    var trackingRate: TrackingRate = .sidereal   // current tracking rate

    // ── Firmware info ─────────────────────────────────────────────────────────
    var firmwareName:    String = "OnStep"       // :GVP# → e.g. "OnStep"
    var firmwareVersion: String = "--"           // :GVN# → e.g. "10.24k"

    // ── Site setup comparison values ─────────────────────────────────────────
    // Read from the mount on connect and after each "Send All" so the Setup
    // screen can compare what the mount has vs. what the phone reports.
    var siteLatitude:  String = "--"   // :Gt# → "+41*01:30"
    var siteLongitude: String = "--"   // :Gg# → "+081*43:48"
    var siteDate:      String = "--"   // :GC# → "04/26/26"
    var siteTime:      String = "--"   // :GL# → "21:30:15"
    var siteUTCOffset: String = "--"   // :GG# → "+04" or "+04.5"

    // ── Polar alignment errors ────────────────────────────────────────────────
    // Only meaningful after a star alignment. Values come from extended commands
    // :GX02# (altitude axis error) and :GX03# (azimuth axis error).
    // Goal: adjust the mount's physical alt/az bolts to bring both toward 0'.
    var polarAltError: String = "--"
    var polarAzError:  String = "--"

    // ── GoTo slew state ───────────────────────────────────────────────────────
    // True from the moment :MS# confirms the slew started ("0" response) until
    // :D# returns an empty string (slew complete) or the 120-second hard cap fires.
    // Views read this to disable GoTo / Accept buttons while the mount is moving.
    var isMoving: Bool = false

    // ── Raw :GU# status string ────────────────────────────────────────────────
    // The full unprocessed status string from :GU# — updated every poll cycle.
    // HomingView uses this to decode individual flags such as:
    //   'h' — home search actively running
    //   'H' — at home position
    //   'N' — not slewing (absence means GoTo in progress)
    //   'P' — parked
    //   'p' — parking in progress
    //   'n' — not tracking
    var rawStatus: String = ""

    // ── Homing state ──────────────────────────────────────────────────────────
    // isHoming is true while :hC# is executing. The mount physically moves to
    // its home switch. isAtHome is true only after the mount successfully reaches
    // home — it is NOT restored from UserDefaults on reconnect because the mount
    // may have been moved since the last session.
    var isHoming:     Bool   = false
    var isAtHome:     Bool   = false
    var homingStatus: String = ""   // human-readable progress shown in HomingView

    // ── Slew altitude limits ──────────────────────────────────────────────────
    // Queried once on connect via :Gh# / :Go#. nil until first successful read.
    var horizonLimit:  Double? = nil   // minimum altitude in degrees (:Gh#)
    var overheadLimit: Double? = nil   // maximum altitude in degrees (:Go#)

    // ── Meridian flip limits ──────────────────────────────────────────────────
    // Both values are in minutes of sidereal time past the meridian (÷4 → degrees of HA).
    // Queried once on connect. nil until the mount responds.
    //
    // East pier (:GXE9#): mount on east pier tracks this far WEST of meridian (HA > 0).
    // West pier (:GXEA#): mount on west pier tracks this far EAST of meridian (HA < 0).
    var meridianLimitEastPier: Double? = nil   // minutes past meridian, east pier side
    var meridianLimitWestPier: Double? = nil   // minutes past meridian, west pier side

    // ── Alignment session state ───────────────────────────────────────────────
    // Driven by :A?# which returns a 3-character string "mno":
    //   m = max stars the firmware supports
    //   n = next star number OnStep is waiting for (0 = done)
    //   o = total stars requested for this session
    var alignmentNextStar:   Int = 0
    var alignmentTotalStars: Int = 0

    // True once all alignment stars have been accepted.
    // Condition: total > 0 AND (next == 0 OR next > total).
    var isAligned: Bool {
        alignmentTotalStars > 0 &&
        (alignmentNextStar == 0 || alignmentNextStar > alignmentTotalStars)
    }

    // True when alignment has started but not yet finished.
    var alignmentInProgress: Bool {
        alignmentTotalStars > 0 && !isAligned
    }

    // Human-readable alignment summary for the Setup screen label.
    var alignmentDescription: String {
        guard alignmentTotalStars > 0 else { return "Not aligned" }
        if isAligned { return "\(alignmentTotalStars)-star complete" }
        let accepted = max(0, alignmentNextStar - 1)
        return "\(accepted) of \(alignmentTotalStars) accepted"
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Transport Protocol
//
// A protocol so the command queue can send bytes without caring whether the
// underlying connection is WiFi or Bluetooth. Both transports deliver bytes to
// the same handleReceivedData() callback in OnStepManager.
// ─────────────────────────────────────────────────────────────────────────────
protocol OnStepTransport: AnyObject {
    var isConnected: Bool { get }
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func startReceiving(handler: @escaping (Data) -> Void)
    func disconnect()
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - WiFi Transport
//
// Opens a TCP socket to the OnStep WiFi module (SmartWebServer or built-in).
// Default host/port: 192.168.0.1:9998 (configurable in Settings).
// ─────────────────────────────────────────────────────────────────────────────
final class WiFiTransport: OnStepTransport {
    private var connection: NWConnection?
    private(set) var isConnected = false
    private var receiveHandler: ((Data) -> Void)?

    func connect(host: String, port: UInt16, onStateChange: @escaping (Bool) -> Void) {
        let hostEndpoint = NWEndpoint.Host(host)
        guard let portEndpoint = NWEndpoint.Port(rawValue: port) else { return }
        connection = NWConnection(host: hostEndpoint, port: portEndpoint, using: .tcp)
        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    // TCP connection established — start the receive loop.
                    self?.isConnected = true
                    onStateChange(true)
                    self?.receiveLoop()
                case .failed, .cancelled:
                    self?.isConnected = false
                    onStateChange(false)
                default:
                    break
                }
            }
        }
        connection?.start(queue: .global(qos: .utility))
    }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection?.send(content: data, completion: .contentProcessed { completion($0) })
    }

    func startReceiving(handler: @escaping (Data) -> Void) {
        receiveHandler = handler
    }

    func disconnect() {
        connection?.cancel()
        connection  = nil
        isConnected = false
    }

    // Recursively waits for the next chunk of bytes from the mount.
    // Each call schedules itself again so data flows continuously until
    // the connection closes or produces an error.
    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            if error != nil || isComplete { return }   // connection ended — stop looping
            if let data, !data.isEmpty { self?.receiveHandler?(data) }
            self?.receiveLoop()   // schedule the next read
        }
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - OnStep Manager
// ─────────────────────────────────────────────────────────────────────────────
final class OnStepManager: ObservableObject {

    // ── Published state (drives SwiftUI views) ────────────────────────────────
    @Published var isConnected:    Bool           = false
    @Published var mountStatus:    MountStatus    = MountStatus()
    @Published var connectionType: ConnectionType = .wifi
    @Published var wifiHost:       String
    @Published var wifiPort:       Int

    // ── Transport layer ───────────────────────────────────────────────────────
    // nil when disconnected. Replaced on each new connect attempt.
    private var transport: OnStepTransport?

    // ── Serial command queue ──────────────────────────────────────────────────
    // All queue variables live exclusively on serialQueue (a serial DispatchQueue)
    // to prevent data races. Never read or write them from another queue.

    // The dedicated serial queue for command processing.
    private let serialQueue = DispatchQueue(label: "com.onstep.commands", qos: .utility)

    // Pending commands waiting to be sent. Each entry carries the command string,
    // whether to wait for a response, and an optional completion callback.
    private var commandQueue: [(cmd: String, expectsResponse: Bool, completion: ((String) -> Void)?)] = []

    // True while a command has been sent and we're waiting for the mount's response.
    // The next command will not be sent until this is false.
    private var isWaitingForResponse = false

    // Holds the completion block for the currently in-flight command so it can
    // be called when the response arrives (or the timeout fires).
    private var pendingCompletion: ((String) -> Void)?

    // Accumulates raw bytes as they arrive from the mount.
    // OnStep may send responses in multiple TCP packets, so we buffer them here
    // and parse complete '#'-terminated messages as they come in.
    private var receiveBuffer = ""

    // A DispatchWorkItem scheduled to fire after commandTimeout seconds.
    // Cancelled immediately if the mount responds in time.
    private var timeoutWorkItem: DispatchWorkItem?

    // Background Task that polls coordinates once per second.
    private var pollingTask: Task<Void, Never>?

    // Background Task that polls :GU# once per second during a home search.
    private var homingPollTask: Task<Void, Never>?

    // ── Polar error support detection ─────────────────────────────────────────
    // :GX02# and :GX03# are extended commands not available on older firmware.
    // After 2 consecutive timeouts we stop calling them so they don't stall the queue.
    private var polarErrorSupported    = true
    private var polarErrorTimeoutCount = 0

    // ── Slew completion tracking ──────────────────────────────────────────────
    // Recorded when :MS# confirms the slew started. Used by the :D# completion
    // check to enforce a 300-second hard cap so isMoving can never get stuck.
    // The :D# poll fires the moment the slew completes; the cap is only a fallback.
    private var slewStartTime = Date.now

    // ── Two-phase homing detection ────────────────────────────────────────────
    // When the user taps "Find Home", we send :hC# and then poll :GU# every second.
    // :GU# contains the flag 'h' while the home search is ACTIVELY running, and
    // 'H' once the mount reaches home. The problem: some firmware already has 'H'
    // in the status string before homing starts, so we'd false-positive immediately.
    //
    // Solution — two phases:
    //   Phase 1: wait until 'h' appears  (home search has started)
    //   Phase 2: wait until 'h' disappears  (home search finished)
    // homingDidActivate tracks whether we've seen Phase 1 yet.
    private var homingDidActivate = false

    // ── Debug logging ─────────────────────────────────────────────────────────
    #if DEBUG
    static var debugLogging = false
    #else
    static var debugLogging = false
    #endif

    // Internal helper — all log output goes through here so the flag is honoured.
    private func log(_ message: String) {
        guard Self.debugLogging else { return }
        print("[OnStep] \(message)")
    }

    // ── Timeout ───────────────────────────────────────────────────────────────
    // If the mount doesn't respond within 3 seconds the command is abandoned
    // and the queue moves on. This prevents a single bad command from freezing
    // the whole app forever.
    private let commandTimeout: TimeInterval = 3.0


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Init
    // ─────────────────────────────────────────────────────────────────────────

    init() {
        // Restore WiFi settings saved by the user in a previous session.
        let d    = UserDefaults.standard
        wifiHost = d.string(forKey: "wifiHost") ?? "192.168.0.1"
        let p    = d.integer(forKey: "wifiPort")
        wifiPort = p > 0 ? p : 9998
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Connection
    // ─────────────────────────────────────────────────────────────────────────

    // Entry point — called when the user taps "Connect" in the Setup screen.
    func connect() {
        guard !isConnected else { return }
        switch connectionType {
        case .wifi:      connectWiFi(host: wifiHost, port: wifiPort)
        case .bluetooth: break   // BLE is started externally via connectBluetooth()
        }
    }

    // Opens a TCP socket to the specified host and port.
    // The WiFiTransport calls onStateChange(true) once the socket is ready.
    func connectWiFi(host: String, port: Int) {
        let portU16 = UInt16(clamping: max(1, port))
        let wifi    = WiFiTransport()
        transport   = wifi
        // Route all incoming bytes to our response parser.
        wifi.startReceiving { [weak self] data in self?.handleReceivedData(data) }
        wifi.connect(host: host, port: portU16) { [weak self] connected in
            DispatchQueue.main.async {
                self?.isConnected = connected
                if connected { self?.onConnected() } else { self?.onDisconnected() }
            }
        }
    }

    // Called by SetupView after the user selects and pairs a BLE peripheral.
    // The BluetoothManager creates the transport and hands it here.
    func connectBluetooth(transport: OnStepTransport) {
        self.transport = transport
        transport.startReceiving { [weak self] data in self?.handleReceivedData(data) }
        DispatchQueue.main.async {
            self.isConnected = true
            self.onConnected()
        }
    }

    // Tears down the connection cleanly:
    //   1. Cancels the background polling task.
    //   2. Closes the transport socket.
    //   3. Drains the command queue on its own queue (thread-safe).
    //   4. Resets all published state so the UI goes blank.
    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        transport?.disconnect()
        transport   = nil
        serialQueue.async { [weak self] in
            self?.commandQueue.removeAll()
            self?.isWaitingForResponse = false
            self?.pendingCompletion    = nil
            self?.receiveBuffer        = ""
            self?.timeoutWorkItem?.cancel()
            self?.timeoutWorkItem = nil
        }
        DispatchQueue.main.async {
            self.isConnected  = false
            self.mountStatus  = MountStatus()   // clears all displayed values
        }
    }

    // Runs once immediately after any successful connection (WiFi or BT).
    // Reads firmware info, refreshes site data and mount flags, then starts
    // the 1-second polling loop.
    private func onConnected() {
        // isAtHome always starts false — we cannot trust persisted state because
        // the mount may have been physically moved since the last session.
        mountStatus.isAtHome = false

        // Read firmware name and version for display in the Status screen.
        query(":GVP#") { [weak self] v in DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.firmwareName    = v } } }
        query(":GVN#") { [weak self] v in DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.firmwareVersion = v } } }

        querySiteInfo()      // latitude, longitude, date, time, UTC offset, alignment
        queryMountFlags()    // park / tracking state from :GU#
        queryMountLimits()   // horizon and overhead slew limits
        startPolling()       // begin 1-second coordinate updates
    }

    // Runs when the connection drops (error or manual disconnect).
    // Cancels all background tasks and resets the polar error support flag.
    private func onDisconnected() {
        pollingTask?.cancel();    pollingTask    = nil
        homingPollTask?.cancel(); homingPollTask = nil
        DispatchQueue.main.async {
            self.mountStatus                = MountStatus()
            self.polarErrorSupported        = true
            self.polarErrorTimeoutCount     = 0
        }
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Status Queries
    // ─────────────────────────────────────────────────────────────────────────

    // Reads the comprehensive :GU# status string and updates park + tracking flags.
    //
    // :GU# returns a multi-flag string like "NnP" where each letter signals a state:
    //   'N' = not slewing (GoTo finished or never started)
    //   'n' = not tracking
    //   'P' = parked
    //   'p' = parking in progress
    //   'h' = home search running
    //   'H' = at home position
    //
    // NOTE: isAtHome and isHoming are intentionally NOT set here — they are owned
    // by the dedicated homing poll task to prevent false positives.
    func queryMountFlags() {
        query(":GU#") { [weak self] status in
            DispatchQueue.main.async {
                guard let self, !status.isEmpty else { return }
                self.mountStatus.isParked   = status.contains("P") && !status.contains("p")
                self.mountStatus.isTracking = !status.contains("n")
                self.mountStatus.rawStatus  = status
                self.log(":GU# → '\(status)'  tracking=\(self.mountStatus.isTracking)  parked=\(self.mountStatus.isParked)")
            }
        }
    }

    // Reads the mount's stored site location, date/time, and alignment state.
    // Called on connect and after each "Send All" so the Setup comparison table
    // shows what the mount actually has (not what we sent).
    func querySiteInfo() {
        query(":Gt#") { [weak self] v in DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.siteLatitude  = v } } }
        query(":Gg#") { [weak self] v in DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.siteLongitude = v } } }
        query(":GC#") { [weak self] v in DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.siteDate      = v } } }
        query(":GL#") { [weak self] v in DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.siteTime      = v } } }
        query(":GG#") { [weak self] v in DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.siteUTCOffset = Self.normalizeUTCOffset(v) } } }

        // :A?# returns "mno" — max/next/total alignment stars.
        // We parse index 1 (nextStar) and index 2 (totalStars) to derive alignment state.
        query(":A?#") { [weak self] v in
            DispatchQueue.main.async {
                guard let self else { return }
                self.log("querySiteInfo :A?# → '\(v)'")
                let chars = Array(v)
                guard chars.count >= 3,
                      let next  = Int(String(chars[1])),
                      let total = Int(String(chars[2])) else { return }
                self.mountStatus.alignmentNextStar   = next
                self.mountStatus.alignmentTotalStars = total
                self.log("alignment: next=\(next) total=\(total) aligned=\(self.mountStatus.isAligned)")
            }
        }
        queryMountFlags()
    }

    // Queries the mount's configured altitude limits once on connect.
    // :Gh# — minimum altitude (horizon limit)   e.g. "+10" or "-05"
    // :Go# — maximum altitude (overhead limit)  e.g. "87"
    // Requery with queryMountLimits() any time the user may have changed them.
    func queryMountLimits() {
        query(":Gh#") { [weak self] v in
            DispatchQueue.main.async {
                if let deg = Self.parseLimitDegrees(v) {
                    self?.mountStatus.horizonLimit = deg
                }
            }
        }
        query(":Go#") { [weak self] v in
            DispatchQueue.main.async {
                if let deg = Self.parseLimitDegrees(v) {
                    self?.mountStatus.overheadLimit = deg
                }
            }
        }
        query(":GXE9#") { [weak self] v in
            DispatchQueue.main.async {
                if let min = Self.parseLimitDegrees(v) {
                    self?.mountStatus.meridianLimitEastPier = min
                }
            }
        }
        query(":GXEA#") { [weak self] v in
            DispatchQueue.main.async {
                if let min = Self.parseLimitDegrees(v) {
                    self?.mountStatus.meridianLimitWestPier = min
                }
            }
        }
    }

    private static func parseLimitDegrees(_ s: String) -> Double? {
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                     .replacingOccurrences(of: "*", with: "")
                     .replacingOccurrences(of: "°", with: "")
        return Double(clean)
    }

    // Reads the polar alignment residual errors reported by OnStep after a star
    // alignment has been completed.
    //
    // :GX02# → altitude axis error  (arc-minutes)
    // :GX03# → azimuth axis error   (arc-minutes)
    //
    // These are extended commands not available on all firmware. If they time out
    // twice in a row we set polarErrorSupported = false and skip them forever so
    // the queue isn't stalled on every poll cycle.
    //
    // Pass forced: true right after completing alignment to reset the timeout
    // counter and force a fresh read even if previous attempts failed.
    func queryPolarError(forced: Bool = false) {
        if forced {
            polarErrorTimeoutCount = 0
            polarErrorSupported    = true
        }
        guard polarErrorSupported else { return }

        query(":GX02#") { [weak self] v in
            DispatchQueue.main.async {
                guard let self else { return }
                if v.isEmpty {
                    // Timed out — count it. After 2 timeouts, stop trying.
                    self.polarErrorTimeoutCount += 1
                    if self.polarErrorTimeoutCount >= 2 { self.polarErrorSupported = false }
                } else {
                    self.polarErrorTimeoutCount    = 0
                    self.mountStatus.polarAltError = v
                }
            }
        }
        query(":GX03#") { [weak self] v in
            DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.polarAzError = v } }
        }
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Command Queue
    //
    // All communication goes through these three functions:
    //   sendCommand()  — fire-and-forget (no response expected)
    //   query()        — send and receive one response
    //   enqueue()      — internal: adds to queue and starts processing if idle
    // ─────────────────────────────────────────────────────────────────────────

    // Sends a command and ignores any response.
    // Use for motion commands like :Mn# (move north), :Q# (stop), :hP# (park).
    // These commands do not return data so there is nothing to wait for.
    func sendCommand(_ command: String) {
        serialQueue.async { [weak self] in
            self?.enqueue(cmd: command, expectsResponse: false, completion: nil)
        }
    }

    // Sends a command and delivers the mount's response to the completion block.
    // Use for any command that returns data: coordinates, status strings,
    // set-command acknowledgements ("0"/"1"), etc.
    // Completion is always called on the MAIN thread.
    func query(_ command: String, completion: @escaping (String) -> Void) {
        serialQueue.async { [weak self] in
            self?.enqueue(cmd: command, expectsResponse: true, completion: completion)
        }
    }

    // Low-level enqueue — only called from within the serialQueue.
    // Appends the command and starts processing immediately if the queue is idle.
    private func enqueue(cmd: String, expectsResponse: Bool, completion: ((String) -> Void)?) {
        commandQueue.append((cmd, expectsResponse, completion))
        if !isWaitingForResponse { processNext() }
    }

    // Dequeues and sends the next command. Schedules a timeout for commands that
    // expect a response. For fire-and-forget commands, moves to the next item
    // immediately after the send completes (no waiting).
    private func processNext() {
        guard !commandQueue.isEmpty, !isWaitingForResponse else { return }
        let item = commandQueue.removeFirst()

        // All LX200 commands must end with '#'. Add it if somehow missing.
        let cmdStr = item.cmd.hasSuffix("#") ? item.cmd : "\(item.cmd)#"
        guard let data = cmdStr.data(using: .utf8) else { processNext(); return }

        if item.expectsResponse {
            // Block the queue until we get a response (or the timeout fires).
            isWaitingForResponse = true
            pendingCompletion    = item.completion

            // 3-second safety timeout — if the mount doesn't respond, drop this
            // command and continue so the queue doesn't freeze permanently.
            let work = DispatchWorkItem { [weak self] in
                self?.serialQueue.async { self?.completeCurrentCommand(response: "") }
            }
            timeoutWorkItem = work
            DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: work)
        }

        transport?.send(data) { [weak self] error in
            if let error {
                self?.log("send error: \(error)")
                if item.expectsResponse {
                    // Send failed — complete with empty response so the queue moves on.
                    self?.serialQueue.async { self?.completeCurrentCommand(response: "") }
                }
                return
            }
            // Fire-and-forget: advance the queue as soon as the bytes are sent.
            if !item.expectsResponse {
                self?.serialQueue.async { self?.processNext() }
            }
        }
    }

    // Called whenever new bytes arrive from the mount (on serialQueue via the transport).
    // Appends bytes to the receive buffer and extracts complete responses.
    //
    // OnStep uses two response formats:
    //   Format A: '#'-terminated  — "HH:MM:SS#",  "NnP#",  "0#",  "1#"
    //   Format B: bare single digit — "0",  "1",  "2"  (some firmware omits '#')
    //
    // Format A is parsed first. Format B is a fallback for the single-digit
    // set-command acks and :MS# GoTo rejection codes that sometimes arrive bare.
    private func handleReceivedData(_ data: Data) {
        serialQueue.async { [weak self] in
            guard let self else { return }
            guard let str = String(data: data, encoding: .utf8) else { return }
            receiveBuffer += str

            // ── Format A: extract everything up to the first '#' ──────────────
            // There may be more than one complete response in a single packet,
            // so we loop until no more '#' characters remain.
            while let hashIdx = receiveBuffer.firstIndex(of: "#") {
                let response  = String(receiveBuffer[receiveBuffer.startIndex..<hashIdx])
                receiveBuffer = String(receiveBuffer[receiveBuffer.index(after: hashIdx)...])
                if isWaitingForResponse { completeCurrentCommand(response: response) }
            }

            // ── Format B: bare single-digit (no '#' terminator) ───────────────
            // Some firmware returns "0", "1", "2" etc. without a '#' at the end.
            // We only trigger this if the ENTIRE buffer (trimmed) is a single digit
            // in the range 0–6, to avoid accidentally consuming the first character
            // of a longer response that hasn't fully arrived yet.
            if isWaitingForResponse {
                let trimmed = receiveBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count == 1 && trimmed >= "0" && trimmed <= "6" {
                    receiveBuffer = ""
                    completeCurrentCommand(response: trimmed)
                }
            }
        }
    }

    // Finalises the in-flight command: cancels its timeout, calls its completion
    // handler on the main thread, then starts the next queued command.
    // Always called from within serialQueue.
    private func completeCurrentCommand(response: String) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let trimmed    = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let completion = pendingCompletion
        pendingCompletion    = nil
        isWaitingForResponse = false
        if let completion { DispatchQueue.main.async { completion(trimmed) } }
        processNext()   // immediately start the next queued command
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Background Polling
    // ─────────────────────────────────────────────────────────────────────────

    // Starts a Swift Task that runs pollCoordinates() every second.
    // The Task is cancelled when the user disconnects (or the app goes to another tab).
    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollCoordinates()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // Enqueues one full set of coordinate + status queries.
    //
    // The guard at the top skips the cycle if the queue still has work from the
    // previous second — this prevents the queue from growing unboundedly if the
    // mount is slow or unresponsive.
    //
    // Commands sent each cycle:
    //   :GR#  — Right Ascension
    //   :GD#  — Declination
    //   :GA#  — Altitude
    //   :GZ#  — Azimuth
    //   :GS#  — Local Sidereal Time
    //   :GU#  — Status flags (park, tracking, etc.)
    //   :D#   — GoTo distance remaining (empty when slew is complete)
    private func pollCoordinates() {
        guard isConnected else { return }
        serialQueue.async { [weak self] in
            guard let self, commandQueue.isEmpty, !isWaitingForResponse else { return }

            // Right Ascension — "HH:MM:SS"
            enqueue(cmd: ":GR#", expectsResponse: true) { [weak self] v in
                DispatchQueue.main.async { if let self, !v.isEmpty { self.mountStatus.ra = v } }
            }

            // Declination — "±DD°MM'SS\""
            enqueue(cmd: ":GD#", expectsResponse: true) { [weak self] v in
                DispatchQueue.main.async { if let self, !v.isEmpty { self.mountStatus.dec = v } }
            }

            // Altitude above horizon — "DD°MM'"
            enqueue(cmd: ":GA#", expectsResponse: true) { [weak self] v in
                DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.alt = v } }
            }

            // Azimuth — "DDD°MM'"
            enqueue(cmd: ":GZ#", expectsResponse: true) { [weak self] v in
                DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.az = v } }
            }

            // Local Sidereal Time — "HH:MM:SS"
            enqueue(cmd: ":GS#", expectsResponse: true) { [weak self] v in
                DispatchQueue.main.async { if !v.isEmpty { self?.mountStatus.siderealTime = v } }
            }

            // Comprehensive status flags — multi-character string like "NnP"
            enqueue(cmd: ":GU#", expectsResponse: true) { [weak self] status in
                DispatchQueue.main.async {
                    guard let self, !status.isEmpty else { return }
                    self.mountStatus.isParked  = status.contains("P") && !status.contains("p")
                    self.mountStatus.rawStatus = status
                }
            }

            // GoTo distance remaining.
            // During a slew: returns a bar-graph string like "|||  " (each '|' ≈ 5°).
            // When slew is complete: returns an empty string or a single space.
            //
            // :D# is the authoritative slew detector. If :MS# response was lost in
            // transit (common on WiFi), isMoving may never have been set true via the
            // :MS# callback. We set it here when bars are present so the slew-complete
            // transition (true → false) still fires onChange in the UI layer.
            enqueue(cmd: ":D#", expectsResponse: true) { [weak self] v in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // Bars present — mount is slewing. Set isMoving even if :MS# was missed.
                        if !self.mountStatus.isMoving {
                            self.mountStatus.isMoving = true
                            self.slewStartTime = .now
                        }
                    } else if self.mountStatus.isMoving {
                        // Empty response — slew finished (or 300 s hard cap).
                        let elapsed = Date.now.timeIntervalSince(self.slewStartTime)
                        self.log("GoTo complete — :D# empty after \(Int(elapsed))s")
                        self.mountStatus.isMoving = false
                    }
                    // idle + empty: isMoving already false, no change needed
                }
            }
        }
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Mount Commands
    // ─────────────────────────────────────────────────────────────────────────

    // Sets both the in-memory isAtHome flag and the UserDefaults copy.
    // Called by homing functions to track home state across the session.
    private func setAtHome(_ value: Bool) {
        mountStatus.isAtHome = value
        UserDefaults.standard.set(value, forKey: "mountIsAtHome")
    }

    // ── Manual directional movement ───────────────────────────────────────────
    // The DPadButton (ControlView / AlignmentView) calls moveX() on press and
    // stopX() on release. Each direction is independent so diagonal moves work.
    func moveNorth() { setAtHome(false); sendCommand(":Mn#") }
    func moveSouth() { setAtHome(false); sendCommand(":Ms#") }
    func moveEast()  { setAtHome(false); sendCommand(":Me#") }
    func moveWest()  { setAtHome(false); sendCommand(":Mw#") }

    func stopNorth() { sendCommand(":Qn#") }
    func stopSouth() { sendCommand(":Qs#") }
    func stopEast()  { sendCommand(":Qe#") }
    func stopWest()  { sendCommand(":Qw#") }
    func stopAll()   { sendCommand(":Q#")  }   // halts all axes immediately

    // ── Park / Unpark ─────────────────────────────────────────────────────────
    // :hP# slews to the park position and stops tracking.
    // :hR# resumes from park (re-enables tracking).
    func park()   { sendCommand(":hP#") }
    func unpark() { sendCommand(":hR#") }

    // ── Tracking ──────────────────────────────────────────────────────────────
    func trackingOn()  { sendCommand(":Te#"); DispatchQueue.main.async { self.mountStatus.isTracking = true  } }
    func trackingOff() { sendCommand(":Td#"); DispatchQueue.main.async { self.mountStatus.isTracking = false } }

    // ── Rate setters ──────────────────────────────────────────────────────────
    func setSlewRate(_ rate: SlewRate) {
        sendCommand(rate.command)
        DispatchQueue.main.async { self.mountStatus.slewRate = rate }
    }

    func setTrackingRate(_ rate: TrackingRate) {
        sendCommand(rate.command)
        DispatchQueue.main.async { self.mountStatus.trackingRate = rate }
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - GoTo
    // ─────────────────────────────────────────────────────────────────────────

    // Sends a GoTo command to the mount:
    //   1. :Sr<RA>#  — set target Right Ascension
    //   2. :Sd<Dec># — set target Declination
    //   3. :MS#      — begin slewing to that target
    //
    // IMPORTANT: :Sr# and :Sd# each return a "1" (accepted) or "0" (rejected)
    // response. These MUST be consumed before :MS# is sent, otherwise the
    // lingering "1" in the receive buffer will be mistaken for :MS#'s "1"
    // (below horizon limit). All three commands are queued atomically in one
    // serialQueue.async block to ensure they execute back-to-back.
    //
    // The completion block is called on the MAIN thread with:
    //   nil         — slew accepted, mount is now moving
    //   "error msg" — mount rejected the GoTo (limit, parked, etc.)
    func slewToTarget(ra: String, dec: String, completion: @escaping (String?) -> Void) {
        setAtHome(false)   // any slew moves the mount away from home
        serialQueue.async { [weak self] in
            // Set RA — response "1" (ok) or "0" (error); discard it.
            self?.enqueue(cmd: ":Sr\(ra)#",  expectsResponse: true, completion: { _ in })
            // Set Dec — same.
            self?.enqueue(cmd: ":Sd\(dec)#", expectsResponse: true, completion: { _ in })
            // Issue the GoTo — response "0"=ok, "1"=horizon, "2"=overhead, etc.
            self?.enqueue(cmd: ":MS#",       expectsResponse: true, completion: { [weak self] response in
                DispatchQueue.main.async {
                    let error = OnStepManager.parseSlewError(response)
                    if let error {
                        self?.log("GoTo rejected by mount — \(error) (raw: '\(response.trimmingCharacters(in: .whitespacesAndNewlines))')")
                    } else {
                        self?.log("GoTo accepted — slew started to RA \(ra) Dec \(dec)")
                        self?.mountStatus.isMoving = true
                        self?.slewStartTime        = .now
                    }
                    completion(error)
                }
            })
        }
    }

    // Converts the :MS# response code to a human-readable error string.
    // Returns nil when the response is "0" (slew accepted — no error).
    private static func parseSlewError(_ response: String) -> String? {
        switch response.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "0":  return nil                        // accepted — mount is slewing
        case "1":  return "Below horizon limit"      // target is below the horizon cutoff
        case "2":  return "Above overhead limit"     // target is above the overhead limit
        case "3":  return "Outside mount limits"     // outside the mount's configured slew range
        case "4":  return "Mount is parked"          // must unpark before GoTo
        case "5":  return "Mount is not parked"      // command requires parked state
        case "6":  return "Above overhead limit"     // alternate code for overhead on some firmware
        default:   return response.isEmpty ? "No response from mount" : "GoTo rejected (\(response))"
        }
    }

    // Polls :GU# until the 'N' (not slewing) flag appears, then calls completion.
    // Alternative to :D# polling — currently available but not used in the main flow.
    // 'N' absent = GoTo in progress;  'N' present = not slewing.
    func pollUntilSlewComplete(timeout: TimeInterval = 300, completion: @escaping () -> Void) {
        let deadline = Date.now.addingTimeInterval(timeout)
        func check() {
            guard Date.now < deadline else { DispatchQueue.main.async { completion() }; return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.query(":GU#") { response in
                    if response.contains("N") {
                        DispatchQueue.main.async { completion() }
                    } else {
                        check()
                    }
                }
            }
        }
        check()
    }

    // Sets the target RA/Dec and syncs the pointing model without moving the mount.
    // :CM# tells OnStep "the scope is currently pointing exactly at these coordinates."
    // Used in GoToView when the user wants to correct the pointing model manually.
    // Same :Sr#/:Sd# response-consumption requirement as slewToTarget.
    func syncToTarget(ra: String, dec: String) {
        serialQueue.async { [weak self] in
            self?.enqueue(cmd: ":Sr\(ra)#",  expectsResponse: true, completion: { _ in })
            self?.enqueue(cmd: ":Sd\(dec)#", expectsResponse: true, completion: { _ in })
            self?.enqueue(cmd: ":CM#",       expectsResponse: true, completion: { _ in })
        }
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Homing
    // ─────────────────────────────────────────────────────────────────────────

    // Sends :hC# to start the hardware home search. The mount rotates until it
    // hits its home sensor (Hall-effect or reed switch) on each axis.
    //
    // This does NOT reset the star alignment model — :hC# only affects the
    // physical position, not the pointing math. The user can go home and
    // return without losing their alignment.
    func goHome() {
        homingDidActivate        = false   // reset phase-1 flag for fresh detection
        sendCommand(":hC#")                // tell the mount to start searching
        setAtHome(false)                   // not home yet — will be set when done
        mountStatus.isHoming     = true
        mountStatus.homingStatus = "Homing…"
        beginHomingPoll()                  // start watching :GU# for completion
    }

    // Polls :GU# every second during the home search.
    // Uses two-phase detection to avoid false positives:
    //
    //   Phase 1 — 'h' appears   → the home search is actively running
    //   Phase 2 — 'h' disappears → the home search has finished
    //
    // Without Phase 1 we'd immediately conclude "homing is done" if the mount's
    // :GU# string happened to lack 'h' when we first checked (before the motors
    // even started).
    private func beginHomingPoll() {
        homingPollTask?.cancel()
        homingPollTask = Task { [weak self] in
            var attempts = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                attempts += 1

                self.query(":GU#") { [weak self] status in
                    DispatchQueue.main.async {
                        guard let self, self.mountStatus.isHoming else { return }
                        self.log("homingPoll :GU# → '\(status)' phase1=\(self.homingDidActivate)")

                        if status.contains("h") {
                            // Phase 1 complete — home search is now running.
                            self.homingDidActivate        = true
                            self.mountStatus.homingStatus = "Homing…"
                        } else if self.homingDidActivate {
                            // Phase 2 complete — 'h' was present and is now gone.
                            // The mount has reached its home position.
                            self.mountStatus.homingStatus = "At Home"
                            self.mountStatus.isHoming     = false
                            self.setAtHome(true)
                            self.homingPollTask?.cancel()
                        }
                        // If neither condition is met (Phase 1 not started yet), keep waiting.
                    }
                }

                // Safety cap: give up after 3 minutes (180 × 1 s) to prevent
                // an infinite loop if the home sensor is broken or missing.
                if attempts >= 180 {
                    DispatchQueue.main.async { [weak self] in
                        self?.mountStatus.isHoming = false
                        self?.homingPollTask?.cancel()
                    }
                    return
                }
            }
        }
    }

    // Aborts a running home search. Sends :Q# to stop all motion, then clears
    // the homing state. Does NOT set isAtHome because the mount didn't finish.
    func cancelHoming() {
        sendCommand(":Q#")
        homingPollTask?.cancel()
        homingPollTask           = nil
        mountStatus.isHoming     = false
        mountStatus.homingStatus = ""
    }

    // Manual override — marks the mount as at home without a poll completing.
    // Not currently surfaced in the UI but available as a fallback.
    func finishHoming() {
        homingPollTask?.cancel()
        homingPollTask   = nil
        mountStatus.isHoming = false
        setAtHome(true)
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Site Setup
    // ─────────────────────────────────────────────────────────────────────────

    // Sends the observer's GPS location to the mount.
    // LX200 convention:
    //   Latitude  → positive = North   e.g. "+41*01:30"
    //   Longitude → positive = West    e.g. "+081*43:48"
    //              (opposite of normal geographic convention!)
    //
    // The mount needs location to calculate rise/set times and to display
    // altitude/azimuth in the Status screen.
    func setSiteLocation(latitude: String, longitude: String, completion: ((Bool) -> Void)? = nil) {
        query(":St\(latitude)#") { [weak self] latResp in
            guard latResp == "1" else { completion?(false); return }
            self?.query(":Sg\(longitude)#") { lonResp in
                completion?(lonResp == "1")
            }
        }
    }

    // Sends the current date, local time, and UTC offset to the mount.
    // Order matters: UTC offset first, then time, then date.
    //
    // LX200 UTC offset convention: positive = hours BEHIND UTC (West).
    //   Ohio Eastern Standard Time = +5
    //   Ohio Eastern Daylight Time = +4
    //
    // The user can override the offset via the stepper in SetupView to
    // correct for daylight saving time.
    func setSiteDateTime(utcOffsetHours: Double? = nil, completion: ((Bool) -> Void)? = nil) {
        let now      = Date()
        let calendar = Calendar.current
        let timezone = calendar.timeZone

        // Use the caller-supplied offset (from the stepper) if provided;
        // otherwise derive it from the device's timezone.
        let lx200Offset: Double
        if let supplied = utcOffsetHours {
            lx200Offset = supplied
        } else {
            let offsetSeconds = timezone.secondsFromGMT(for: now)
            lx200Offset       = Double(-offsetSeconds) / 3600.0
        }

        // Format the offset as "+HH" or "+HH.5" (OnStep requires 2-digit hours).
        let sign   = lx200Offset >= 0 ? "+" : "-"
        let absH   = Swift.abs(lx200Offset)
        let h      = Int(absH)
        let frac   = Int((absH - Double(h)) * 10.0)
        let offsetString = frac == 0
            ? ":SG\(sign)\(String(format: "%02d", h))#"
            : ":SG\(sign)\(String(format: "%02d", h)).\(frac)#"

        // Step 1: set UTC offset (:SG)
        query(offsetString) { resp in
            guard resp == "1" else { completion?(false); return }

            let fmt = DateFormatter()
            fmt.timeZone = timezone

            // Step 2: set local time (:SL) — format "HH:MM:SS"
            fmt.dateFormat = "HH:mm:ss"
            self.query(":SL\(fmt.string(from: now))#") { timeResp in
                guard timeResp == "1" else { completion?(false); return }

                // Step 3: set date (:SC) — format "MM/DD/YY"
                // Use query (not sendCommand) to consume the response and keep the buffer clean.
                fmt.dateFormat = "MM/dd/yy"
                self.query(":SC\(fmt.string(from: now))#") { _ in
                    completion?(true)
                }
            }
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(wifiHost, forKey: "wifiHost")
        UserDefaults.standard.set(wifiPort, forKey: "wifiPort")
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Star Alignment
    // ─────────────────────────────────────────────────────────────────────────

    // Starts a new n-star alignment session on the mount.
    // :An# resets OnStep's internal pointing model math but does NOT physically
    // move the mount. The mount simply forgets its previous corrections and waits
    // for the user to GoTo and accept each alignment star.
    func startAlignment(starCount: Int, completion: @escaping () -> Void) {
        query(":A\(starCount)#") { _ in DispatchQueue.main.async { completion() } }
    }

    // Reads the current alignment progress via :A?#.
    // Response is a 3-character string "mno":
    //   m — max stars the firmware supports (e.g. "9")
    //   n — next star number OnStep is waiting for (0 = alignment complete)
    //   o — total stars requested for this session
    //
    // Example: "930" = supports 9 stars, next = 3, total = 0 (not started yet)
    //          "921" = supports 9 stars, next = 2, total = 1 (accepted 1 so far)
    //          "900" = supports 9 stars, next = 0, total = 0 (complete or not started)
    func queryAlignmentStatus(completion: @escaping (_ maxStars: Int, _ nextStar: Int, _ totalStars: Int) -> Void) {
        query(":A?#") { response in
            self.log("queryAlignmentStatus :A?# → '\(response)'")
            let chars = Array(response)
            guard chars.count >= 3,
                  let max   = Int(String(chars[0])),
                  let next  = Int(String(chars[1])),
                  let total = Int(String(chars[2])) else {
                // Parse failed — return safe defaults so the alignment view can continue.
                DispatchQueue.main.async { completion(0, 1, 0) }
                return
            }
            self.log("alignment parsed: max=\(max) next=\(next) total=\(total)")
            DispatchQueue.main.async { completion(max, next, total) }
        }
    }

    // Accepts the current alignment star.
    // Sends :CM# which tells OnStep "the scope is pointing exactly at the selected star."
    // OnStep records the pointing correction, increments the star counter,
    // and automatically starts waiting for the next star.
    //
    // :CM# returns a descriptive string (e.g. "M31 EX GAL MAG 3.5 ...") that
    // must be consumed to keep the queue clean — hence using query() not sendCommand().
    // Completion fires on the main thread after the response so the view can
    // immediately call queryAlignmentStatus() to learn the next step number.
    func alignmentSync(completion: (() -> Void)? = nil) {
        query(":CM#") { _ in DispatchQueue.main.async { completion?() } }
    }


    // ─────────────────────────────────────────────────────────────────────────
    // MARK: - Helpers
    // ─────────────────────────────────────────────────────────────────────────

    // Normalises the :GG# UTC offset to match the format shown in the phone column.
    // Mount returns "[sign]HH:MM" (e.g. "+04:00", "+05:30").
    // Normalised: "[sign]HH" for whole hours, "[sign]HH.5" for half-hour offsets.
    private static func normalizeUTCOffset(_ raw: String) -> String {
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Int(parts[1]) else { return raw }
        let hourPart = String(parts[0])
        switch minutes {
        case 0:  return hourPart          // "+04:00" → "+04"
        case 30: return "\(hourPart).5"   // "+05:30" → "+05.5"
        default: return raw               // unusual offset — show as-is
        }
    }
}
