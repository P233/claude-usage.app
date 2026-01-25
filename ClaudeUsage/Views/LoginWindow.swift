import SwiftUI

// MARK: - Loading Overlay Component

private struct LoadingOverlay: View {
    let title: String
    var backgroundOpacity: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)

            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(backgroundOpacity))
    }
}

// MARK: - Login Window

struct LoginWindow: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var isPageLoading = true
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ZStack {
                LoginWebView(
                    onLoginSuccess: handleLoginSuccess,
                    onLoginFailed: handleLoginFailed,
                    onLoadingStateChanged: { isPageLoading = $0 }
                )

                if isPageLoading {
                    LoadingOverlay(title: "Loading...")
                } else if isLoading {
                    LoadingOverlay(title: "Completing login...", backgroundOpacity: 0.95)
                }
            }

            if let error = errorMessage {
                errorBanner(error)
            }
        }
        .frame(
            width: Constants.UI.loginWindowWidth,
            height: Constants.UI.loginWindowHeight
        )
        .onAppear(perform: bringWindowToFront)
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            Text(Constants.UI.loginWindowTitle)
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)

            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                errorMessage = nil
            } label: {
                Text("Retry")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Actions

    private func bringWindowToFront() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Find window by identifier pattern instead of fragile title string
            if let window = NSApplication.shared.windows.first(where: { $0.identifier?.rawValue.contains("login") == true }) {
                window.makeKeyAndOrderFront(nil)
                window.level = .floating
            }
        }
    }

    private func handleLoginSuccess(_ cookies: [HTTPCookie]) {
        isLoading = true
        errorMessage = nil

        Task {
            await viewModel.onLoginSuccess(cookies: cookies)

            await MainActor.run {
                if let error = viewModel.lastError {
                    errorMessage = "Login failed: \(error)"
                    isLoading = false
                } else if viewModel.authState.isAuthenticated {
                    dismiss()
                } else {
                    errorMessage = "Login failed: Authentication state not updated"
                    isLoading = false
                }
            }
        }
    }

    private func handleLoginFailed(_ error: Error) {
        errorMessage = error.localizedDescription
        isLoading = false
    }
}
