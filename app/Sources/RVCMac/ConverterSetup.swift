import CryptoKit
import Foundation
import RVCMacCore

/// Installs the model converter's Python environment on first use, so the downloaded app needs nothing else.
///
/// 1. downloads a standalone CPython (python-build-standalone); the build pins its URL and SHA-256 in Info.plist,
/// 2. verifies the checksum and unpacks it into `<home>/runtime/python`,
/// 3. creates `<home>/venv` and installs `requirements.txt` bundled with the app (torch, coremltools, ...).
///
/// Without pinned Python (a local developer build) it falls back to a Homebrew python3.12.
enum ConverterSetup {
    struct Progress {
        var phase: String
        var fraction: Double?   // nil = indeterminate
    }

    enum SetupError: LocalizedError {
        case noPython, checksum, failed(String, Int32)
        var errorDescription: String? {
            switch self {
            case .noPython: return tr("В этой сборке не закреплён Python, и python3.12 из Homebrew не найден. Установи его: brew install python@3.12")
            case .checksum: return tr("Контрольная сумма скачанного Python не совпала — файл повреждён или подменён. Попробуй ещё раз.")
            case let .failed(step, code): return trf("Шаг «%@» завершился с кодом %@ — подробности в логе.", step, "\(code)")
            }
        }
    }

    static var runtimeDir: URL { RVCMacPaths.home.appendingPathComponent("runtime") }
    static var venvDir: URL { RVCMacPaths.home.appendingPathComponent("venv") }

    static var isReady: Bool { FileManager.default.isExecutableFile(atPath: RVCMacPaths.python.path) }

    /// Removes the environment (for a clean reinstall). Converted voices are kept.
    static func remove() throws {
        let fm = FileManager.default
        for d in [venvDir, runtimeDir] where fm.fileExists(atPath: d.path) { try fm.removeItem(at: d) }
    }

    static func install(progress: @escaping @Sendable (Progress) -> Void, log: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        let python = try await basePython(progress: progress, log: log)

        progress(Progress(phase: tr("Создаю окружение Python…"), fraction: nil))
        if fm.fileExists(atPath: venvDir.path) { try fm.removeItem(at: venvDir) }
        try await run(python, ["-m", "venv", venvDir.path], step: "venv", log: log)

        let pip = RVCMacPaths.python
        progress(Progress(phase: tr("Обновляю pip…"), fraction: nil))
        try await run(pip, ["-m", "pip", "install", "--upgrade", "pip", "wheel"], step: "pip", log: log)

        let req = RVCMacPaths.requirements
        let total = Double(max(1, ((try? String(contentsOf: req, encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }.count))
        let counter = LineCounter()
        progress(Progress(phase: tr("Скачиваю библиотеки (torch, coremltools…) — около 1 ГБ"), fraction: 0))
        try await run(pip, ["-m", "pip", "install", "-r", req.path], step: "pip install", log: log) { line in
            // pip prints "Collecting <pkg>" for each requirement and its dependencies; good enough for a progress bar
            if line.hasPrefix("Collecting ") {
                let n = counter.increment()
                let name = line.dropFirst("Collecting ".count).split(separator: " ").first.map(String.init) ?? ""
                progress(Progress(phase: trf("Скачиваю %@…", name), fraction: min(0.9, Double(n) / (total * 4))))
            } else if line.hasPrefix("Installing collected packages") {
                progress(Progress(phase: tr("Устанавливаю пакеты…"), fraction: 0.92))
            }
        }

        progress(Progress(phase: tr("Проверяю установку…"), fraction: 0.97))
        try await run(pip, ["-c", "import torch, coremltools, torchfcpe, faiss; print('torch', torch.__version__, 'coremltools', coremltools.__version__)"],
                      step: "check", log: log)
        try? "ok\n".write(to: venvDir.appendingPathComponent(".rvcmac-setup"), atomically: true, encoding: .utf8)
        progress(Progress(phase: tr("Конвертер готов"), fraction: 1))
    }

    /// A Python able to create the venv: the pinned standalone build, or a local python3.12.
    private static func basePython(progress: @escaping @Sendable (Progress) -> Void, log: @escaping @Sendable (String) -> Void) async throws -> URL {
        let standalone = runtimeDir.appendingPathComponent("python/bin/python3")
        if FileManager.default.isExecutableFile(atPath: standalone.path) { return standalone }

        let info = Bundle.main.infoDictionary ?? [:]
        if let s = info["RVCMacPythonURL"] as? String, let url = URL(string: s), !s.isEmpty,
           let sha = info["RVCMacPythonSHA256"] as? String, !sha.isEmpty {
            progress(Progress(phase: tr("Скачиваю Python…"), fraction: 0))
            log(trf("Скачиваю Python: %@", url.lastPathComponent))
            let archive = runtimeDir.appendingPathComponent("python.tar.gz")
            try await Downloader.download(url, to: archive) { f in
                progress(Progress(phase: tr("Скачиваю Python…"), fraction: f))
            }
            guard try sha256(of: archive) == sha.lowercased() else {
                try? FileManager.default.removeItem(at: archive)
                throw SetupError.checksum
            }
            progress(Progress(phase: tr("Распаковываю Python…"), fraction: nil))
            try await run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", runtimeDir.path], step: "tar", log: log)
            try? FileManager.default.removeItem(at: archive)
            guard FileManager.default.isExecutableFile(atPath: standalone.path) else { throw SetupError.failed("tar", -1) }
            return standalone
        }
        for p in ["/opt/homebrew/bin/python3.12", "/usr/local/bin/python3.12"] where FileManager.default.isExecutableFile(atPath: p) {
            log(trf("Python не закреплён в сборке — использую %@", p))
            return URL(fileURLWithPath: p)
        }
        throw SetupError.noPython
    }

    static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a process, streaming its output lines to `log` (and `onLine`), and throws on a non-zero exit.
    static func run(_ exe: URL, _ args: [String], step: String, log: @escaping @Sendable (String) -> Void,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        env["PIP_PROGRESS_BAR"] = "off"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            for line in buffer.append(data) {
                log(line)
                onLine?(line)
            }
        }
        let code: Int32 = try await withCheckedThrowingContinuation { cont in
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: proc.terminationStatus)
            }
            do { try p.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: error)
            }
        }
        if let rest = buffer.flush() { log(rest) }
        guard code == 0 else { throw SetupError.failed(step, code) }
    }
}

/// Splits a byte stream into lines (thread-safe: called from the pipe's handler queue).
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    func append(_ d: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(d)
        var lines: [String] = []
        while let r = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: pending[pending.startIndex..<r], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...r)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        return lines
    }
    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        let s = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        pending.removeAll()
        return s.isEmpty ? nil : s
    }
}

private final class LineCounter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

/// URLSession download with progress.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private let destination: URL

    private init(destination: URL, onProgress: @escaping (Double?) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func download(_ url: URL, to destination: URL, onProgress: @escaping (Double?) -> Void) async throws {
        let d = Downloader(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            d.continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
