import SwiftUI

struct HomingView: View {
    @EnvironmentObject var telescope: OnStepManager
    @Binding var isPresented: Bool
    @State private var pulse = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                if telescope.mountStatus.isHoming {
                    // Pulsing ring animation while the mount is searching.
                    ZStack {
                        Circle()
                            .stroke(Color.astroRed.opacity(0.15), lineWidth: 3)
                            .frame(width: 140, height: 140)

                        Circle()
                            .stroke(Color.astroRed.opacity(pulse ? 0.0 : 0.4), lineWidth: 3)
                            .frame(width: pulse ? 170 : 140, height: pulse ? 170 : 140)
                            .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false),
                                       value: pulse)

                        ProgressView()
                            .controlSize(.large)
                            .tint(Color.astroRed)
                    }
                    .onAppear { pulse = true }

                    VStack(spacing: 8) {
                        Text("Finding Home")
                            .font(.title2).fontWeight(.bold)
                        Text("The mount is moving to its home position…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    Image(systemName: "house.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Color.astroRed)

                    VStack(spacing: 8) {
                        Text("At Home Position")
                            .font(.title2).fontWeight(.bold)
                        Text("The mount has found its home position.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        isPresented = false
                    } label: {
                        Text("Done")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.astroRed)
                            .foregroundStyle(.white)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 32)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Find Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if telescope.mountStatus.isHoming {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Stop") {
                            telescope.cancelHoming()
                            isPresented = false
                        }
                        .foregroundStyle(Color.astroRed)
                    }
                }
            }
            .interactiveDismissDisabled(telescope.mountStatus.isHoming)
            .onDisappear {
                if telescope.mountStatus.isHoming { telescope.cancelHoming() }
            }
        }
    }
}
