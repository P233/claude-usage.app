# Claude Usage - Project Guidelines

## Project Overview

A macOS menubar application that displays Claude.ai usage statistics in real-time. Built with Swift 5.9 and SwiftUI, targeting macOS 13.0+.

## Core Features

### 1. Authentication

- **Login Flow**: Open WebView → load `claude.ai/login` → user logs in → extract session cookies
- **Cookie Storage**: Store in macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (encrypted, device-only)
- **Bootstrap**: Call `/api/bootstrap` to get organization ID and subscription tier (Free/Pro/Team/Enterprise)
- **Session Management**: Detect 401/403 responses as session expiry, prompt re-login
- **Cookie Validation**: Whitelist only `claude.ai` and `anthropic.com` domains, check expiration

### 2. Usage Data Fetching

- **API Endpoint**: `GET /api/organizations/{id}/usage`
- **Polling**: Auto-refresh at configurable intervals (1, 2, 3, 5, 10 minutes)
- **Dynamic Response Parsing**: API returns varying keys (`five_hour`, `seven_day`, `seven_day_opus`, etc.)
- **Priority Ordering**: `five_hour` → `seven_day` → `seven_day_*` variants → others (alphabetically)
- **Data Model**: Each item has `utilization` (0-100+) and `resetsAt` (ISO timestamp)

### 3. Menubar Display

- **Status Item**: Multi-line text showing primary usage percentage and reset time
- **Color Coding**:
  - Green (normal): utilization < 80%
  - Yellow (warning): 80% ≤ utilization < 100%
  - Red (critical): utilization ≥ 100%
- **Popover Menu**:
  - Header: "Claude Usage" + subscription tier badge
  - Usage cards: Full-width for primary items (five_hour, seven_day)
  - Compact grid: 2-column layout when items exceed threshold
  - Each card shows: title, percentage, progress bar, reset time countdown
  - Refresh countdown/button, last updated time

### 4. Reset Time Management

- **Time Parsing**: Convert ISO `resets_at` to remaining days/hours/minutes
- **Display Formats**:
  - Short (5-hour): `"14:30 · in 2h 30m"`
  - Long (7-day): `"Jan 5 · in 3d 5h"` or `"14:30 · in 2h 30m"` if today
  - Null reset time: `"Ready"` (shown in both menubar and panel)
- **Auto-Refresh Pause**: When primary (five_hour) reaches 100%, pause polling
- **Reset Detection**: When utilization drops (reset occurred), resume polling
- **Sound Alert**: Optional notification sound when quota resets

### 5. Extra Usage (Billing)

- **Prepaid Credits**: `GET /api/organizations/{id}/prepaid/credits` - balance and auto-reload status
- **Spend Limit**: `GET /api/organizations/{id}/overage_spend_limit` - monthly limit and used amount
- **Display**: Used credits / monthly limit with progress bar, currency formatting
- **Toggle**: Enable/disable extra usage via `PUT /api/organizations/{id}/overage_spend_limit`
- **Browser Link**: "Manage in Browser" opens `claude.ai/settings/usage`

### 6. Settings

- **Auto Refresh Interval**: Picker with 1, 2, 3, 5, 10 minute options
- **Reset Sound**: Selector for notification sound (or off)
- **Log Out**: Clear Keychain credentials and reset state
- **Quit**: Terminate application

## Architecture

**MVVM Pattern** with protocol-based services:

```
Views (SwiftUI) → ViewModel (AppViewModel) → Services → API/Storage
```

- `AppViewModel`: Central coordinator with Combine publishers
- `Services/`: Business logic (auth, API, refresh scheduling)
- `Models/`: Data structures and API response types
- `Views/`: SwiftUI components

### Service Dependencies & Initialization Order

```
UserSettings.shared (singleton)
       ↓
AuthenticationService (standalone, owns KeychainService)
       ↓
ClaudeAPIClient (depends on AuthenticationService for cookies)
       ↓
UsageRefreshService (depends on APIClient, AuthService, Settings)
       ↓
AppViewModel (coordinates all above, exposes @Published properties)
```

