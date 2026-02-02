import SwiftUI
import AppKit
import Combine

/// Custom AppDelegate to manage NSStatusItem for multi-line menubar display
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    static private(set) var shared: AppDelegate!

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var loginWindow: NSWindow?
    private var eventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    /// Reusable hosting view for status bar content (prevents memory leaks)
    private var statusBarHostingView: NSHostingView<StatusBarContentView>?

    /// Shared view model accessible throughout the app
    @Published var viewModel = AppViewModel()

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy for menubar-only app
        NSApplication.shared.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        observeViewModelChanges()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.action = #selector(togglePopover)
        button.target = self

        updateStatusBarContent()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: Constants.UI.menuBarWidth, height: 500)
        popover?.behavior = .transient
        popover?.animates = true
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover?.isShown == true {
                self?.popover?.performClose(nil)
            }
        }
    }

    private func observeViewModelChanges() {
        // Combine multiple publishers to reduce redundant updates
        Publishers.CombineLatest3(
            viewModel.$usageSummary,
            viewModel.$authState,
            viewModel.$isRefreshing
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.updateStatusBarContent()
        }
        .store(in: &cancellables)
    }

    // MARK: - Status Bar Content

    private func updateStatusBarContent() {
        guard let button = statusItem?.button else { return }

        let contentView = StatusBarContentView(viewModel: viewModel)

        // Reuse existing hosting view or create new one
        if let hostingView = statusBarHostingView {
            // Update rootView instead of recreating (prevents memory leak)
            hostingView.rootView = contentView
        } else {
            let hostingView = NSHostingView(rootView: contentView)
            statusBarHostingView = hostingView
            button.addSubview(hostingView)
        }

        guard let hostingView = statusBarHostingView else { return }

        // Calculate and apply size
        let fittingSize = hostingView.fittingSize
        let width = max(Constants.UI.statusBarMinWidth, fittingSize.width + Constants.UI.statusBarPadding)
        let height = Constants.UI.statusBarHeight

        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        button.frame = NSRect(x: 0, y: 0, width: width, height: height)
        statusItem?.length = width
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover, popover.isShown {
            popover.performClose(nil)
        } else {
            let contentView = MenuBarView().environmentObject(viewModel)
            popover?.contentViewController = NSHostingController(rootView: contentView)
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover?.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Login Window

    func openLoginWindow() {
        // Close popover if open
        popover?.performClose(nil)

        // If window already exists and is visible, just bring to front
        if let window = loginWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        // Create login window
        let loginView = LoginWindow().environmentObject(viewModel)
        let hostingController = NSHostingController(rootView: loginView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Login to Claude"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 420, height: 600))
        window.center()
        window.isReleasedWhenClosed = false

        loginWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeLoginWindow() {
        loginWindow?.close()
    }

    deinit {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}

// MARK: - Status Bar Content View

/// SwiftUI view for the menubar status item (supports two lines)
struct StatusBarContentView: View {
    @ObservedObject var viewModel: AppViewModel

    /// Default remaining time when resetting (5-hour cycle)
    private static let defaultRemaining = "5h"

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "brain")
                .font(.system(size: 13))

            if viewModel.authState.isAuthenticated {
                if let summary = viewModel.usageSummary, let primary = summary.primaryItem {
                    VStack(alignment: .leading, spacing: -3) {
                        // Percentage with status indicator
                        HStack(alignment: .center, spacing: 3) {
                            Text("\(primary.utilization)%")
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .fixedSize()

                            Circle()
                                .fill(viewModel.statusColor)
                                .frame(width: 6, height: 6)
                        }

                        // Show remaining time, fallback to "5h" when resetting
                        Text(primary.resetTimeRemaining ?? Self.defaultRemaining)
                            .font(.system(size: 8, weight: .regular, design: .rounded))
                            .opacity(0.8)
                            .fixedSize()
                    }
                } else if viewModel.isRefreshing {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                }
            }
        }
        .frame(height: 22)
    }
}
