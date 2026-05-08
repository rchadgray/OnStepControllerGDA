import Foundation

// Approximate positions for solar system bodies using Schlyter's simplified
// orbital elements (~1° accuracy, valid 1950–2050).
enum SolarSystem {

    static func bodies(date: Date = .now) -> [SkyObject] {
        let d   = daysSinceJ2000(date)
        let ecl = obliquity(d: d)
        let (sr, sLon) = sunOrbit(d: d)   // sun distance (AU), ecliptic lon (radians)
        let sunLonDeg  = sLon * (180.0 / .pi)
        let ex = -sr * cos(sLon)           // Earth heliocentric ecliptic x
        let ey = -sr * sin(sLon)           // Earth heliocentric ecliptic y

        return [
            makeSun(sr: sr, sLon: sLon, ecl: ecl),
            makeMoon(d: d, ecl: ecl, sunLonDeg: sunLonDeg),
            makePlanet(.mercury, d: d, ecl: ecl, ex: ex, ey: ey),
            makePlanet(.venus,   d: d, ecl: ecl, ex: ex, ey: ey),
            makePlanet(.mars,    d: d, ecl: ecl, ex: ex, ey: ey),
            makePlanet(.jupiter, d: d, ecl: ecl, ex: ex, ey: ey),
            makePlanet(.saturn,  d: d, ecl: ecl, ex: ex, ey: ey),
            makePlanet(.uranus,  d: d, ecl: ecl, ex: ex, ey: ey),
            makePlanet(.neptune, d: d, ecl: ecl, ex: ex, ey: ey),
        ]
    }

    // MARK: - Math helpers

    private static func daysSinceJ2000(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400.0 + 2440587.5 - 2451545.0
    }

    private static func obliquity(d: Double) -> Double { 23.4393 - 3.563e-7 * d }

    private static func rev(_ x: Double) -> Double {
        let r = x.truncatingRemainder(dividingBy: 360.0)
        return r < 0 ? r + 360.0 : r
    }

    // Iterative Kepler solver; M and result in radians.
    private static func kepler(M: Double, e: Double) -> Double {
        var E = M + e * sin(M) * (1.0 + e * cos(M))
        for _ in 0..<8 {
            let dE = (M - (E - e * sin(E))) / (1.0 - e * cos(E))
            E += dE
            if abs(dE) < 1e-8 { break }
        }
        return E
    }

    // Geocentric ecliptic (x,y,z) → equatorial (RA hours, Dec degrees).
    private static func toEquatorial(x: Double, y: Double, z: Double, ecl: Double)
        -> (ra: Double, dec: Double) {
        let e  = ecl * .pi / 180.0
        let ye = y * cos(e) - z * sin(e)
        let ze = y * sin(e) + z * cos(e)
        let r  = sqrt(x*x + ye*ye + ze*ze)
        let ra  = (atan2(ye, x) * (180.0 / .pi) / 15.0 + 24.0)
            .truncatingRemainder(dividingBy: 24.0)
        let dec = asin(max(-1.0, min(1.0, ze / r))) * (180.0 / .pi)
        return (ra, dec)
    }

    // Heliocentric ecliptic XYZ from Schlyter elements (angles in degrees).
    private static func heliocentric(N: Double, i: Double, w: Double,
                                     a: Double, e: Double, M: Double)
        -> (x: Double, y: Double, z: Double) {
        let Mr  = rev(M) * .pi / 180.0
        let E   = kepler(M: Mr, e: e)
        let xv  = a * (cos(E) - e)
        let yv  = a * sqrt(max(0, 1 - e*e)) * sin(E)
        let v   = atan2(yv, xv)
        let r   = sqrt(xv*xv + yv*yv)
        let Nr  = N * .pi / 180.0
        let ir  = i * .pi / 180.0
        let vw  = v + w * .pi / 180.0
        return (
            r * (cos(Nr)*cos(vw) - sin(Nr)*sin(vw)*cos(ir)),
            r * (sin(Nr)*cos(vw) + cos(Nr)*sin(vw)*cos(ir)),
            r * sin(vw) * sin(ir)
        )
    }

    // MARK: - Sun

    // Returns (distance AU, ecliptic longitude radians) for the Sun.
    private static func sunOrbit(d: Double) -> (r: Double, lon: Double) {
        let w  = rev(282.9404 + 4.70935e-5 * d)
        let e  = 0.016709 - 1.151e-9 * d
        let Mr = rev(356.0470 + 0.9856002585 * d) * .pi / 180.0
        let E  = kepler(M: Mr, e: e)
        let xv = cos(E) - e
        let yv = sqrt(max(0, 1 - e*e)) * sin(E)
        let r  = sqrt(xv*xv + yv*yv)
        let v  = atan2(yv, xv)
        return (r, v + w * .pi / 180.0)
    }

