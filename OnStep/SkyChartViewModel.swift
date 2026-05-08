import SwiftUI
import Combine

// State and coordinate math for the sky chart.
// Holds the "camera" pointing direction (alt/az), field-of-view radius, and observer
// location. Converts RA/Dec catalog entries to screen positions using a gnomonic
// projection — great circles appear as straight lines, natural for star-hopping.
@MainActor
final class SkyChartViewModel: ObservableObject {

    // Center of the view in altitude/azimuth degrees.
    // Alt: 0 = horizon, 90 = zenith. Az: 0 = North, 90 = East (clockwise).
    @Published var centerAlt: Double = 45.0
    @Published var centerAz:  Double = 0.0   // default: face North (matches telescope home position)

    // Half-angle of the visible field in degrees. 60 = wide, 15 = zoomed in.
    @Published var fovRadius: Double = 60.0

    // Object the user tapped, shown in the detail card at the bottom.
    @Published var selectedObject: SkyObject? = nil

    // Observer state (updated every 2 s from the live task in SkyChartView).
    var latitude:  Double = 40.0
    var longitude: Double = -83.0
    var lst:       Double = 0.0   // Local Sidereal Time in hours

    // Mount pointing direction in alt/az, kept fresh from OnStepManager.
    var mountAlt: Double = 45.0
    var mountAz:  Double = 180.0

    // Slew limits queried from the mount. nil until the mount is connected and responds.
    var horizonLimit:  Double? = nil   // minimum altitude (:Gh#)
    var overheadLimit: Double? = nil   // maximum altitude (:Go#)

    // Meridian flip limits in minutes of sidereal time past the meridian. nil until the mount responds.
    // East pier (:GXE9#): draws WEST of meridian (positive HA, scope on east pier).
    // West pier (:GXEA#): draws EAST of meridian (negative HA, scope on west pier).
    var meridianLimitEastPier: Double? = nil
    var meridianLimitWestPier: Double? = nil

    let catalog: [SkyObject] = SkyCatalog.all
    private(set) var solarSystem: [SkyObject] = SolarSystem.bodies()

    // Syncs observer location, sidereal time, mount position, and limits from live app state.
    func update(latitude: Double, longitude: Double, raString: String, decString: String,
                horizonLimit: Double?, overheadLimit: Double?,
                meridianLimitEastPier: Double?, meridianLimitWestPier: Double?) {
        self.latitude               = latitude
        self.longitude              = longitude
        self.lst                    = StarCatalog.localSiderealTime(longitude: longitude)
        self.horizonLimit           = horizonLimit
        self.overheadLimit          = overheadLimit
        self.meridianLimitEastPier  = meridianLimitEastPier
        self.meridianLimitWestPier  = meridianLimitWestPier
        self.solarSystem            = SolarSystem.bodies()

        if let ra = parseRA(raString), let dec = parseDec(decString) {
            let (alt, az) = altAzFor(ra: ra, dec: dec)
            mountAlt = alt
            mountAz  = az
        }
    }

    // ── Coordinate conversion ─────────────────────────────────────────────────

    // Converts equatorial (RA hours, Dec degrees, J2000) to horizon (Alt/Az degrees).
    // Az convention: 0 = North, clockwise to East (90), South (180), West (270).
    func altAzFor(ra: Double, dec: Double) -> (alt: Double, az: Double) {
        var ha = (lst - ra) * 15.0   // hour angle in degrees
        ha = ha.truncatingRemainder(dividingBy: 360.0)
        if ha >  180.0 { ha -= 360.0 }
        if ha < -180.0 { ha += 360.0 }

        let phi = latitude * .pi / 180.0
        let del = dec      * .pi / 180.0
        let h   = ha       * .pi / 180.0

        let sinAlt = sin(phi)*sin(del) + cos(phi)*cos(del)*cos(h)
        let alt    = asin(max(-1.0, min(1.0, sinAlt))) * 180.0 / .pi

        let cosAlt = cos(alt * .pi / 180.0)
        let cosAz  = cosAlt > 0.001
            ? (sin(del) - sin(phi)*sinAlt) / (cos(phi)*cosAlt)
            : 0.0
        var az = acos(max(-1.0, min(1.0, cosAz))) * 180.0 / .pi
        if sin(h) > 0.0 { az = 360.0 - az }   // object is west of the meridian

        return (alt, az)
    }

    // ── Gnomonic projection ───────────────────────────────────────────────────

    // Projects (alt, az) in degrees onto a canvas of the given size.
    // Returns nil when the point is behind the viewer or outside the canvas bounds.
    // Screen convention: North up, East RIGHT (map/compass convention — matches standing
    // at the telescope: North up, East on your right, West on your left).
    func project(alt: Double, az: Double, in size: CGSize) -> CGPoint? {
        let scale = projectionScale(for: size)
        let alt0  = centerAlt * .pi / 180.0
        let az0   = centerAz  * .pi / 180.0
        let altR  = alt * .pi / 180.0
        let dAz   = az  * .pi / 180.0 - az0

        // Cosine of angular separation from the center. Must be positive.
        let cosC = cos(alt0)*cos(altR)*cos(dAz) + sin(alt0)*sin(altR)
        guard cosC > 0.02 else { return nil }

        // Gnomonic tangent-plane coords: px points East, py points North.
        let px =  cos(altR)*sin(dAz) / cosC
        let py = (cos(alt0)*sin(altR) - sin(alt0)*cos(altR)*cos(dAz)) / cosC

        // East → RIGHT (+x), North → UP (flip screen-y since screen-y increases downward).
        let sx = size.width  / 2.0 + px * scale
        let sy = size.height / 2.0 - py * scale

        guard sx >= 0 && sx <= size.width && sy >= 0 && sy <= size.height else { return nil }
        return CGPoint(x: sx, y: sy)
    }

