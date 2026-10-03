import DeviceHubCore
import SwiftUI

/// Shared dimensions that keep the custom device roster compact and tappable.
enum DeviceSidebarMetrics {
    static let cornerRadius: CGFloat = 14
    static let horizontalPadding: CGFloat = 16
    static let rowMinimumHeight: CGFloat = 68
}

struct DeviceSidebar: View {
    let devices: [DeviceSummary]
    let isLoading: Bool
    let selectedDeviceID: DeviceID?
    let detailsButtonTapped: (DeviceSummary) -> Void
    let deviceSelected: (DeviceID) -> Void
    let pairButtonTapped: () -> Void

    private var sections: DeviceListSections {
        DeviceListSections(devices: devices)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if devices.isEmpty {
                    emptyState
                } else {
                    deviceSection(
                        title: "Available",
                        devices: sections.available
                    )
                    deviceSection(
                        title: "Needs Attention",
                        devices: sections.needsAttention
                    )
                }

                pairButton
            }
            .padding(.horizontal, DeviceSidebarMetrics.horizontalPadding)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(.ultraThinMaterial)
        // The material sits over the near-black canvas in both appearances,
        // so light-mode foregrounds would be black on black. Render the
        // sidebar dark everywhere so text, rows, and material agree.
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .navigationTitle("Devices")
        .overlay {
            if isLoading, devices.isEmpty {
                ProgressView("Finding nearby devices…")
                    .controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 18))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No Paired Devices")
                .font(.headline)
            Text(
                "Pair a nearby device to see and control its screen."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func deviceSection(
        title: String,
        devices: [DeviceSummary]
    ) -> some View {
        if !devices.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(secondaryForeground)
                    .padding(.leading, 2)

                VStack(spacing: 8) {
                    ForEach(devices) { device in
                        DeviceRow(
                            device: device,
                            isSelected: device.id == selectedDeviceID,
                            detailsButtonTapped: {
                                detailsButtonTapped(device)
                            },
                            selectionTapped: {
                                deviceSelected(device.id)
                            }
                        )
                    }
                }
            }
        }
    }

    private var pairButton: some View {
        Button(action: pairButtonTapped) {
            HStack(spacing: 12) {
                Text(Image(systemName: "plus"))
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(accentForeground)
                    .background(
                        accentForeground.opacity(0.12),
                        in: .circle
                    )

                Text("Pair Nearby Device")
                    .font(.body.weight(.semibold))

                Spacer(minLength: 8)

                Text(Image(systemName: "chevron.right"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(secondaryForeground)
            }
            .foregroundStyle(primaryForeground)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 12)
            .contentShape(.rect(cornerRadius: DeviceSidebarMetrics.cornerRadius))
            .background(
                rowBackground,
                in: .rect(cornerRadius: DeviceSidebarMetrics.cornerRadius)
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: DeviceSidebarMetrics.cornerRadius
                )
                .strokeBorder(rowBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(
            "Shows instructions and a temporary pairing code."
        )
    }

    private var accentForeground: Color {
        Color(red: 0.48, green: 0.52, blue: 1)
    }

    private var primaryForeground: Color {
        .white
    }

    private var secondaryForeground: Color {
        .white.opacity(0.72)
    }

    private var rowBackground: Color {
        .white.opacity(0.055)
    }

    private var rowBorder: Color {
        .white.opacity(0.08)
    }
}

private struct DeviceRow: View {
    let device: DeviceSummary
    let isSelected: Bool
    let detailsButtonTapped: () -> Void
    let selectionTapped: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: selectionTapped) {
                HStack(spacing: 11) {
                    Text(Image(systemName: deviceSymbolName))
                        .font(.title3)
                        .frame(width: 30)
                        .foregroundStyle(
                            device.reachability == .reachable
                                ? AnyShapeStyle(accentForeground)
                                : AnyShapeStyle(secondaryForeground)
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(primaryForeground)
                            .lineLimit(1)

                        HStack(spacing: 5) {
                            Text(
                                Image(
                                    systemName:
                                    device.deviceHubAvailabilitySymbol
                                )
                            )
                            Text(device.deviceHubAvailabilityLabel)
                        }
                        .font(.caption)
                        .foregroundStyle(statusForeground)
                    }

                    Spacer(minLength: 4)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: DeviceSidebarMetrics.rowMinimumHeight
                )
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(device.name), \(device.deviceHubAvailabilityLabel)"
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button(
                action: detailsButtonTapped,
                label: {
                    Text(Image(systemName: "info.circle"))
                        .foregroundStyle(secondaryForeground)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
            )
            .buttonStyle(.plain)
            .accessibilityLabel("Details for \(device.name)")
        }
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .background(
            rowBackground,
            in: .rect(cornerRadius: DeviceSidebarMetrics.cornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DeviceSidebarMetrics.cornerRadius)
                .strokeBorder(rowBorder, lineWidth: isSelected ? 1.25 : 1)
        }
    }

    private var accentForeground: Color {
        Color(red: 0.48, green: 0.52, blue: 1)
    }

    private var primaryForeground: Color {
        .white
    }

    private var secondaryForeground: Color {
        .white.opacity(0.72)
    }

    private var statusForeground: Color {
        if device.pairingState == .requiresPairing
            || device.reachability == .unavailable
        {
            return Color.orange.opacity(0.9)
        }
        return secondaryForeground
    }

    private var rowBackground: Color {
        if isSelected {
            return accentForeground.opacity(0.16)
        }
        return .white.opacity(0.055)
    }

    private var rowBorder: Color {
        if isSelected {
            return accentForeground.opacity(0.72)
        }
        return .white.opacity(0.08)
    }

    private var deviceSymbolName: String {
        device.productType.localizedCaseInsensitiveContains("ipad")
            ? "ipad"
            : "iphone"
    }
}