    private static func makeSun(sr: Double, sLon: Double, ecl: Double) -> SkyObject {
        let xs = sr * cos(sLon)
        let ys = sr * sin(sLon)
        let (ra, dec) = toEquatorial(x: xs, y: ys, z: 0, ecl: ecl)
        return SkyObject(id: "sol_sun", name: "Sun",
                         ra: ra, dec: dec, magnitude: -26.7, type: .sun)
    }

    // MARK: - Moon

    private static func makeMoon(d: Double, ecl: Double, sunLonDeg: Double) -> SkyObject {
        let (xh, yh, zh) = heliocentric(
            N: rev(125.1228 - 0.0529538083 * d),
            i: 5.1454,
            w: rev(318.0634 + 0.1643573223 * d),
            a: 60.2666,   // Earth radii — direction only matters for RA/Dec
            e: 0.054900,
            M: rev(115.3654 + 13.0649929509 * d)
        )
        let (ra, dec) = toEquatorial(x: xh, y: yh, z: zh, ecl: ecl)

        // Signed elongation: + = east of Sun (waxing), - = west (waning)
        let moonLonDeg = atan2(yh, xh) * (180.0 / .pi)
        var elong = rev(moonLonDeg - sunLonDeg)
        if elong > 180 { elong -= 360 }

        return SkyObject(id: "sol_moon", name: "Moon",
                         ra: ra, dec: dec, magnitude: -12.7, type: .moon, phase: elong)
    }

    // MARK: - Planets

    private enum PlanetId { case mercury, venus, mars, jupiter, saturn, uranus, neptune }

    private static func makePlanet(_ p: PlanetId, d: Double, ecl: Double,
                                   ex: Double, ey: Double) -> SkyObject {
        let el = elements(p, d: d)
        let (xh, yh, zh) = heliocentric(N: el.N, i: el.i, w: el.w,
                                         a: el.a, e: el.e, M: el.M)
        let (ra, dec) = toEquatorial(x: xh - ex, y: yh - ey, z: zh, ecl: ecl)
        let (name, mag) = meta(p)
        return SkyObject(id: "sol_\(name.lowercased())", name: name,
                         ra: ra, dec: dec, magnitude: mag, type: .planet)
    }

    private static func elements(_ p: PlanetId, d: Double)
        -> (N: Double, i: Double, w: Double, a: Double, e: Double, M: Double) {
        switch p {
        case .mercury:
            return (48.3313 + 3.24587e-5*d, 7.0047 + 5.00e-8*d,
                    29.1241 + 1.01444e-5*d, 0.387098,
                    0.205635 + 5.59e-10*d,  168.6562 + 4.0923344368*d)
        case .venus:
            return (76.6799 + 2.46590e-5*d, 3.3946 + 2.75e-8*d,
                    54.8910 + 1.38374e-5*d, 0.723330,
                    0.006773 - 1.302e-9*d,  48.0052 + 1.6021302244*d)
        case .mars:
            return (49.5574 + 2.11081e-5*d, 1.8497 - 1.78e-8*d,
                    286.5016 + 2.92961e-5*d, 1.523688,
                    0.093405 + 2.516e-9*d,   18.6021 + 0.5240207766*d)
        case .jupiter:
            return (100.4542 + 2.76854e-5*d, 1.3030 - 1.557e-7*d,
                    273.8777 + 1.64505e-5*d,  5.20256,
                    0.048498 + 4.469e-9*d,    19.8950 + 0.0830853001*d)
        case .saturn:
            return (113.6634 + 2.38980e-5*d, 2.4886 - 1.081e-7*d,
                    339.3939 + 2.97661e-5*d,  9.55475,
                    0.055546 - 9.499e-9*d,    316.9670 + 0.0334442282*d)
        case .uranus:
            return (74.0005 + 1.3978e-5*d,  0.7733 + 1.9e-8*d,
                    96.6612 + 3.0565e-5*d,   19.18171 - 1.55e-8*d,
                    0.047318 + 7.45e-9*d,    142.5905 + 0.011725806*d)
        case .neptune:
            return (131.7806 + 3.0173e-5*d, 1.7700 - 2.55e-7*d,
                    272.8461 - 6.027e-6*d,  30.05826 + 3.313e-8*d,
                    0.008606 + 2.15e-9*d,   260.2471 + 0.005995147*d)
        }
    }

    private static func meta(_ p: PlanetId) -> (name: String, magnitude: Double) {
        switch p {
        case .mercury: return ("Mercury",  0.0)
        case .venus:   return ("Venus",   -4.0)
        case .mars:    return ("Mars",     0.5)
        case .jupiter: return ("Jupiter", -2.0)
        case .saturn:  return ("Saturn",   0.7)
        case .uranus:  return ("Uranus",   5.7)
        case .neptune: return ("Neptune",  7.8)
        }
    }
}