**Initialization in AppViewModel**:

```swift
convenience init() {
    let settings = UserSettings.shared
    let authService = AuthenticationService()
    let apiClient = ClaudeAPIClient(authService: authService)
    let refreshService = UsageRefreshService(apiClient, authService, settings)
    self.init(authService, apiClient, refreshService, settings)
}
```

### UI State Machine (AuthState)

```
                    ┌─────────────┐
     App Launch ───▶│   unknown   │
                    └──────┬──────┘
                           │ checkStoredCredentials()
                    ┌──────▼─────────┐
                    │ authenticating │
                    └──────┬─────────┘
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌─────────────┐ ┌────────────────┐ ┌─────────────┐
    │authenticated│ │notAuthenticated│ │    error    │
    │(orgId, tier)│ │                │ │  (message)  │
    └──────┬──────┘ └──────┬─────────┘ └──────┬──────┘
           │               │                  │
           │   logout()    │   login()        │  retry()
           └───────────────┼──────────────────┘
                           ▼
                    (cycle repeats)
```

**State Transitions**:

- `unknown` → `authenticating`: On app launch, call `checkStoredCredentials()`
- `authenticating` → `authenticated`: Valid cookies found in Keychain + bootstrap success
- `authenticating` → `notAuthenticated`: No stored credentials or expired
- `authenticating` → `error`: Keychain access failed or API error
- `authenticated` → `notAuthenticated`: User logout or 401/403 from API
- Any state → `authenticating`: Re-check credentials

### Data Flow

**1. Login Success Flow**:

```
WebView login complete
       ↓
AppViewModel.onLoginSuccess(cookies)
       ↓
APIClient.fetchBootstrap(cookies) → get orgId, subscriptionType
       ↓
AuthService.saveSession(cookies, orgId, subscriptionType)
       ↓
Keychain storage + AuthState → .authenticated
       ↓
UsageRefreshService observes authState change
       ↓
refreshNow() + startAutoRefresh()
```

**2. Usage Refresh Flow**:

```
Timer fires or manual refresh
       ↓
UsageRefreshService.refreshNow()
       ↓
Check: isRefreshing? isAuthenticated? NetworkMonitor.isConnected?
       ↓
APIClient.fetchUsage(organizationId)
       ↓
processUsageResponse() → UsageSummary
       ↓
Check: isPrimaryAtLimit? → pause auto-refresh, schedule resume
       ↓
checkForResetAndPlaySound() → compare with lastUtilization
       ↓
Update @Published usageSummary → Combine → AppViewModel → Views
       ↓
saveCache() to UserDefaults
       ↓
fetchExtraUsageData() (parallel: credits + spendLimit)
```

**3. Combine Bindings (Service → ViewModel)**:

```swift
// In AppViewModel.setupBindings()
authService.$authState → $authState
refreshService.$usageSummary → $usageSummary
refreshService.$extraUsage → $extraUsage
refreshService.$isRefreshing → $isRefreshing
refreshService.$lastError → $lastError
refreshService.$secondsUntilNextRefresh → $secondsUntilNextRefresh
```

### Edge Cases & Error Handling

**Network Disconnected**:

- `NetworkMonitor.shared.isConnected` checked before each refresh
- If disconnected: set `lastError = "No network connection"`, skip API call
- Auto-refresh timer continues, will retry on next tick

**Session Expired (401/403)**:

- `ClaudeAPIClient` throws `APIError.sessionExpired`
- `AuthenticationService` sets `authState = .notAuthenticated`
- UI shows login prompt, user must re-authenticate

**API Errors with Retry**:

- Max 3 retries with exponential backoff (30s, 60s, 120s)
- `retryCount` resets on successful refresh or auth state change
- After max retries: wait for next scheduled refresh

**Cache Behavior**:

- Cache key: `cachedUsageSummary_v2` in UserDefaults
- Max age: 3600 seconds (1 hour)
- Loaded on service init, used while fetching fresh data
- Cleared on logout or cache expiration

