import SwiftUI
import Charts
import AppKit
import FanFiCore

// MARK: - Menu bar label (the chip in the status bar)

struct MenuBarLabel: View {
    @Bindable var monitor: StatusMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
            if let t = monitor.hottestSensor {
                Text("\(Int(t.celsius.rounded()))°")
                    .monospacedDigit()
            }
        }
    }

    private var iconName: String {
        guard let t = monitor.hottestSensor?.celsius else { return "fan" }
        switch t {
        case ..<55: return "fan"
        case ..<75: return "fan.fill"
        default:    return "thermometer.high"
        }
    }
}

// MARK: - Popover body

struct MenuBarView: View {
    @Bindable var monitor: StatusMonitor
    @Bindable var presets: PresetController
    @Bindable var installer: HelperInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let err = monitor.initError {
                Text("Cannot read SMC")
                    .font(.headline)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                installerBanner
                presetRow
                Divider()
                temperatureSection
                Divider()
                fanSection
                if monitor.tempHistory.count > 4 {
                    Divider()
                    chartsSection
                }
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    @ViewBuilder
    private var installerBanner: some View {
        switch installer.status {
        case .enabled:
            EmptyView()  // happy path, no banner
        case .notFound:
            // macOS 26 returns .notFound for ad-hoc-signed daemons. Until
            // SMAppService can be exercised with a notarised build we hide
            // this and rely on the manual LaunchDaemon install instead
            // (see Resources/launchd/install-helper.sh).
            EmptyView()
        case .notRegistered:
            installerCallout(
                tint: .blue,
                icon: "arrow.down.circle.fill",
                title: "Install helper",
                message: "Register the FanFiHelper LaunchDaemon to enable fan control.",
                actionLabel: "Install",
                action: { installer.install() }
            )
        case .requiresApproval:
            installerCallout(
                tint: .orange,
                icon: "exclamationmark.circle.fill",
                title: "Helper needs approval",
                message: "Open Login Items & Extensions in System Settings and enable FanFi.",
                actionLabel: "Open Settings",
                action: { installer.openLoginItemsSettings() }
            )
        case .error(let msg):
            installerCallout(
                tint: .red,
                icon: "exclamationmark.triangle.fill",
                title: "Installer error",
                message: msg,
                actionLabel: "Retry",
                action: { installer.install() }
            )
        }
    }

    private func installerCallout(
        tint: Color,
        icon: String,
        title: String,
        message: String,
        actionLabel: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold())
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionLabel, let action {
                    Button(actionLabel, action: action)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(0.3), lineWidth: 1)
        )
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Preset")
                Spacer()
                presetStatusText
            }
            HStack(spacing: 6) {
                ForEach(MenuPreset.allCases) { preset in
                    PresetButton(
                        preset: preset,
                        isActive: presets.active == preset,
                        isApplying: { if case .applying(let p) = presets.status, p == preset { return true }; return false }(),
                        action: { presets.apply(preset) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var presetStatusText: some View {
        switch presets.status {
        case .idle:
            EmptyView()
        case .applying(let p):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("applying \(p.label)…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .running(let p):
            Text("active: \(p.label)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .helperUnreachable(let msg):
            Text("helper: \(msg)")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(msg)
        case .error(let msg):
            Text(msg)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(msg)
        }
    }

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Temperatures")
            ForEach(monitor.temps.sorted { $0.celsius > $1.celsius }.prefix(6), id: \.key) { t in
                HStack {
                    Text(t.key)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(String(format: "%.1f °C", t.celsius))
                        .monospacedDigit()
                        .foregroundStyle(tempColor(t.celsius))
                }
            }
        }
    }

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("Fans")
            if monitor.fans.isEmpty {
                Text("No fans detected").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.fans, id: \.index) { f in
                    HStack {
                        Text("F\(f.index)")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 28, alignment: .leading)
                        Spacer()
                        Text("\(Int(f.actual)) RPM")
                            .monospacedDigit()
                        Text(f.modeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var chartsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Last \(historyMinutes) min")

            // Temperature trace
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Temp").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(rangeLabel(monitor.tempHistory, unit: "°C", format: "%.1f"))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Chart(monitor.tempHistory) { s in
                    LineMark(x: .value("t", s.date), y: .value("°C", s.value))
                        .foregroundStyle(.orange)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 38)
            }

            // RPM trace with target overlay
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("RPM").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(rangeLabel(monitor.rpmHistory, unit: "RPM", format: "%.0f"))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(monitor.targetHistory) { s in
                        LineMark(x: .value("t", s.date), y: .value("Target", s.value))
                            .foregroundStyle(.blue.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    ForEach(monitor.rpmHistory) { s in
                        LineMark(x: .value("t", s.date), y: .value("Actual", s.value))
                            .foregroundStyle(.blue)
                            .interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 38)
            }
        }
    }

    private func rangeLabel(_ samples: [StatusMonitor.TimedSample], unit: String, format: String) -> String {
        guard let lo = samples.map({ $0.value }).min(),
              let hi = samples.map({ $0.value }).max() else { return "—" }
        if hi - lo < 0.1 {
            return String(format: "\(format) \(unit)", hi)
        }
        return String(format: "\(format)–\(format) \(unit)", lo, hi)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let hw = monitor.hardware {
                Text("\(hw.modeKeyFormat)  Ftst: \(hw.ftstAvailable ? "✓" : "✗")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            helperBadge
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var helperBadge: some View {
        if case .helperUnreachable = presets.status {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("helper offline")
            }
            .font(.caption2)
            .foregroundStyle(.orange)
            .help("FanFiHelper isn't reachable. Install via Resources/launchd/install-helper.sh.")
        } else if let snap = presets.helperSnapshot {
            HStack(spacing: 3) {
                Image(systemName: "bolt.horizontal.circle.fill")
                Text("helper #\(snap.pid)")
            }
            .font(.caption2)
            .foregroundStyle(.green)
            .help("FanFiHelper pid \(snap.pid), protocol v\(snap.protocolVersion)")
        }
    }

    private var historyMinutes: Int {
        guard let first = monitor.tempHistory.first?.date,
              let last  = monitor.tempHistory.last?.date else { return 0 }
        return max(1, Int(last.timeIntervalSince(first) / 60))
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func tempColor(_ c: Float) -> Color {
        switch c {
        case ..<50: return .green
        case ..<70: return .orange
        default:    return .red
        }
    }
}

// MARK: - Preset button

struct PresetButton: View {
    let preset: MenuPreset
    let isActive: Bool
    let isApplying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if isApplying {
                    ProgressView().controlSize(.mini)
                        .frame(height: 16)
                } else {
                    Image(systemName: preset.icon)
                        .font(.system(size: 14))
                        .frame(height: 16)
                }
                Text(preset.label)
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor.opacity(0.20) : Color.gray.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 1)
            )
            .foregroundStyle(isActive ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .disabled(isApplying)
    }
}
