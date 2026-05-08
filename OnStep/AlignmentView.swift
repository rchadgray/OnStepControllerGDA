import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// AlignmentPanelView
//
// Sheet presented from SkyChartView during a star alignment session.
// The user picks and GoTos stars on the sky chart; this panel appears
// automatically after each slew completes so they can nudge and accept.
//
// States:
//   • Nudge/Accept  — D-pad + ✓ button + GoTo Again
//   • Complete      — polar error summary + Done button
//
// LX200 commands:
//   :CM#   — accept current star (sync)
//   :A?#   — query alignment progress
//   :GX02# / :GX03# — polar residuals after final accept
// ─────────────────────────────────────────────────────────────────────────────
struct AlignmentPanelView: View {
    @EnvironmentObject var telescope: OnStepManager
    @Environment(AppState.self) var appState

    @State private var isSlewing = false

    var body: some View {
        NavigationStack {
            Group {
                if appState.alignmentIsComplete {
                    completionView
                } else {
                    nudgeView
                }
            }
            .navigationTitle(appState.alignmentIsComplete
                             ? "Alignment Complete"
                             : "Star \(appState.alignmentNextStar) of \(appState.alignmentTotalStars)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !appState.alignmentIsComplete {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Skip") {
                            appState.alignmentShowPanel = false
                        }
                    }
                }
            }
        }
    }

    // MARK: - Nudge / Accept View

    private var nudgeView: some View {
        VStack(spacing: 16) {
            // Star name + instruction
            VStack(spacing: 6) {
                if !appState.alignmentCurrentStarName.isEmpty {
                    Text(appState.alignmentCurrentStarName)
                        .font(.headline)
                        .foregroundStyle(Color.astroAmber)
                }
                Text(isSlewing
                     ? "Slewing — wait for the mount to arrive."
                     : "Nudge until centered in the eyepiece, then tap Accept.")
                    .font(.caption)
                    .foregroundStyle(isSlewing ? Color.astroAmber : .secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 8)

            // Progress bar — accepted stars so far
            ProgressView(value: Double(max(0, appState.alignmentNextStar - 1)),
                         total: Double(max(1, appState.alignmentTotalStars)))
                .tint(Color.astroRed)
                .padding(.horizontal)

            // D-pad with Accept in the centre
            alignmentControlPad

            // Slew rate picker
            SlewRatePicker()

            // GoTo Again — re-slews to the same object if the mount overshot
            Button { slewAgain() } label: {
                Label("GoTo Again", systemImage: "location.north.line.fill")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.astroRed.opacity(0.12))
                    .foregroundStyle(Color.astroRed)
                    .cornerRadius(12)
            }
            .disabled(appState.alignmentCurrentRA.isEmpty || isSlewing)
            .buttonStyle(.plain)
            .padding(.horizontal)

            Spacer(minLength: 0)
        }
    }

    // D-pad with green Accept button in the centre
    private var alignmentControlPad: some View {
        VStack(spacing: 14) {
            DPadButton(icon: "chevron.up",
                       onPress: telescope.moveNorth, onRelease: telescope.stopNorth)
            HStack(spacing: 40) {
                DPadButton(icon: "chevron.left",
                           onPress: telescope.moveWest, onRelease: telescope.stopWest)

                Button { acceptCurrentStar() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .bold))
                        Text("Accept")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Color.green.opacity(0.85))
                    .clipShape(Circle())
                    .shadow(color: Color.green.opacity(0.3), radius: 6)
                }
                .buttonStyle(.plain)
                .disabled(isSlewing)

                DPadButton(icon: "chevron.right",
                           onPress: telescope.moveEast, onRelease: telescope.stopEast)
            }
            DPadButton(icon: "chevron.down",
                       onPress: telescope.moveSouth, onRelease: telescope.stopSouth)
        }
        .disabled(!telescope.isConnected || isSlewing)
        .opacity(telescope.isConnected && !isSlewing ? 1.0 : 0.4)
    }

    // MARK: - Completion View

    private var completionView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.astroRed)
                    Text("Alignment Complete")
                        .font(.title2).fontWeight(.bold)
                    Text("\(appState.alignmentStarCount)-star alignment recorded.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                VStack(spacing: 0) {
                    HStack {
                        Text("Polar Alignment Residuals").font(.headline)
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 10)

                    polarErrorRow("Altitude Error", value: telescope.mountStatus.polarAltError)
                    Divider().padding(.horizontal)
                    polarErrorRow("Azimuth Error",  value: telescope.mountStatus.polarAzError)
                }
                .padding(.vertical, 12)
                .background(Color.astroRed.opacity(0.06))
                .cornerRadius(12)
                .padding(.horizontal)

                Text("Adjust the mount's alt/az bolts to reduce both values toward zero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                Button {
                    appState.alignmentShowPanel = false
                    appState.endAlignment()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.astroRed)
                        .foregroundStyle(Color.white)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func polarErrorRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if value == "--" || value == "0" {
                ProgressView().controlSize(.small)
            } else {
                Text("\(value)'")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.astroAmber)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func acceptCurrentStar() {
        let name = appState.alignmentCurrentStarName
        if !name.isEmpty { appState.alignmentUsedStarNames.append(name) }
        appState.alignmentCurrentStarName = ""

        telescope.alignmentSync {
            telescope.queryAlignmentStatus { _, next, total in
                let done = total > 0 && (next == 0 || next > total)
                if done {
                    telescope.queryPolarError(forced: true)
                    appState.alignmentIsComplete = true
                } else {
                    appState.alignmentNextStar  = next
                    appState.alignmentShowPanel = false   // back to sky chart for next star
                }
            }
        }
    }

    private func slewAgain() {
        guard !appState.alignmentCurrentRA.isEmpty else { return }
        isSlewing = true
        telescope.slewToTarget(ra: appState.alignmentCurrentRA,
                               dec: appState.alignmentCurrentDec) { _ in
            isSlewing = false
        }
    }
}
