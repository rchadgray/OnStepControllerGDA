import SwiftUI

// Sky chart showing stars and Messier objects for the observer's current location
// and time. Uses a gnomonic projection centered on an alt/az point that the user
// can pan (drag) and zoom (pinch). A red crosshair tracks where OnStep is pointing.
// Tap any object to see its name and issue a GoTo.
// In alignment mode (appState.isAligning) an amber banner appears at the top;
// after each GoTo completes the alignment panel auto-slides up.
struct SkyChartView: View {
    @EnvironmentObject var telescope:       OnStepManager
    @EnvironmentObject var locationManager: LocationManager
    @Environment(AppState.self) var appState
    @StateObject private var vm = SkyChartViewModel()

    @State private var lastDragTranslation: CGSize = .zero
    @State private var lastMagnification:   Double = 1.0
    @State private var goToIssued:          Bool   = false

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Color.black.ignoresSafeArea()

                    Canvas { ctx, size in
                        drawSky(ctx: ctx, size: size)
                    }
                    .gesture(dragGesture(in: geo.size))
                    .simultaneousGesture(magnificationGesture)
                    .onTapGesture { tap in
                        if let (obj, _) = vm.nearestObject(to: tap, in: geo.size) {
                            vm.selectedObject = obj
                        } else {
                            vm.selectedObject = nil
                        }
                    }

                    if let obj = vm.selectedObject {
                        objectCard(for: obj)
                    }

