import Foundation

// A single bright star used as an alignment reference.
struct AlignmentStar: Identifiable {
    var id: String { name }
    let name: String
    let ra:   Double  // Right Ascension in decimal hours, J2000 epoch
    let dec:  Double  // Declination in decimal degrees, J2000 epoch

    // LX200 RA format for :Sr command: HH:MM:SS
    var raLX200: String {
        let h  = Int(ra)
        let mt = (ra - Double(h)) * 60.0
        let m  = Int(mt)
        let s  = Int((mt - Double(m)) * 60.0)
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    // LX200 Dec format for :Sd command: ±DD*MM'SS
    var decLX200: String {
        let sign = dec >= 0 ? "+" : "-"
        let a    = abs(dec)
        let d    = Int(a)
        let mt   = (a - Double(d)) * 60.0
        let m    = Int(mt)
        let s    = Int((mt - Double(m)) * 60.0)
        return String(format: "%@%02d*%02d'%02d", sign, d, m, s)
    }

    // Calculates the star's altitude above the horizon for a given observer
    // location and Local Sidereal Time. Uses the standard spherical trig formula.
    func altitude(latitude: Double, lst: Double) -> Double {
        // Hour angle = LST − RA, converted from hours to degrees
        var ha = (lst - ra) * 15.0
        // Normalise to [−180°, +180°] so sin/cos work correctly
        ha = ha.truncatingRemainder(dividingBy: 360.0)
        if ha >  180.0 { ha -= 360.0 }
        if ha < -180.0 { ha += 360.0 }

        let lat = latitude * .pi / 180.0
        let d   = dec      * .pi / 180.0
        let h   = ha       * .pi / 180.0
        let sinAlt = sin(lat) * sin(d) + cos(lat) * cos(d) * cos(h)
        return asin(max(-1.0, min(1.0, sinAlt))) * 180.0 / .pi
    }

    // Returns true when the star is above the minimum altitude threshold (default 15°).
    // Stars below 15° are typically too close to the horizon for reliable alignment.
    func isVisible(latitude: Double, lst: Double, minAlt: Double = 15.0) -> Bool {
        altitude(latitude: latitude, lst: lst) >= minAlt
    }
}

// Provides the list of alignment stars and helpers for filtering by visibility.
enum StarCatalog {
    // 28 prominent alignment stars spread across the whole sky.
    // RA is in decimal hours, Dec is in decimal degrees, both J2000.
    static let stars: [AlignmentStar] = [
        AlignmentStar(name: "Sirius",      ra:  6.7525, dec: -16.716),
        AlignmentStar(name: "Canopus",     ra:  6.3992, dec: -52.696),
        AlignmentStar(name: "Arcturus",    ra: 14.2610, dec:  19.182),
        AlignmentStar(name: "Vega",        ra: 18.6156, dec:  38.784),
        AlignmentStar(name: "Capella",     ra:  5.2781, dec:  45.998),
        AlignmentStar(name: "Rigel",       ra:  5.2422, dec:  -8.202),
        AlignmentStar(name: "Procyon",     ra:  7.6553, dec:   5.225),
        AlignmentStar(name: "Betelgeuse",  ra:  5.9194, dec:   7.407),
        AlignmentStar(name: "Altair",      ra: 19.8464, dec:   8.868),
        AlignmentStar(name: "Aldebaran",   ra:  4.5987, dec:  16.509),
        AlignmentStar(name: "Spica",       ra: 13.4200, dec: -11.161),
        AlignmentStar(name: "Antares",     ra: 16.4901, dec: -26.432),
        AlignmentStar(name: "Pollux",      ra:  7.7553, dec:  28.026),
        AlignmentStar(name: "Fomalhaut",   ra: 22.9608, dec: -29.622),
        AlignmentStar(name: "Deneb",       ra: 20.6905, dec:  45.280),
        AlignmentStar(name: "Regulus",     ra: 10.1395, dec:  11.967),
        AlignmentStar(name: "Castor",      ra:  7.5767, dec:  31.888),
        AlignmentStar(name: "Polaris",     ra:  2.5303, dec:  89.264),
        AlignmentStar(name: "Mirfak",      ra:  3.4053, dec:  49.861),
        AlignmentStar(name: "Dubhe",       ra: 11.0621, dec:  61.751),
        AlignmentStar(name: "Alioth",      ra: 12.9003, dec:  55.960),
        AlignmentStar(name: "Alpheratz",   ra:  0.1397, dec:  29.090),
        AlignmentStar(name: "Hamal",       ra:  2.1197, dec:  23.463),
        AlignmentStar(name: "Denebola",    ra: 11.8177, dec:  14.572),
        AlignmentStar(name: "Nunki",       ra: 18.9211, dec: -26.297),
        AlignmentStar(name: "Alnilam",     ra:  5.6036, dec:  -1.202),
        AlignmentStar(name: "Almach",      ra:  2.0650, dec:  42.330),
        AlignmentStar(name: "Mirach",      ra:  1.1622, dec:  35.621),
    ]

    // Computes Local Sidereal Time (LST) in decimal hours.
    // LST tells us which RA is currently on the meridian, needed to
    // calculate altitude/azimuth for any star from the observer's location.
    // longitude: East-positive decimal degrees (standard GPS convention).
    static func localSiderealTime(longitude: Double, date: Date = .now) -> Double {
        // Convert date to Julian Date, then compute Greenwich Mean Sidereal Time (GMST).
        let jd   = date.timeIntervalSince1970 / 86400.0 + 2440587.5
        var gmst = 280.46061837 + 360.98564736629 * (jd - 2451545.0)
        gmst = gmst.truncatingRemainder(dividingBy: 360.0)
        if gmst < 0 { gmst += 360.0 }
        // Add the observer's longitude to get Local Sidereal Time, in hours.
        var lst = gmst / 15.0 + longitude / 15.0
        lst = lst.truncatingRemainder(dividingBy: 24.0)
        if lst < 0 { lst += 24.0 }
        return lst
    }

    // Returns all stars currently above minAlt degrees, sorted highest-first.
    // Higher stars are better alignment choices — less atmospheric distortion.
    static func visibleStars(latitude: Double, longitude: Double, date: Date = .now) -> [AlignmentStar] {
        let lst = localSiderealTime(longitude: longitude, date: date)
        return stars
            .filter { $0.isVisible(latitude: latitude, lst: lst) }
            .sorted { $0.altitude(latitude: latitude, lst: lst) > $1.altitude(latitude: latitude, lst: lst) }
    }
}
