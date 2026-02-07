# Claude Usage - Project Guidelines

## Project Overview

A macOS menubar application that displays Claude.ai usage statistics in real-time. Built with Swift 5.9 and SwiftUI, targeting macOS 13.0+.

**Tech Stack**: Swift async/await + Combine, SwiftUI + AppKit (NSStatusItem), Keychain + UserDefaults, URLSession, os.log. No external dependencies.

## Core Features

### 1. Authentication

- **Login Flow**: Open WebView → load `claude.ai/login` → user logs in → extract session cookies
- **Cookie Storage**: macOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- **Bootstrap**: Call `/api/bootstrap` to get organization ID and subscription tier
- **Session Management**: Detect 401/403 as session expiry, prompt re-login
- **Cookie Validation**: Whitelist only `claude.ai` and `anthropic.com` domains

### 2. Usage Data Fetching

- **API Endpoint**: `GET /api/organizations/{id}/usage`
- **Polling**: Auto-refresh at configurable intervals (1, 2, 3, 5, 10 minutes)
- **Dynamic Response Parsing**: API returns varying keys (`five_hour`, `seven_day`, `seven_day_opus`, etc.)
- **Priority Ordering**: `five_hour` → `seven_day` → `seven_day_*` variants → others (alphabetically)
- **Data Model**: Each item has `utilization` (0-100+) and `resetsAt` (ISO timestamp)

### 3. Menubar Display

- **Status Item**: Multi-line text showing primary usage percentage and reset time
- **Color Coding**: Green (< 80%), Orange (80-99%), Red (≥ 100%)
- **Popover Menu**: Header with tier badge, usage cards (full-width primary, 2-column grid for others), refresh countdown/button

### 4. Reset Time Management

- **Display Formats**: Short `"14:30 · in 2h 30m"`, Long `"Jan 5 · in 3d 5h"`, At limit `"until 14:30"`, Null `"Ready"`
- **Auto-Refresh Pause**: When primary reaches 100%, pause API polling
- **Reset Detection**: When utilization drops to 0, play notification sound (if enabled)

### 5. Extra Usage (Billing)

- **Prepaid Credits**: `GET /api/organizations/{id}/prepaid/credits`
- **Spend Limit**: `GET /api/organizations/{id}/overage_spend_limit`
- **Toggle**: Enable/disable via `PUT`, "Manage in Browser" links to `claude.ai/settings/usage`

### 6. Settings

- Auto Refresh Interval, Reset Sound selector, Log Out, Quit

## Architecture

**MVVM Pattern** with protocol-based services:

```
Views (SwiftUI) → ViewModel (AppViewModel) → Services → API/Storage
```

### Service Dependencies

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

### AuthState Machine

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

### Edge Cases & Error Handling

- **Network Disconnected**: Skip API call, set `lastError`, retry on next timer tick
- **Session Expired (401/403)**: Set `authState = .notAuthenticated`, prompt re-login
- **API Errors**: Max 3 retries with exponential backoff (30s, 60s, 120s)
- **Cache**: `cachedUsageSummary_v2` in UserDefaults, max age 1 hour, cleared on logout
- **System Sleep/Wake**: Stop all timers on sleep (prevents Power Nap API calls/sounds); refresh + restart on wake

**Primary Usage at Limit (100%)**:

- Pause auto-refresh, start 60s reset countdown timer (clock-aligned to minute boundaries)
- `secondsUntilNextRefresh` counts down to `resetsAt` (not next API call)
- All display locations (menubar, popover header, usage cards) use `primary.resetTimeRemaining` as unified source
- Schedule `resumeRefreshTimer` at `resetsAt + 5s` to resume polling
- Non-primary item reset during pause: `checkForExpiredResetTimes()` triggers refresh on each 60s tick; `processedResetTimes` prevents duplicate triggers

## Coding Conventions

- **Naming**: PascalCase types, camelCase functions/variables, constants in `Constants.swift` nested enums
- **Code Organization**: Use `// MARK: -` sections
- **Concurrency**: `@MainActor` for UI classes, async/await for all async work
- **Protocols**: Define protocols for services to enable testing (`ClaudeAPIClientProtocol`, `AuthenticationServiceProtocol`)
- **Error Handling**: Custom error enums with `LocalizedError`
- **Logging**: os.log with per-file `Logger` instances
- **Performance**: Cache DateFormatters, reuse NSHostingView for statusbar, `[weak self]` in closures

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

ClaudeUsageTests/
├── UsageRefreshServiceTests.swift  # Unit tests with lightweight test framework
└── Mocks/                          # Mock services for testing
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

## Build & Test

```bash
./build.sh      # Creates build/ClaudeUsage.app (requires macOS 13.0+, Xcode CLI Tools)
./run-tests.sh  # Compiles and runs unit tests
```

- Lightweight custom test framework (no XCTest dependency)
- Protocol-based dependency injection with mock services

## Important Notes

1. **No External Dependencies**: Keep the project pure Swift/SwiftUI
2. **Menubar App**: Uses `LSUIElement` (no dock icon)
3. **Cookie-Based Auth**: WebView login flow with manual cookie management
4. **English UI**: User-facing strings are in English
5. **Dynamic API Response**: Usage API returns varying keys; handle with `orderedKeys`
