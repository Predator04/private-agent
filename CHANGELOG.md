# Changelog

All notable changes to Apex Agent will be documented here.

## [1.8.0] - 2026-07-20
### Added
- Token cost estimator in Settings (total tasks, success rate, tokens spent, estimated cost)
- Scheduled Tasks UI — define recurring goals with schedule presets (every 30m, hourly, daily, custom)
- Screenshot evidence capture — when a task completes, a screenshot is saved to the task history log
- Analytics section in Execution logs card in Settings

### Fixed
- Duration tracking in StepTrace — actual wall-clock time per step now recorded (was always 0ms)
- `print()` calls replaced with `developer.log()` in task_history_logger for release-build hygiene
- Bounds null safety — `node['bounds']` is now type-checked before access in screen_automation_service

### Changed
- All 10 audit bugs resolved, 10 optimizations applied, top feature suggestions added

## [1.7.0] - 2026-07-20
### Fixed
- Vision fallback dead code — `_visionService.init()` now called at start of executeTask()
- Retry logic no longer wastes tokens on 4xx client errors (bad keys, rate limits)
- 30-minute timeout reduced to 120s for task messages (hung calls no longer block for half an hour)
- Overlay poll interval reduced from 500ms to 3s (battery savings)
- Theme "System" mode correctly restored on restart (no longer reverts to Light)
- Telegram concurrency guard — message queue + `_isProcessing` flag prevents race conditions
- `_maxSteps` field initializer matched to `init()` default (both now 10)

## [1.6.0] - 2026-07-20
### Changed
- Reduced default max steps from 15 → 10 to prevent excessive looping
- Stuck detection threshold lowered from 3 → 2 repeated actions
- Max consecutive scrolls capped at 3 before AI must take action
- Stronger prompt emphasis: "Complete the task in as few steps as possible"
- Fix: Auto-update download URL now correctly points to release assets

### Fixed
- Auto-update "Download failed" — was using wrong asset filename (Apex-Agent-*.apk → app-release.apk)
- App version now properly displayed in About section

## [1.5.0] - 2026-07-20
### Fixed
- "Missing type parameter" crash on notification cancel wrapped in try/catch on `init()`
- Stale scheduled notification cache from previous versions no longer crashes the app

### Changed
- Install intent changed from `ACTION_INSTALL_PACKAGE` to `ACTION_VIEW` with MIME type for broader Android compatibility

## [1.4.0] - 2026-07-20
### Fixed
- Notification buzzing on every step — `onlyAlertOnce: true`
- Chat message flooding — progress updates now edit a single status message in-place
- Toast leaking exception text to user
- `skipVersion()` and `installApk()` now properly awaited
- `setState` after dispose crash in download dialog
- YouTube links removed from About section

### Changed
- AI prompt rule: "Do NOT click voice search, microphone, or 'search by voice' elements"
- Speed improvements: action delays cut 55-65%
- Each task step shows a toast + persistent notification
- Progress notification updates silently (no buzz)

## [1.3.0] - 2026-07-20
### Fixed
- `http.Client()` memory leak (added `client.close()` after download)
- Stale `_cancelCompleter` — set to null on all exit paths
- Duplicate notification on task start removed
- Progress notification not cleared on completion
- Bad `context` ref in update dialog snackbar

### Changed
- Disable Max Steps toggle in Settings (warning: can cause infinite loops)

## [1.2.0] - 2026-07-20
### Changed
- Action delays slashed 55-65% (`open_app` 3.0s→1.5s, `click_text` 1.5s→0.8s, etc.)
- Persistent notification on every task step (step number, progress bar, AI reasoning)
- Toast on every step instead of every 3 steps

## [1.1.0] - 2026-07-20
### Added
- In-app version display in Settings > About
- Auto-update check on launch (silent GitHub release check)
- Download & Install button (in-app APK download + installer)
- Skip This Version / Clear Skipped Updates
- Check for Updates button in Settings

## [1.0.2] - 2026-07-20
### Added
- First public release as "Apex Agent"
- God Mode toggle in Settings
- Default to Agent mode (not Chat)
- Mute button on main screen input bar
- Rebranded from PrivateAgent to Apex Agent by Predator04
- New 3D-style app icon