                    // Alignment mode banner — overlaid at the top
                    if appState.isAligning {
                        VStack {
                            alignmentBanner
                            Spacer()
                        }
                    }
                }
            }
            .ignoresSafeArea(.all, edges: .bottom)
            .navigationTitle("Sky Chart")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        vm.centerAlt = 45
                        vm.centerAz  = 0
                        vm.fovRadius = 60
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    trackingIndicator
                        .buttonStyle(.plain)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        vm.centerAlt = vm.mountAlt
                        vm.centerAz  = vm.mountAz
                    } label: {
                        Label("Center on Mount", systemImage: "scope")
                    }
                    .disabled(!telescope.isConnected)
                }
            }
            .task {
                while !Task.isCancelled {
                    vm.update(
                        latitude:              locationManager.latitude,
                        longitude:             locationManager.longitude,
                        raString:              telescope.mountStatus.ra,
                        decString:             telescope.mountStatus.dec,
                        horizonLimit:          telescope.mountStatus.horizonLimit,
                        overheadLimit:         telescope.mountStatus.overheadLimit,
                        meridianLimitEastPier: telescope.mountStatus.meridianLimitEastPier,
                        meridianLimitWestPier:  telescope.mountStatus.meridianLimitWestPier
                    )
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            // When a GoTo slew finishes during alignment, auto-show the nudge panel.
            .onChange(of: telescope.mountStatus.isMoving) { _, isMoving in
                guard !isMoving else { return }
                goToIssued = false
                vm.selectedObject = nil
                guard appState.isAligning,
                      !appState.alignmentCurrentRA.isEmpty,
                      !appState.alignmentShowPanel else { return }
                appState.alignmentShowPanel = true
            }
            .sheet(isPresented: $appState.alignmentShowPanel) {
                AlignmentPanelView()
                    .environmentObject(telescope)
                    .environment(appState)
            }
        }
    }

    // MARK: - Alignment Banner

    private var alignmentBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.circle.fill")
                .foregroundStyle(Color.astroAmber)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Alignment Mode")
                    .font(.caption).fontWeight(.bold)
                    .foregroundStyle(Color.astroAmber)
                Text(appState.alignmentTotalStars > 0
                     ? "Star \(appState.alignmentNextStar) of \(appState.alignmentTotalStars) — tap a star and GoTo"
                     : "Tap a bright star and GoTo to begin")
                    .font(.caption2)
                    .foregroundStyle(Color.astroAmber.opacity(0.8))
            }
            Spacer()
            Button("Exit") { appState.endAlignment() }
                .font(.caption2).fontWeight(.semibold)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.3))
                .foregroundStyle(.white)
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    // MARK: - Gestures

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { val in
                let delta = CGSize(
                    width:  val.translation.width  - lastDragTranslation.width,
                    height: val.translation.height - lastDragTranslation.height
                )
                lastDragTranslation = val.translation
                vm.pan(delta: delta, canvasSize: size)
            }
            .onEnded { _ in lastDragTranslation = .zero }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { val in
                let factor = Double(val) / lastMagnification
                lastMagnification = Double(val)
                vm.zoom(factor: factor)
            }
            .onEnded { _ in lastMagnification = 1.0 }
    }

    // MARK: - Canvas Drawing

    private func drawSky(ctx: GraphicsContext, size: CGSize) {
        drawMilkyWay(in: ctx, size: size)
        drawHorizonLine(in: ctx, size: size)
        drawHorizonLimit(in: ctx, size: size)
        drawOverheadLimit(in: ctx, size: size)
        drawMeridianLimits(in: ctx, size: size)
        let projections = vm.visibleProjections(for: size)
        let catalogTypes: Set<SkyObjectType> = [.star, .openCluster, .globularCluster, .nebula, .galaxy, .planetaryNebula]
        for (obj, pt) in projections where catalogTypes.contains(obj.type) && obj.type != .star { drawDSO(obj, at: pt, in: ctx) }
        for (obj, pt) in projections where obj.type == .star   { drawStar(obj,   at: pt, in: ctx) }
        for (obj, pt) in projections where obj.type == .planet { drawPlanet(obj, at: pt, in: ctx) }
        for (obj, pt) in projections where obj.type == .moon   { drawMoon(obj,   at: pt, in: ctx) }
        for (obj, pt) in projections where obj.type == .sun    { drawSun(obj,    at: pt, in: ctx) }
        drawMountCrosshair(in: ctx, size: size)
        drawCardinalLabels(in: ctx, size: size)
        drawLegend(in: ctx, size: size)
        drawFOVIndicator(in: ctx, size: size)
    }

    private func drawStar(_ obj: SkyObject, at pt: CGPoint, in ctx: GraphicsContext) {
        let selected = obj.id == vm.selectedObject?.id
        let r = max(1.5, 5.5 - obj.magnitude)

        if obj.magnitude < 1.0 {
            let gr = r * 2.5
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x-gr, y: pt.y-gr, width: gr*2, height: gr*2)),
                     with: .color(.white.opacity(0.12)))
        }

        ctx.fill(Path(ellipseIn: CGRect(x: pt.x-r, y: pt.y-r, width: r*2, height: r*2)),
                 with: .color(selected ? Color.astroAmber : .white))

        if selected {
            let sr = r + 4
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x-sr, y: pt.y-sr, width: sr*2, height: sr*2)),
                       with: .color(Color.astroAmber), lineWidth: 1)
        }

        if obj.magnitude < vm.starLabelThreshold || selected {
            ctx.draw(
                Text(obj.name).font(.system(size: 9)).foregroundStyle(Color.white.opacity(selected ? 0.9 : 0.55)),
                at: CGPoint(x: pt.x + r + 2, y: pt.y - 3), anchor: .topLeading
            )
        }
    }

    private func drawDSO(_ obj: SkyObject, at pt: CGPoint, in ctx: GraphicsContext) {
        let selected = obj.id == vm.selectedObject?.id
        let s: Double = 6
        let alpha     = selected ? 1.0 : 0.7

        switch obj.type {
        case .openCluster:
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x-s, y: pt.y-s, width: s*2, height: s*2)),
                       with: .color(Color.yellow.opacity(alpha)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

        case .globularCluster:
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x-s, y: pt.y-s, width: s*2, height: s*2)),
                       with: .color(Color.yellow.opacity(alpha)), lineWidth: 1)
            var cross = Path()
            cross.move(to: CGPoint(x: pt.x-s, y: pt.y)); cross.addLine(to: CGPoint(x: pt.x+s, y: pt.y))
            cross.move(to: CGPoint(x: pt.x, y: pt.y-s)); cross.addLine(to: CGPoint(x: pt.x, y: pt.y+s))
            ctx.stroke(cross, with: .color(Color.yellow.opacity(alpha * 0.6)), lineWidth: 0.5)

        case .nebula:
            ctx.stroke(Path(CGRect(x: pt.x-s, y: pt.y-s, width: s*2, height: s*2)),
                       with: .color(Color.green.opacity(alpha)), lineWidth: 1)

        case .galaxy:
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x-s*1.6, y: pt.y-s*0.6, width: s*3.2, height: s*1.2)),
                       with: .color(Color(red: 0.8, green: 0.6, blue: 1.0).opacity(alpha)), lineWidth: 1)

        case .planetaryNebula:
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x-s*0.5, y: pt.y-s*0.5, width: s, height: s)),
                       with: .color(Color.cyan.opacity(alpha)), lineWidth: 1)
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x-s, y: pt.y-s, width: s*2, height: s*2)),
                       with: .color(Color.cyan.opacity(alpha * 0.5)), lineWidth: 0.5)

        case .star, .sun, .moon, .planet:
            break
        }

        if selected {
            let sr = s + 5
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x-sr, y: pt.y-sr, width: sr*2, height: sr*2)),
                       with: .color(Color.astroAmber), lineWidth: 1)
        }

        let labelColor = dsoColor(obj.type)
        ctx.draw(
            Text(obj.name).font(.system(size: 9)).foregroundStyle(labelColor.opacity(selected ? 0.9 : 0.6)),
            at: CGPoint(x: pt.x + s + 2, y: pt.y - 4), anchor: .topLeading
        )
    }

    // MARK: - Solar System Drawing

    private func drawSun(_ obj: SkyObject, at pt: CGPoint, in ctx: GraphicsContext) {
        let selected = obj.id == vm.selectedObject?.id
        let r: Double = 10
        // Glow
        ctx.fill(Path(ellipseIn: CGRect(x: pt.x-r*2.5, y: pt.y-r*2.5, width: r*5, height: r*5)),
                 with: .color(Color.yellow.opacity(0.12)))
        ctx.fill(Path(ellipseIn: CGRect(x: pt.x-r*1.6, y: pt.y-r*1.6, width: r*3.2, height: r*3.2)),
                 with: .color(Color.yellow.opacity(0.2)))
        // Disk
        ctx.fill(Path(ellipseIn: CGRect(x: pt.x-r, y: pt.y-r, width: r*2, height: r*2)),
                 with: .color(Color.yellow.opacity(0.95)))
        if selected {
            let sr = r + 5
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x-sr, y: pt.y-sr, width: sr*2, height: sr*2)),
                       with: .color(Color.astroAmber), lineWidth: 1.5)
        }
        ctx.draw(Text(obj.name).font(.system(size: 9)).foregroundStyle(Color.yellow.opacity(selected ? 1 : 0.7)),
                 at: CGPoint(x: pt.x + r + 2, y: pt.y - 4), anchor: .topLeading)
    }

    private func drawMoon(_ obj: SkyObject, at pt: CGPoint, in ctx: GraphicsContext) {
        let selected = obj.id == vm.selectedObject?.id
        let r: Double = 8
        // obj.phase = signed elongation in degrees; + east (waxing), - west (waning)
        let elong  = obj.phase
        let k      = (1 - cos(elong * .pi / 180)) / 2   // illumination 0–1
        let waxing = elong >= 0

        // Phase angle of terminator: 0 = new (thin crescent), π/2 = quarter, π = full
        let phaseAngle = acos(max(-1.0, min(1.0, 1.0 - 2.0 * k)))
        let tx = abs(r * cos(phaseAngle))  // terminator ellipse half-width

        let moonRect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)

        ctx.drawLayer { inner in
            inner.clip(to: Path(ellipseIn: moonRect))

            if k < 0.5 {
                // Crescent: fill dark, add lit half, cut with terminator
                inner.fill(Path(ellipseIn: moonRect), with: .color(.black))
                var litHalf = Path()
                if waxing { litHalf.addRect(CGRect(x: pt.x, y: pt.y - r, width: r, height: r * 2)) }
                else      { litHalf.addRect(CGRect(x: pt.x - r, y: pt.y - r, width: r, height: r * 2)) }
                inner.fill(litHalf, with: .color(.white.opacity(0.92)))
                // Dark terminator ellipse cuts into the lit half
                inner.fill(Path(ellipseIn: CGRect(x: pt.x - tx, y: pt.y - r, width: tx * 2, height: r * 2)),
                           with: .color(.black))
            } else {
                // Gibbous / full: fill white, add dark half, lighten with terminator
                inner.fill(Path(ellipseIn: moonRect), with: .color(.white.opacity(0.92)))
                var darkHalf = Path()
                if waxing { darkHalf.addRect(CGRect(x: pt.x - r, y: pt.y - r, width: r, height: r * 2)) }
                else      { darkHalf.addRect(CGRect(x: pt.x, y: pt.y - r, width: r, height: r * 2)) }
                inner.fill(darkHalf, with: .color(.black))
                // White terminator ellipse cuts into the dark half
                inner.fill(Path(ellipseIn: CGRect(x: pt.x - tx, y: pt.y - r, width: tx * 2, height: r * 2)),
                           with: .color(.white.opacity(0.92)))
            }
        }

        ctx.stroke(Path(ellipseIn: moonRect), with: .color(.white.opacity(0.5)), lineWidth: 0.5)

        if selected {
            let sr = r + 5
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - sr, y: pt.y - sr, width: sr * 2, height: sr * 2)),
                       with: .color(Color.astroAmber), lineWidth: 1.5)
        }
        ctx.draw(Text(obj.name).font(.system(size: 9)).foregroundStyle(Color.white.opacity(selected ? 1 : 0.7)),
                 at: CGPoint(x: pt.x + r + 2, y: pt.y - 4), anchor: .topLeading)
    }

    private func drawPlanet(_ obj: SkyObject, at pt: CGPoint, in ctx: GraphicsContext) {
        let selected = obj.id == vm.selectedObject?.id
        let r: Double = 4
        let color = planetColor(obj.name)
        // Soft glow for bright planets
        if obj.magnitude < 0 {
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r*2, y: pt.y - r*2, width: r*4, height: r*4)),
                     with: .color(color.opacity(0.2)))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2)),
                 with: .color(color.opacity(0.95)))
        if selected {
            let sr = r + 5
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - sr, y: pt.y - sr, width: sr*2, height: sr*2)),
                       with: .color(Color.astroAmber), lineWidth: 1)
        }
        ctx.draw(Text(obj.name).font(.system(size: 9)).foregroundStyle(color.opacity(selected ? 1 : 0.75)),
                 at: CGPoint(x: pt.x + r + 2, y: pt.y - 4), anchor: .topLeading)
    }

    private func planetColor(_ name: String) -> Color {
        switch name {
        case "Mercury": return Color(red: 0.7, green: 0.7, blue: 0.7)
        case "Venus":   return Color(red: 1.0, green: 0.95, blue: 0.7)
        case "Mars":    return Color(red: 1.0, green: 0.4, blue: 0.2)
        case "Jupiter": return Color(red: 1.0, green: 0.8, blue: 0.6)
        case "Saturn":  return Color(red: 0.9, green: 0.85, blue: 0.6)
        case "Uranus":  return Color(red: 0.6, green: 0.9, blue: 1.0)
        case "Neptune": return Color(red: 0.3, green: 0.5, blue: 1.0)
        default:        return .white
        }
    }

    private func drawHorizonLine(in ctx: GraphicsContext, size: CGSize) {
        var horizonPath = Path()
        var prevOnScreen = false

        for azDeg in stride(from: 0.0, through: 360.0, by: 2.0) {
            if let pt = vm.project(alt: 0, az: azDeg, in: size) {
                if !prevOnScreen { horizonPath.move(to: pt) }
                else             { horizonPath.addLine(to: pt) }
                prevOnScreen = true
            } else {
                prevOnScreen = false
            }
        }

        ctx.stroke(horizonPath, with: .color(Color.astroAmber.opacity(0.6)), lineWidth: 1.5)

        if let labelPt = vm.project(alt: 0, az: vm.centerAz, in: size) {
            ctx.draw(
                Text("HORIZON").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.astroAmber.opacity(0.5)),
                at: CGPoint(x: labelPt.x, y: labelPt.y - 8), anchor: .bottom
            )
        }
    }

    private func drawMountCrosshair(in ctx: GraphicsContext, size: CGSize) {
        guard let pt = vm.project(alt: vm.mountAlt, az: vm.mountAz, in: size) else { return }
        let arm: Double = 14
        var lines = Path()
        lines.move(to: CGPoint(x: pt.x-arm, y: pt.y)); lines.addLine(to: CGPoint(x: pt.x-5, y: pt.y))
        lines.move(to: CGPoint(x: pt.x+5,   y: pt.y)); lines.addLine(to: CGPoint(x: pt.x+arm, y: pt.y))
        lines.move(to: CGPoint(x: pt.x, y: pt.y-arm)); lines.addLine(to: CGPoint(x: pt.x, y: pt.y-5))
        lines.move(to: CGPoint(x: pt.x, y: pt.y+5));   lines.addLine(to: CGPoint(x: pt.x, y: pt.y+arm))
        ctx.stroke(lines, with: .color(Color.astroRed), lineWidth: 1.5)
        ctx.stroke(Path(ellipseIn: CGRect(x: pt.x-5, y: pt.y-5, width: 10, height: 10)),
                   with: .color(Color.astroRed), lineWidth: 1.5)
    }

    private func drawCardinalLabels(in ctx: GraphicsContext, size: CGSize) {
        for (label, az) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
            guard let pt = vm.project(alt: 3, az: az, in: size) else { continue }
            ctx.draw(
                Text(label).font(.system(size: 28, weight: .bold)).foregroundStyle(Color.white.opacity(0.65)),
                at: pt, anchor: .center
            )
        }
    }

    private func drawLegend(in ctx: GraphicsContext, size: CGSize) {
        let x: Double = 14
        var y = size.height - 144.0
        let step: Double = 16
        let entries: [(String, Color)] = [
            ("Sun",            .yellow),
            ("Moon",           .white),
            ("Planet",         Color(red: 1.0, green: 0.8, blue: 0.5)),
            ("Star",           .white),
            ("Open Cluster",   .yellow),
            ("Glob. Cluster",  .yellow),
            ("Nebula",         .green),
            ("Galaxy",         Color(red: 0.8, green: 0.6, blue: 1.0)),
            ("Planetary Neb.", .cyan),
        ]
        for (name, color) in entries {
            ctx.fill(Path(ellipseIn: CGRect(x: x-3, y: y-3, width: 6, height: 6)),
                     with: .color(color.opacity(0.65)))
            ctx.draw(
                Text(name).font(.system(size: 9)).foregroundStyle(Color.white.opacity(0.4)),
                at: CGPoint(x: x + 8, y: y), anchor: .leading
            )
            y += step
        }
    }

    private func drawHorizonLimit(in ctx: GraphicsContext, size: CGSize) {
        guard let limit = vm.horizonLimit, limit > -89 else { return }
        var path = Path()
        var prevOnScreen = false
        for azDeg in stride(from: 0.0, through: 360.0, by: 2.0) {
            if let pt = vm.project(alt: limit, az: azDeg, in: size) {
                if !prevOnScreen { path.move(to: pt) } else { path.addLine(to: pt) }
                prevOnScreen = true
            } else { prevOnScreen = false }
        }
        ctx.stroke(path, with: .color(Color.orange.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [8, 5]))
        if let pt = vm.project(alt: limit, az: vm.centerAz, in: size) {
            ctx.draw(
                Text("LIMIT \(Int(limit.rounded()))°").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.65)),
                at: CGPoint(x: pt.x, y: pt.y - 8), anchor: .bottom
            )
        }
    }

    private func drawOverheadLimit(in ctx: GraphicsContext, size: CGSize) {
        guard let limit = vm.overheadLimit, limit < 90 else { return }
        var path = Path()
        var prevOnScreen = false
        for azDeg in stride(from: 0.0, through: 360.0, by: 2.0) {
            if let pt = vm.project(alt: limit, az: azDeg, in: size) {
                if !prevOnScreen { path.move(to: pt) } else { path.addLine(to: pt) }
                prevOnScreen = true
            } else { prevOnScreen = false }
        }
        ctx.stroke(path, with: .color(Color.orange.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [8, 5]))
        let labelAz = vm.centerAz
        if let pt = vm.project(alt: limit, az: labelAz, in: size) {
            ctx.draw(
                Text("OVERHEAD \(Int(limit.rounded()))°").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.65)),
                at: CGPoint(x: pt.x, y: pt.y + 8), anchor: .top
            )
        }
    }

    private func drawMeridianLimits(in ctx: GraphicsContext, size: CGSize) {
        drawHALine(haDegrees: 0,
                   color: Color.white.opacity(0.22),
                   dashed: false,
                   label: "MERIDIAN",
                   in: ctx, size: size)

        if let ep = vm.meridianLimitEastPier {
            let deg = ep / 4.0
            drawHALine(haDegrees:  deg,
                       color: Color.yellow.opacity(0.6),
                       dashed: true,
                       label: "E-PIER \(Int(deg.rounded()))°",
                       in: ctx, size: size)
        }

        if let wp = vm.meridianLimitWestPier {
            let deg = wp / 4.0
            drawHALine(haDegrees: -deg,
                       color: Color.yellow.opacity(0.6),
                       dashed: true,
                       label: "W-PIER \(Int(deg.rounded()))°",
                       in: ctx, size: size)
        }
    }

    private func drawHALine(haDegrees: Double, color: Color, dashed: Bool, label: String,
                             in ctx: GraphicsContext, size: CGSize) {
        let ra = vm.lst - haDegrees / 15.0

        var path = Path()
        var prevOnScreen = false

        for decDeg in stride(from: -89.0, through: 89.0, by: 1.0) {
            let (alt, az) = vm.altAzFor(ra: ra, dec: decDeg)
            guard alt > 0 else { prevOnScreen = false; continue }
            guard let pt = vm.project(alt: alt, az: az, in: size) else { prevOnScreen = false; continue }
            if !prevOnScreen { path.move(to: pt) } else { path.addLine(to: pt) }
            prevOnScreen = true
        }

        ctx.stroke(path, with: .color(color),
                   style: dashed ? StrokeStyle(lineWidth: 1.5, dash: [8, 5]) : StrokeStyle(lineWidth: 1.0))

        for decDeg in stride(from: 85.0, through: -85.0, by: -5.0) {
            let (alt, az) = vm.altAzFor(ra: ra, dec: decDeg)
            guard alt > 5 else { continue }
            if let pt = vm.project(alt: alt, az: az, in: size) {
                ctx.draw(
                    Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(color),
                    at: CGPoint(x: pt.x + 4, y: pt.y), anchor: .leading
                )
                break
            }
        }
    }

    // MARK: - Milky Way

    private func drawMilkyWay(in ctx: GraphicsContext, size: CGSize) {
        let scale = vm.projectionScale(for: size)
        let blurR = scale * tan(8.0 * .pi / 180.0)
        let dotR  = max(3.0, blurR * 0.4)

        ctx.drawLayer { inner in
            inner.addFilter(.blur(radius: blurR))
            for (ra, dec, bAbs) in Self.milkyWayPoints {
                let (alt, az) = vm.altAzFor(ra: ra, dec: dec)
                guard alt > -8 else { continue }
                guard let pt = vm.project(alt: alt, az: az, in: size) else { continue }
                let opacity: Double = bAbs < 1 ? 0.55 : bAbs < 12 ? 0.28 : 0.10
                inner.fill(
                    Path(ellipseIn: CGRect(x: pt.x - dotR, y: pt.y - dotR,
                                          width: dotR * 2, height: dotR * 2)),
                    with: .color(Color(red: 0.3, green: 0.4, blue: 0.7).opacity(opacity))
                )
            }
        }
    }

    private static let milkyWayPoints: [(ra: Double, dec: Double, bAbs: Double)] = {
        var pts: [(Double, Double, Double)] = []
        for b in [0.0, 8.0, -8.0, 16.0, -16.0] {
            for l in stride(from: 0.0, through: 357.0, by: 3.0) {
                let (ra, dec) = galacticToEquatorial(lDeg: l, bDeg: b)
                pts.append((ra, dec, abs(b)))
            }
        }
        return pts
    }()

    private static func galacticToEquatorial(lDeg: Double, bDeg: Double) -> (ra: Double, dec: Double) {
        let l = lDeg * .pi / 180.0
        let b = bDeg * .pi / 180.0

        let agc  = 266.405   * .pi / 180.0
        let dgc  = -28.936   * .pi / 180.0
        let angp = 192.85948 * .pi / 180.0
        let dngp =  27.12825 * .pi / 180.0

        let e1x = cos(dgc)*cos(agc);  let e1y = cos(dgc)*sin(agc);  let e1z = sin(dgc)
        let e3x = cos(dngp)*cos(angp); let e3y = cos(dngp)*sin(angp); let e3z = sin(dngp)
        var e2x = e3y*e1z - e3z*e1y
        var e2y = e3z*e1x - e3x*e1z
        var e2z = e3x*e1y - e3y*e1x
        let mag = sqrt(e2x*e2x + e2y*e2y + e2z*e2z)
        e2x /= mag; e2y /= mag; e2z /= mag

        let px = cos(b)*cos(l)*e1x + cos(b)*sin(l)*e2x + sin(b)*e3x
        let py = cos(b)*cos(l)*e1y + cos(b)*sin(l)*e2y + sin(b)*e3y
        let pz = cos(b)*cos(l)*e1z + cos(b)*sin(l)*e2z + sin(b)*e3z

        let ra  = (atan2(py, px) * (180.0 / .pi) / 15.0 + 24.0).truncatingRemainder(dividingBy: 24.0)
        let dec = asin(max(-1.0, min(1.0, pz))) * (180.0 / .pi)
        return (ra, dec)
    }

    private func drawFOVIndicator(in ctx: GraphicsContext, size: CGSize) {
        let text = Text("FOV \(Int(vm.fovRadius.rounded()))°")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.4))
        ctx.draw(text, at: CGPoint(x: size.width - 8, y: 8), anchor: .topTrailing)
    }

    // MARK: - Selected Object Card

    private func objectCard(for obj: SkyObject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(obj.name).font(.headline)
                    Text(obj.cardSubtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { vm.selectedObject = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if goToIssued || telescope.mountStatus.isMoving {
                // GoTo issued or slew in progress — show Cancel so user can't queue another GoTo
                Button {
                    goToIssued = false
                    telescope.stopAll()
                } label: {
                    Label("Cancel GoTo", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .foregroundStyle(Color.white)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            } else {
                let buttonLabel = appState.isAligning
                    ? "GoTo — Align Star \(appState.alignmentNextStar)"
                    : "GoTo"

                Button {
                    if appState.isAligning {
                        appState.alignmentCurrentStarName = obj.name
                        appState.alignmentCurrentRA  = raString(obj.ra)
                        appState.alignmentCurrentDec = decString(obj.dec)
                    }
                    issueGoTo(obj)
                } label: {
                    Label(buttonLabel, systemImage: "location.north.line.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(telescope.isConnected ? Color.astroRed : Color.secondary.opacity(0.3))
                        .foregroundStyle(telescope.isConnected ? Color.white : Color.secondary)
                        .cornerRadius(8)
                }
                .disabled(!telescope.isConnected)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
        .padding(.bottom, 8)
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

    // MARK: - GoTo

    private func issueGoTo(_ obj: SkyObject) {
        goToIssued = true
        telescope.slewToTarget(ra: raString(obj.ra), dec: decString(obj.dec)) { error in
            guard error != nil else { return }
            // BT timeouts can lose the `:MS#` response while the mount is already slewing.
            // Give 2 s for isMoving to become true before reverting the Cancel button.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !telescope.mountStatus.isMoving { goToIssued = false }
            }
        }
    }

    private func raString(_ ra: Double) -> String {
        let h = Int(ra); let mt = (ra - Double(h)) * 60
        let m = Int(mt); let s  = Int((mt - Double(m)) * 60)
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func decString(_ dec: Double) -> String {
        let sign = dec >= 0 ? "+" : "-"; let a = abs(dec)
        let d = Int(a); let mt = (a - Double(d)) * 60
        let m = Int(mt); let s = Int((mt - Double(m)) * 60)
        return String(format: "%@%02d*%02d:%02d", sign, d, m, s)
    }

    private func dsoColor(_ type: SkyObjectType) -> Color {
        switch type {
        case .openCluster, .globularCluster: return .yellow
        case .nebula:                        return .green
        case .galaxy:                        return Color(red: 0.8, green: 0.6, blue: 1.0)
        case .planetaryNebula:               return .cyan
        default:                             return .white
        }
    }
}
