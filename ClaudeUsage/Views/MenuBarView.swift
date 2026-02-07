import SwiftUI

// MARK: - Layout Helpers

private enum LayoutHelper {
    static let primaryItemKeys: Set<String> = ["five_hour", "seven_day"]

    /// Split items into primary and others, with pre-computed grid rows for others
    static func layoutItems(_ items: [UsageItem]) -> (primary: [UsageItem], gridRows: [[UsageItem]]) {
        var primary: [UsageItem] = []
        var others: [UsageItem] = []

        for item in items {
            if primaryItemKeys.contains(item.key) {
                primary.append(item)
            } else {
                others.append(item)
            }
        }

        // Pre-compute grid rows (2 items per row)
        let gridRows = stride(from: 0, to: others.count, by: 2).map { index in
            Array(others[index..<min(index + 2, others.count)])
        }

        return (primary, gridRows)
    }
}

struct ExtraUsageToggleButton: View {
    let isEnabled: Bool
    let onToggle: (Bool) async throws -> Void

    @State private var isUpdating = false
    @State private var isHovered = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                guard !isUpdating else { return }
                isUpdating = true
                errorMessage = nil
                Task {
                    do {
                        try await onToggle(!isEnabled)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isUpdating = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isUpdating {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 8, height: 8)
                    } else {
                        Circle()
                            .fill(isEnabled ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }

                    Text(isUpdating ? "Updating" : (isEnabled ? "Enabled" : "Disabled"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isUpdating ? .secondary : (isEnabled ? .primary : .secondary))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isEnabled ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isHovered ? (isEnabled ? Color.green.opacity(0.3) : Color.secondary.opacity(0.3)) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
            .help(isEnabled ? "Click to disable extra usage" : "Click to enable extra usage")

            if let error = errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 10) {
            contentView
            footerView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: Constants.UI.menuBarWidth)
    }

    // MARK: - Content Views

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.authState {
        case .authenticated:
            authenticatedView
        case .notAuthenticated, .unknown:
            notAuthenticatedView
        case .authenticating:
            authenticatingView
        case .error(let message):
            errorView(message: message)
        }
    }

    private var authenticatedView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header with tier and last updated time
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Usage")
                    .font(.system(size: 14, weight: .semibold))

                if let tierName = viewModel.authState.tierDisplayName {
                    Text(tierName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(
                            red: Constants.Colors.claudeOrange.red,
                            green: Constants.Colors.claudeOrange.green,
                            blue: Constants.Colors.claudeOrange.blue
                        ))
                        .cornerRadius(4)
                }

                Spacer()

