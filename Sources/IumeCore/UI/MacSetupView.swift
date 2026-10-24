import SwiftUI

/// Beautiful system health & setup checklist displaying live environment and conflict status.
public struct MacSetupView: View {
    @ObservedObject var checker = MacSetupChecker.shared
    
    public init() {}
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mac Setup & Compatibility Inspector")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Live environment checks for optimal 120 FPS continuous slide window management.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: {
                    checker.refreshChecks()
                }) {
                    Label("Recheck Now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 4)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(checker.checkResults) { item in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: item.isOptimal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.title3)
                                .foregroundColor(item.isOptimal ? .green : .orange)
                                .frame(width: 28)
                            
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.title)
                                        .font(.headline)
                                    Spacer()
                                    Text(item.statusMessage)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(item.isOptimal ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                                        .foregroundColor(item.isOptimal ? .green : .orange)
                                        .cornerRadius(6)
                                }
                                
                                Text(item.recommendation)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                
                                if item.id == "trackpad_swipe_conflict" && !item.isOptimal {
                                    Button("Fix Now: Disable macOS 3/4-Finger Desktop Swipe") {
                                        checker.disableConflictingDesktopSwipe()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .padding(.top, 4)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(item.isOptimal ? Color.green.opacity(0.2) : Color.orange.opacity(0.3), lineWidth: 1)
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 460)
        .onAppear {
            checker.refreshChecks()
        }
    }
}
