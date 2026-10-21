import AppKit
import ScreenCaptureKit

/// Captures a region of the display under the mouse with ScreenCaptureKit (read-only).
enum ScreenCapturer {
    struct Capture {
        let image: CGImage
        /// Cursor position in image pixels (top-left origin).
        let cursorInImage: CGPoint
        /// Captured region in global AppKit coordinates (bottom-left origin), for placing the panel.
        let regionInScreen: CGRect
        let screen: NSScreen
        let scale: CGFloat
    }

    enum CaptureError: LocalizedError {
        case noScreen, noDisplay, permission
        var errorDescription: String? {
            switch self {
            case .noScreen: return "Mouse isn't on a screen"
            case .noDisplay: return "Display not available to ScreenCaptureKit"
            case .permission: return "Screen Recording permission is needed — System Settings › Privacy & Security › Screen & System Audio Recording"
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (first time) asking the user to allow Screen Recording.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Captures a band `width` points wide (full display height) centred on the cursor.
    /// Default is the whole display: stash tooltips can be drawn far from the cursor.
    static func captureAroundMouse(width: CGFloat = .greatestFiniteMagnitude) async throws -> Capture {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            throw CaptureError.noScreen
        }
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw CaptureError.noDisplay
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw hasPermission ? error : CaptureError.permission
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }

        // Display-local, top-left origin (points).
        let frame = screen.frame
        let local = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
        let w = min(width, frame.width)
        let x0 = min(max(0, local.x - w / 2), frame.width - w)
        let source = CGRect(x: x0, y: 0, width: w, height: frame.height)

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int(source.width * scale)
        config.height = Int(source.height * scale)
        config.showsCursor = false
        config.captureResolution = .best

        // Leave our own windows out of the shot.
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let cursor = CGPoint(x: (local.x - x0) * scale, y: local.y * scale)
        let region = CGRect(x: frame.minX + x0, y: frame.minY, width: w, height: frame.height)
        return Capture(image: image, cursorInImage: cursor, regionInScreen: region, screen: screen, scale: scale)
    }
}