                lastUpdatedView
            }

            // Usage cards - dynamically render all items
            usageCardsView

            // Extra Usage section
            extraUsageSectionView

            // Error message
            if let error = viewModel.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var usageCardsView: some View {
        if let summary = viewModel.usageSummary {
            if summary.items.isEmpty {
                placeholderCard(title: "No Usage Data")
            } else if summary.items.count <= Constants.UI.compactLayoutThreshold {
                // Normal layout: all items as full-width cards
                ForEach(summary.items) { item in
                    UsageCardView(item: item)
                }
            } else {
                // Compact layout: primary items as cards, others as 2-column grid
                let layout = LayoutHelper.layoutItems(summary.items)

                ForEach(layout.primary) { item in
                    UsageCardView(item: item)
                }

                compactGridView(rows: layout.gridRows)
            }
        } else {
            placeholderCard(title: "Loading...")
        }
    }

    /// 2-column grid for compact display (pre-computed rows)
    @ViewBuilder
    private func compactGridView(rows: [[UsageItem]]) -> some View {
        ForEach(rows.indices, id: \.self) { rowIndex in
            let row = rows[rowIndex]
            HStack(spacing: 8) {
                ForEach(row) { item in
                    UsageCardCompactView(item: item)
                }
                // Fill remaining space if odd number of items
                if row.count == 1 {
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var extraUsageSectionView: some View {
        if let extra = viewModel.extraUsage, let spendLimit = extra.spendLimit {
            extraUsageSection(extra: extra, spendLimit: spendLimit)
        } else if viewModel.usageSummary != nil && viewModel.extraUsage == nil {
            // Show placeholder while extra usage is loading (usage data loaded but extra not yet)
            extraUsagePlaceholder
        }
        // If usageSummary is nil, we're still loading everything - don't show extra usage area
    }

    @ViewBuilder
    private var extraUsagePlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row - match toggle button height
            HStack {
                Text("Extra Usage")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                // Placeholder for toggle button to match height
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 8, height: 8)
                    Text("Loading")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
            }

            // Spending section - match real content heights
            VStack(alignment: .leading, spacing: 6) {
                // Amounts row - font size 20 bold ≈ 24px
                HStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 70, height: 24)

                    Spacer()

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 90, height: 16)
                }
                .frame(height: 24)

                // Progress bar
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 6)

                // Balance row - font size 11 is ~14px
                HStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 60, height: 14)

                    Spacer()

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 120, height: 14)
                }
            }

            // Manage in browser button (always visible to prevent layout shift)
            Button {
                openURL("https://claude.ai/settings/usage")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                    Text("Manage in Browser")
                        .font(.system(size: 11))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(6)
    }

    @ViewBuilder
    private func extraUsageSection(extra: ExtraUsageSummary, spendLimit: OverageSpendLimit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with toggle
            HStack(alignment: .center) {
                Text("Extra Usage")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                ExtraUsageToggleButton(
                    isEnabled: spendLimit.isEnabled,
                    onToggle: viewModel.toggleExtraUsage
                )
            }

            // Spending progress section
            VStack(alignment: .leading, spacing: 6) {
                // Amounts row
                HStack(alignment: .firstTextBaseline) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(spendLimit.formattedUsedCredits)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(spendingColor(percentage: spendLimit.usedPercentage))

                        Text("spent")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(spendLimit.usedPercentage)%")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)

                        Text("of")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Text(spendLimit.formattedMonthlyLimit)
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundColor(.secondary)
                    }
                }

                // Progress bar
                GeometryReader { geometry in
                    let normalizedPercentage = min(max(Double(spendLimit.usedPercentage), 0), 100) / 100.0
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color(nsColor: .separatorColor))

                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(spendingColor(percentage: spendLimit.usedPercentage))
                            .frame(width: geometry.size.width * normalizedPercentage)
                    }
                }
                .frame(height: 6)

                // Balance and info row
                HStack(alignment: .center, spacing: 0) {
                    if let balance = extra.formattedBalance {
                        HStack(spacing: 4) {
                            Image(systemName: "creditcard")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(balance)
                                .font(.system(size: 11, weight: .medium))
                        }

                        Spacer()
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(extra.isAutoReloadOn ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 6, height: 6)
                        Text(extra.isAutoReloadOn ? "Auto-reload" : "No auto-reload")
                            .font(.system(size: 11))
                            .foregroundColor(extra.isAutoReloadOn ? .primary : .secondary)
                    }

                    if extra.formattedBalance == nil {
                        Spacer()
                    }

                    Text("·")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)

                    Text(spendLimit.resetDateDisplay)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // Manage in browser button
            Button {
                openURL("https://claude.ai/settings/usage")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "safari")
                        .font(.system(size: 11))
                    Text("Manage in Browser")
                        .font(.system(size: 11))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(6)
    }

    private func spendingColor(percentage: Int) -> Color {
        UsageStatusLevel.from(percentage: percentage).color
    }

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString),
              url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func placeholderCard(title: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Text("–")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                    .fixedSize()

                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(6)
    }

    private var lastUpdatedView: some View {
        HStack(alignment: .center, spacing: 4) {
            if viewModel.isRefreshing {
                ProgressView()
                    .scaleEffect(0.45)
                    .frame(width: 11, height: 11)
            } else if viewModel.usageSummary != nil {
                if viewModel.isPrimaryAtLimit {
                    // Show countdown to reset time
                    Text(formatResetCountdown(viewModel.secondsUntilNextRefresh))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else if viewModel.secondsUntilNextRefresh > 0 {
                    // Show countdown to next auto-refresh
                    Text(formatCountdown(viewModel.secondsUntilNextRefresh))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                        .scaleEffect(0.45)
                        .frame(width: 11, height: 11)
                }

                Button {
                    Task { await viewModel.refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Refresh now")
            }
        }
        .padding(.trailing, 2)
    }

    private func formatCountdown(_ seconds: Int) -> String {
        if seconds <= 0 {
            return "Refreshing..."
        } else if seconds < Constants.Time.secondsPerMinute {
            return "in \(seconds)s"
        } else {
            return "in \(seconds / Constants.Time.secondsPerMinute)m"
        }
    }

    private func formatResetCountdown(_ seconds: Int) -> String {
        if seconds <= 0 {
            return "Resetting..."
        }
        let hours = seconds / Constants.Time.secondsPerHour
        let minutes = (seconds % Constants.Time.secondsPerHour) / Constants.Time.secondsPerMinute
        if hours > 0 {
            return "resets in \(hours)h \(minutes)m"
        } else {
            return "resets in \(minutes)m"
        }
    }

    private var notAuthenticatedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("Not Logged In")
                .font(.system(size: 13, weight: .medium))

            Text("Log in to Claude.ai to view usage")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Button {
                AppDelegate.shared.openLoginWindow()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 12))
                    Text("Log In")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }

    private var authenticatingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)

            Text("Checking login status...")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 20)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundColor(.orange)

            Text("Error")
                .font(.system(size: 13, weight: .medium))

            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task { await viewModel.authService.checkStoredCredentials() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("Retry")
                        .font(.system(size: 11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Constants.Colors.cardBackground)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 8) {
            if viewModel.authState.isAuthenticated {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: -1) {
                        Text("Auto Refresh")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("API polling interval")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    Spacer()

                    Picker("", selection: $viewModel.settings.refreshIntervalRaw) {
                        ForEach(RefreshInterval.allCases, id: \.rawValue) { interval in
                            Text(interval.label).tag(interval.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 70)
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: -2) {
                        Text("5-Hour Reset Alert")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("Sound when quota resets")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    Spacer()

                    Picker("", selection: $viewModel.settings.resetSoundRaw) {
                        ForEach(ResetSound.allCases, id: \.rawValue) { sound in
                            Text(sound.label).tag(sound.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 70)
                    .onChange(of: viewModel.settings.resetSoundRaw) { newValue in
                        ResetSound(rawValue: newValue)?.play()
                    }
                }

                HStack(spacing: 10) {
                    FooterButton(title: "Log Out", icon: "rectangle.portrait.and.arrow.right") {
                        Task { await viewModel.logout() }
                    }

                    FooterButton(title: "Quit", icon: "xmark.circle") {
                        viewModel.quit()
                    }
                }
                .padding(.top, 4)
            } else {
                FooterButton(title: "Quit", icon: "xmark.circle") {
                    viewModel.quit()
                }
            }
        }
    }
}

struct FooterButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Constants.Colors.cardBackground)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

