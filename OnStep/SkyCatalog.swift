import Foundation

// Type of deep-sky object — drives the symbol drawn on the chart.
enum SkyObjectType: String {
    case star, openCluster, globularCluster, nebula, galaxy, planetaryNebula

    var displayName: String {
        switch self {
        case .star:              return "Star"
        case .openCluster:       return "Open Cluster"
        case .globularCluster:   return "Globular Cluster"
        case .nebula:            return "Nebula"
        case .galaxy:            return "Galaxy"
        case .planetaryNebula:   return "Planetary Nebula"
        }
    }
}

// A single sky object — star or deep-sky object.
struct SkyObject: Identifiable {
    let id:        String
    let name:      String
    let ra:        Double   // decimal hours, J2000
    let dec:       Double   // decimal degrees, J2000
    let magnitude: Double
    let type:      SkyObjectType
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
