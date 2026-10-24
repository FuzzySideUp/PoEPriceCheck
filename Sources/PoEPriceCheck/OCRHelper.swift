import CoreGraphics
import Foundation
import ImageIO
import PoECore
import UniformTypeIdentifiers

/// Vision can break inside a long-running process and never recover (seen: every request failing with an
/// e5rt error after the Mac slept with a game running locally under CrossOver), while a fresh process reads the
/// same screen fine. So when in-process OCR fails, run it in a fresh copy of this app (`--ocr-helper <image>`)
/// and keep doing that for the rest of the session.
enum OCRHelper {
    /// POE_OCR_HELPER=1 uses the helper from the start (for testing).
    private static let useHelper = Switch(on: ProcessInfo.processInfo.environment["POE_OCR_HELPER"] == "1")
    /// The first run of a new build compiles Vision's GPU model (~30 s, cached per binary), so the first helper
    /// call gets longer; a shorter limit would kill it every time and the cache would never be written.
    static var timeout: TimeInterval { firstRun.isOn ? 20 : 90 }
    private static let firstRun = Switch(on: false)

    static func read(image: CGImage, cursor: CGPoint?) throws -> TooltipReader.Result {
        if !useHelper.isOn {
            do { return try TooltipReader.read(image: image, cursor: cursor) }
            catch {
                useHelper.turnOn()
                Log.info("in-process OCR failed (\(error)); using a helper process from now on")
            }
        }
        return try TooltipReader.read(image: image, cursor: cursor, recognizer: recognizeInHelper)
    }

    static var inUse: Bool { useHelper.isOn }

    private static func recognizeInHelper(_ image: CGImage) throws -> [OCRLine] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poepc-ocr-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HelperError("can't write \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw HelperError("can't write \(url.path)") }

        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["--ocr-helper", url.path]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        // Read in the background while it runs, so a large result can't fill the pipe and stall the helper,
        // and a hung helper can't block us past the timeout.
        let output = Output()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.data = out.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw HelperError("timed out after \(Int(timeout))s")
        }
        readDone.wait()
        firstRun.turnOn()
        let data = output.data
        guard process.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw HelperError("exit \(process.terminationStatus): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try JSONDecoder().decode([OCRLine].self, from: data)
    }

    /// The helper side: OCR one image file and print the lines as JSON. Returns the exit code.
    static func runHelper(path: String) -> Int32 {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            FileHandle.standardError.write(Data("can't read \(path)\n".utf8))
            return 2
        }
        do {
            let lines = try TooltipReader.recognize(image)
            FileHandle.standardOutput.write(try JSONEncoder().encode(lines))
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    struct HelperError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { "OCR helper: \(message)" }
    }

    private final class Output: @unchecked Sendable { var data = Data() }

    private final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var on: Bool
        init(on: Bool) { self.on = on }
        var isOn: Bool { lock.withLock { on } }
        func turnOn() { lock.withLock { on = true } }
    }
}
