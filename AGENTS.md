# Repository Guidelines

## Project Structure & Module Organization

This repository contains a single iOS SwiftUI app in `CullaMusic/`. The Xcode project is `CullaMusic/CullaMusic.xcodeproj`, with one app target and scheme named `CullaMusic`.

Source code lives in `CullaMusic/CullaMusic/`:

- `CullaMusicApp.swift`: app entry point.
- `Views/`: SwiftUI screens, sheets, and reusable view components.
- `ViewModels/`: UI state and interaction logic, including swipe flow state.
- `Models/`: lightweight domain types such as playlists, sorted songs, dismissed songs, and swipe config.
- `Services/`: Apple Music and library integration.
- `Helpers/`: shared UI/environment utilities and haptics.
- `Assets.xcassets/`: app icon, accent color, and visual assets.

There is currently no dedicated test target. Add tests under a new `CullaMusicTests/` target when introducing test coverage.

## Build, Test, and Development Commands

- `open CullaMusic/CullaMusic.xcodeproj`: open the app in Xcode for local development and signing setup.
- `xcodebuild -list -project CullaMusic/CullaMusic.xcodeproj`: list available targets, configurations, and schemes.
- `xcodebuild -project CullaMusic/CullaMusic.xcodeproj -scheme CullaMusic -configuration Debug build`: build the app from the command line.
- `xcodebuild test -project CullaMusic/CullaMusic.xcodeproj -scheme CullaMusic -destination 'platform=iOS Simulator,name=iPhone 16'`: run tests once a test target is added and a matching simulator is installed.

The app uses MusicKit and requires Apple Music authorization, so validate library flows on a signed simulator/device with an Apple Music-capable account.

## Coding Style & Naming Conventions

Use Swift 5 and SwiftUI conventions. Indent with 4 spaces, keep files focused by feature or type, and prefer `struct` views with small private helper views when a screen grows. Name views with a `View` suffix, sheets with `Sheet`, view models with `ViewModel`, and services with `Service` (for example, `MusicSwipeViewModel`, `MusicLibraryService`). Keep UI state in view models where it is shared across views.

## Testing Guidelines

When adding tests, prefer XCTest unless the project is migrated to Swift Testing. Name test files after the subject, such as `MusicSwipeViewModelTests.swift`, and test methods by behavior, for example `testUndoRestoresPreviousSong()`. Prioritize view model logic, playlist filtering, MusicKit service boundaries, and regressions around swipe/undo behavior.

## Commit & Pull Request Guidelines

Recent history uses concise Conventional Commit-style messages: `feat: ...` and `fix: ...`. Keep the subject imperative and specific, for example `fix: preserve playlist editability on sync`.

Pull requests should include a short description, user-visible behavior changes, linked issues when relevant, and screenshots or screen recordings for UI changes. Note any MusicKit authorization, device, or simulator requirements used during validation.
