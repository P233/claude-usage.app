import SwiftUI

extension UsageStatusLevel {
    var color: Color {
        switch self {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct UsageCardView: View {
    let item: UsageItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title row with reset time
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayTitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()

                if let resetTime = item.useLongResetDisplay ? item.resetTimeDisplayLong : item.resetTimeDisplay {
                    Text(resetTime)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            // Usage percentage and progress bar
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(item.utilization)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(item.statusLevel.color)

                    Text("%")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(item.statusLevel.color)
                }
                .fixedSize()

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color(nsColor: .separatorColor))

                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(item.statusLevel.color)
                            .frame(width: geometry.size.width * min(item.percentage, 1.0))
                    }
                }
                .frame(height: 6)
            }

            // Show parse error if any
            if let error = item.parseError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
            }
        }
        .padding(10)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(6)
    }
}

/// Compact version for grid layout (2 per row)
struct UsageCardCompactView: View {
    let item: UsageItem

    var body: some View {
        HStack(spacing: 8) {
            // Circular progress indicator
            ZStack {
                Circle()
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 3)

                Circle()
                    .trim(from: 0, to: min(item.percentage, 1.0))
                    .stroke(item.statusLevel.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                // Title (shortened)
                Text(item.compactTitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                // Percentage
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(item.utilization)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(item.statusLevel.color)

                    Text("%")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(item.statusLevel.color)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Constants.Colors.cardBackground)
        .cornerRadius(6)
    }
}

#Preview("Full Cards") {
    VStack(spacing: 8) {
        UsageCardView(
            item: UsageItem(key: "five_hour", utilization: 66, resetsAt: Date().addingTimeInterval(3600))
        )

        UsageCardView(
            item: UsageItem(key: "seven_day", utilization: 45, resetsAt: Date().addingTimeInterval(86400 * 3))
        )

        UsageCardView(
            item: UsageItem(key: "seven_day_opus", utilization: 100, resetsAt: Date().addingTimeInterval(1800))
        )

        UsageCardView(
            item: UsageItem(key: "iguana_necktie", utilization: 25, resetsAt: nil)
        )
    }
    .padding()
    .frame(width: 280)
}

#Preview("Compact Grid") {
    VStack(spacing: 8) {
        // Full cards for primary items
        UsageCardView(
            item: UsageItem(key: "five_hour", utilization: 66, resetsAt: Date().addingTimeInterval(3600))
        )

        UsageCardView(
            item: UsageItem(key: "seven_day", utilization: 45, resetsAt: Date().addingTimeInterval(86400 * 3))
        )

        // Compact grid for other items
        HStack(spacing: 8) {
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_opus", utilization: 100, resetsAt: nil)
            )
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_sonnet", utilization: 85, resetsAt: nil)
            )
        }

        HStack(spacing: 8) {
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_haiku", utilization: 30, resetsAt: nil)
            )
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_code", utilization: 55, resetsAt: nil)
            )
        }

        HStack(spacing: 8) {
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_vision", utilization: 12, resetsAt: nil)
            )
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_tools", utilization: 92, resetsAt: nil)
            )
        }

        HStack(spacing: 8) {
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_api", utilization: 78, resetsAt: nil)
            )
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_oauth", utilization: 5, resetsAt: nil)
            )
        }
    }
    .padding()
    .frame(width: 280)
}

#Preview("Compact Only") {
    VStack(spacing: 8) {
        HStack(spacing: 8) {
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_opus", utilization: 100, resetsAt: nil)
            )
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_sonnet", utilization: 85, resetsAt: nil)
            )
        }

        HStack(spacing: 8) {
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_haiku", utilization: 30, resetsAt: nil)
            )
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_code", utilization: 55, resetsAt: nil)
            )
        }

        HStack(spacing: 8) {
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_vision", utilization: 12, resetsAt: nil)
            )
            UsageCardCompactView(
                item: UsageItem(key: "seven_day_tools", utilization: 92, resetsAt: nil)
            )
        }
    }
    .padding()
    .frame(width: 280)
}