**System Wake from Sleep**:

- Observer on `NSWorkspace.didWakeNotification`
- Immediately refresh + restart auto-refresh timer
- Handles stale `nextRefreshDate` after sleep

**Primary Usage at Limit (100%)**:

- Pause auto-refresh to reduce API calls
- Schedule `resumeRefreshTimer` at `resetsAt + 5 seconds`
- On timer fire: refresh + restart auto-refresh
- Wake from sleep also triggers resume

**Reset Detection**:

- Track `lastUtilization` for primary item
- If drops from >0 to 0: play notification sound (if enabled)
- `processedResetTimes` set prevents duplicate refresh triggers

## Tech Stack

- **Language**: Swift 5.9
- **UI**: SwiftUI + AppKit (NSStatusItem for menubar)
- **Concurrency**: Swift async/await + Combine
- **Storage**: Keychain (credentials), UserDefaults (settings)
- **Networking**: URLSession (no third-party dependencies)
- **Logging**: os.log framework

## Coding Conventions

### Naming

- **Types**: PascalCase (`AppViewModel`, `UsageItem`)
- **Functions/Variables**: camelCase (`fetchUsage()`, `refreshInterval`)
- **Constants**: Grouped in `Constants.swift` using nested enums

### Code Organization

Use MARK comments to section code:

```swift
// MARK: - Published Properties
// MARK: - Services
// MARK: - Initialization
// MARK: - Actions
// MARK: - Private Helpers
```

### Concurrency

- Use `@MainActor` for all UI-related classes
- All async work uses Swift concurrency (async/await)
- Thread-safe storage with `NSLock` when needed

```swift
@MainActor
final class AppViewModel: ObservableObject { }
```

### Protocols

Define protocols for services to enable testing:

```swift
protocol ClaudeAPIClientProtocol { }
protocol AuthenticationServiceProtocol { }
```

### Error Handling

Use custom error enums with `LocalizedError`:

```swift
enum APIError: Error, LocalizedError {
    case notAuthenticated
    case sessionExpired
    case httpError(statusCode: Int)

    var errorDescription: String? { ... }
}
```

### Logging

Use os.log with per-file loggers:

```swift
private let logger = Logger(
    subsystem: Constants.App.bundleIdentifier,
    category: "ClassName"
)
logger.debug("Debug message")
logger.error("Error: \(error)")
```

### Performance Patterns

- Cache expensive objects (DateFormatters)
- Reuse NSHostingView for statusbar updates
- Use `[weak self]` in closures to prevent retain cycles

## File Structure

```
ClaudeUsage/
├── ClaudeUsageApp.swift      # @main entry point
├── AppDelegate.swift         # Menubar management
├── Models/                   # Data structures
├── Services/                 # Business logic
├── ViewModels/               # UI state (AppViewModel)
├── Views/                    # SwiftUI components
└── Utilities/                # Constants, helpers
```

## API Endpoints

All calls go to `claude.ai`:

- `POST /api/bootstrap` - Organization & subscription info
- `GET /api/organizations/{id}/usage` - Usage statistics
- `GET /api/organizations/{id}/prepaid/credits` - Prepaid balance
- `GET /api/organizations/{id}/overage_spend_limit` - Billing limits

## Security Requirements

- Store credentials only in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Validate cookie domains (only `claude.ai`, `anthropic.com`)
- Never log sensitive data (cookies, tokens)
- Use HTTPS for all network requests

## Build

```bash
./build.sh  # Creates build/ClaudeUsage.app
```

Requires: macOS 13.0+, Xcode Command Line Tools

## Important Notes

1. **No External Dependencies**: Keep the project pure Swift/SwiftUI
2. **Menubar App**: Uses `LSUIElement` (no dock icon)
3. **Cookie-Based Auth**: WebView login flow with manual cookie management
4. **English UI**: User-facing strings are in English
5. **Dynamic API Response**: Usage API returns varying keys; handle with `orderedKeys`