    // Pixels per radian in the gnomonic projection.
    func projectionScale(for size: CGSize) -> Double {
        (min(size.width, size.height) / 2.0) / tan(fovRadius * .pi / 180.0)
    }

    // ── Interaction ───────────────────────────────────────────────────────────

    // Pan the camera by a pixel delta (from DragGesture).
    // Uses "content follows finger": the sky point under the finger stays under it as it moves.
    func pan(delta: CGSize, canvasSize: CGSize) {
        let radPerPx = 1.0 / projectionScale(for: canvasSize)
        // East is RIGHT: drag right → content moves right → center moves toward West (az decreases).
        centerAz  -= delta.width  * radPerPx * (180.0 / .pi)
        // Drag down → content moves down → center moves to higher altitude (zenith direction).
        centerAlt += delta.height * radPerPx * (180.0 / .pi)
        centerAlt  = max(-10.0, min(90.0, centerAlt))
        centerAz   = centerAz.truncatingRemainder(dividingBy: 360.0)
        if centerAz < 0 { centerAz += 360.0 }
    }

    // Zoom by a scale factor (> 1 zooms in, < 1 zooms out).
    func zoom(factor: Double) {
        fovRadius = max(5.0, min(90.0, fovRadius / factor))
    }

    // ── Magnitude limits based on zoom level ─────────────────────────────────
    // As the user zooms in (smaller fovRadius), fainter objects become visible.
    // Stars use a tighter scale than DSOs since there are far more faint stars.

    var limitingStarMagnitude: Double {
        if fovRadius < 10 { return 6.5 }
        if fovRadius < 20 { return 6.0 }
        if fovRadius < 35 { return 5.0 }
        if fovRadius < 55 { return 4.0 }
        return 3.5   // wide angle default: enough to trace constellations
    }

    var limitingDSOMagnitude: Double {
        if fovRadius < 10 { return 10.5 }
        if fovRadius < 20 { return  9.0 }
        if fovRadius < 35 { return  7.5 }
        if fovRadius < 55 { return  6.0 }
        return 5.5   // wide angle: only showpiece objects (Pleiades, Orion Nebula, etc.)
    }

    // Magnitude threshold above which star names are shown (more labels when zoomed).
    var starLabelThreshold: Double {
        if fovRadius < 15 { return 4.5 }
        if fovRadius < 30 { return 3.0 }
        if fovRadius < 55 { return 2.0 }
        return 1.5
    }

    // Returns catalog and solar system objects above the horizon that pass the magnitude
    // filter, with projected screen positions. Solar system bodies are always included.
    func visibleProjections(for size: CGSize) -> [(obj: SkyObject, pt: CGPoint)] {
        let starLimit = limitingStarMagnitude
        let dsoLimit  = limitingDSOMagnitude
        var result = catalog.compactMap { obj -> (SkyObject, CGPoint)? in
            let limit = obj.type == .star ? starLimit : dsoLimit
            guard obj.magnitude <= limit else { return nil }
            let (alt, az) = altAzFor(ra: obj.ra, dec: obj.dec)
            guard alt > -5.0 else { return nil }
            guard let pt = project(alt: alt, az: az, in: size) else { return nil }
            return (obj, pt)
        }
        for body in solarSystem {
            let (alt, az) = altAzFor(ra: body.ra, dec: body.dec)
            guard alt > -5.0 else { continue }
            guard let pt = project(alt: alt, az: az, in: size) else { continue }
            result.append((body, pt))
        }
        return result
    }

    // Hit-test: nearest object within 28 pt of a tap, solar system bodies preferred.
    func nearestObject(to tap: CGPoint, in size: CGSize) -> (SkyObject, CGPoint)? {
        var best: (SkyObject, CGPoint)? = nil
        var bestDist = 28.0
        for (obj, pt) in visibleProjections(for: size) {
            let d = hypot(tap.x - pt.x, tap.y - pt.y)
            if d < bestDist { bestDist = d; best = (obj, pt) }
        }
        return best
    }

    // ── LX200 string parsers ──────────────────────────────────────────────────

    // Parses "HH:MM:SS" into decimal hours, or nil if the string is invalid.
    func parseRA(_ s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        let v = parts[0] + parts[1]/60.0 + parts[2]/3600.0
        return (v >= 0 && v < 24) ? v : nil
    }

    // Parses "+DD:MM:SS" or "+DD*MM:SS" (LX200 Dec format) into decimal degrees, or nil.
    func parseDec(_ s: String) -> Double? {
        let cleaned = s.replacingOccurrences(of: "*", with: ":")
                       .replacingOccurrences(of: "'", with: ":")
        guard !cleaned.isEmpty else { return nil }
        let negative = cleaned.hasPrefix("-")
        let digits   = String(cleaned.dropFirst())
        let parts    = digits.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return nil }
        let v = parts[0] + parts[1]/60.0 + (parts.count > 2 ? parts[2]/3600.0 : 0)
        return negative ? -v : v
    }
}
