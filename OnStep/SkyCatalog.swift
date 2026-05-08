import Foundation

// Type of deep-sky object — drives the symbol drawn on the chart.
enum SkyObjectType: String {
    case star, openCluster, globularCluster, nebula, galaxy, planetaryNebula
    case sun, moon, planet

    var displayName: String {
        switch self {
        case .star:              return "Star"
        case .openCluster:       return "Open Cluster"
        case .globularCluster:   return "Globular Cluster"
        case .nebula:            return "Nebula"
        case .galaxy:            return "Galaxy"
        case .planetaryNebula:   return "Planetary Nebula"
        case .sun:               return "Sun"
        case .moon:              return "Moon"
        case .planet:            return "Planet"
        }
    }
}

// A single sky object — star, deep-sky object, or solar system body.
struct SkyObject: Identifiable {
    let id:        String
    let name:      String
    let ra:        Double   // decimal hours, apparent geocentric (J2000 for catalog objects)
    let dec:       Double   // decimal degrees
    let magnitude: Double
    let type:      SkyObjectType
    // Moon: signed elongation from Sun in degrees (+ = east/waxing, - = west/waning).
    // Other objects: 0.
    let phase:     Double

    init(id: String, name: String, ra: Double, dec: Double,
         magnitude: Double, type: SkyObjectType, phase: Double = 0) {
        self.id        = id
        self.name      = name
        self.ra        = ra
        self.dec       = dec
        self.magnitude = magnitude
        self.type      = type
        self.phase     = phase
    }

    // Subtitle shown in the object detail card.
    var cardSubtitle: String {
        switch type {
        case .moon:
            let k   = (1 - cos(phase * .pi / 180)) / 2
            let pct = Int((k * 100).rounded())
            let dir: String
            if abs(phase) < 10       { dir = "New Moon" }
            else if abs(phase) > 170 { dir = "Full Moon" }
            else if phase > 0        { dir = "Waxing" }
            else                     { dir = "Waning" }
            return "Moon · \(pct)% illuminated · \(dir)"
        case .sun:
            return "Sun · Never aim mount at the Sun"
        case .planet:
            return "Planet · Mag \(String(format: "%.1f", magnitude))"
        default:
            return "\(type.displayName) · Mag \(String(format: "%.1f", magnitude))"
        }
    }
}

// Loads the catalog from bundled CSV resource files at app startup.
//
// File format — one object per line, six comma-separated fields:
//   id, display_name, ra_hours, dec_degrees, magnitude, type_code
// Type codes: star | oc | gc | neb | gal | pn
// Lines beginning with # are comments and are ignored.
//
// To upgrade to a fuller catalog, replace or augment the CSV files with data
// from free standard sources:
//   Stars: HYG Database   https://github.com/astronexus/HYG-Database   (119 614 stars)
//   DSOs:  OpenNGC        https://github.com/mattiaverga/OpenNGC        (13 957 objects)
// Convert their columns to the six-field format above and drop the file in
// the app bundle — no code changes required.
enum SkyCatalog {

    static let all: [SkyObject] = loadCSV("stars") + loadCSV("dso")

    private static func loadCSV(_ name: String) -> [SkyObject] {
        guard let url  = Bundle.main.url(forResource: name, withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        return text
            .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> SkyObject? {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
        let f = s.split(separator: ",", maxSplits: 5, omittingEmptySubsequences: false)
                  .map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count == 6,
              let ra  = Double(f[2]),
              let dec = Double(f[3]),
              let mag = Double(f[4])
        else { return nil }
        return SkyObject(id: f[0], name: f[1], ra: ra, dec: dec, magnitude: mag,
                         type: parseType(f[5]))
    }

    private static func parseType(_ s: String) -> SkyObjectType {
        switch s {
        case "oc":  return .openCluster
        case "gc":  return .globularCluster
        case "neb": return .nebula
        case "gal": return .galaxy
        case "pn":  return .planetaryNebula
        default:    return .star
        }
    }
}
