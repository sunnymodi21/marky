import CryptoKit
import Foundation

/// Runs GLiNER2.5 Base locally via a long-lived Python worker.
///
/// Direct release builds carry a relocatable Python + GLiNER runtime. First use
/// only downloads the verified model snapshot from download.marky.click. Debug
/// builds can still create a development venv when the bundled runtime is absent.
actor GLiNERService {
    static let modelID = "fastino/gliner2.5-base-v1"
    static let modelRevision = "1a8bc24e00dc7300b9017c81d63e3dcdabb26596"
    static let modelBaseURL = URL(
        string: "https://download.marky.click/models/fastino/gliner2.5-base-v1/\(modelRevision)/")!
    static let maxClipboardCharacters = 12_000

    private struct Download {
        var path: String
        var byteCount: Int
        var sha256: String
    }

    private static let modelFiles = [
        Download(
            path: "config.json",
            byteCount: 3_150,
            sha256: "0eb92d00584d613aab32b2178f84a85176b62c87ae3689ce9084e83f6eba64d1"),
        Download(
            path: "encoder_config/config.json",
            byteCount: 857,
            sha256: "d36a845b9f25dcaf1ec45a1c4bdf65ea4ac20596537e14530ec9f660a63aeca4"),
        Download(
            path: "tokenizer.json",
            byteCount: 8_341_713,
            sha256: "cbc8ae6037812709c9c26f2a160f8dc48b0440bcb79c8141804259ae2d6adac3"),
        Download(
            path: "tokenizer_config.json",
            byteCount: 645,
            sha256: "0bf3ea0873234bd9bfdd3853c440395009ac6365a925b91654daed5396d655e1"),
    ]
    private static let modelParts = [
        Download(
            path: "model.safetensors.part-000",
            byteCount: 262_144_000,
            sha256: "36621cb8a4139bdb4858967d5ecf6e09e8c8541ce570bec3d4e0047b308d9801"),
        Download(
            path: "model.safetensors.part-001",
            byteCount: 262_144_000,
            sha256: "6ebe70f052490168a75fa76470708afd5cf500e9a4ddb2e52b686fd3974e5cb8"),
        Download(
            path: "model.safetensors.part-002",
            byteCount: 250_078_564,
            sha256: "3acafa8f572c4148eaa614905332dfab4b0319a4ef3a5ae2da874122be95b6ef"),
    ]
    private static let modelSHA256 = "7274094de2e0c2a37a386f55fc4e23061a954da5bd7a335e7dfe56f2743c277a"

    private let fileManager: FileManager
    private let supportDirectory: URL
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var pending: [Int: CheckedContinuation<GLiNERWorkerResponse, Error>] = [:]
    private var nextRequestID = 1

    init(supportDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let supportDirectory {
            self.supportDirectory = supportDirectory
        } else {
            let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.supportDirectory = root.appendingPathComponent("Marky/gliner", isDirectory: true)
        }
    }

    var isInstalled: Bool {
        self.bundledPythonURL != nil
            || (self.fileManager.fileExists(atPath: self.pythonURL.path)
                && self.fileManager.fileExists(atPath: self.markerURL.path))
    }

    func extract(
        text: String,
        fields: [FormFieldSnapshot],
        progress: @escaping @Sendable (String) -> Void) async throws -> [ExtractedFieldValue]
    {
        guard !fields.isEmpty else { return [] }
        try await self.ensureReady(progress: progress)
        let clipped = Self.clip(text)
        let payload: [String: Any] = [
            "op": "extract",
            "text": clipped,
            "fields": fields.map {
                ["id": $0.id, "description": FieldContextBuilder.description(for: $0)]
            },
        ]
        let response = try await self.send(payload, timeoutSeconds: 120)
        guard response.ok else {
            throw SmartFillError.extractionFailed(response.error ?? "Unknown worker error.")
        }
        return response.values
    }

    private func ensureReady(progress: @escaping @Sendable (String) -> Void) async throws {
        if self.process?.isRunning == true { return }
        progress("Preparing GLiNER2.5…")
        try self.fileManager.createDirectory(at: self.supportDirectory, withIntermediateDirectories: true)
        let python = try self.ensureEnvironment(progress: progress)
        try await self.ensureModel(progress: progress)
        progress("Starting GLiNER2.5…")
        try self.spawnWorker(python: python)
        progress("Loading GLiNER2.5 Base…")
        let response = try await self.send(["op": "load"], timeoutSeconds: 600)
        guard response.ok else {
            throw SmartFillError.glinerUnavailable(response.error ?? "Worker failed to load the model.")
        }
    }

    func shutdown() {
        self.failAllPending(SmartFillError.extractionFailed("GLiNER worker stopped."))
        (self.process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (self.process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        if let stdin = self.stdinHandle {
            try? stdin.close()
        }
        self.stdinHandle = nil
        self.process?.terminate()
        self.process = nil
        self.stdoutBuffer.removeAll()
    }

    // MARK: - Environment

    private var venvURL: URL {
        self.supportDirectory.appendingPathComponent("venv", isDirectory: true)
    }

    private var pythonURL: URL {
        self.venvURL.appendingPathComponent("bin/python")
    }

    private var markerURL: URL {
        self.venvURL.appendingPathComponent(".marky-gliner-ok")
    }

    private var bundledPythonURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("python/bin/python3")
        return self.fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    private var hubURL: URL {
        self.supportDirectory.appendingPathComponent("hub", isDirectory: true)
    }

    private var modelDirectory: URL {
        self.supportDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(Self.modelRevision, isDirectory: true)
    }

    private var modelMarkerURL: URL {
        self.modelDirectory.appendingPathComponent(".verified")
    }

    private var isModelInstalled: Bool {
        guard self.fileManager.fileExists(atPath: self.modelMarkerURL.path) else { return false }
        let files = Self.modelFiles.map { ($0.path, $0.byteCount) }
            + [("model.safetensors", 774_366_564)]
        return files.allSatisfy { path, byteCount in
            let url = self.modelDirectory.appendingPathComponent(path)
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size == byteCount
        }
    }

    private func ensureEnvironment(progress: @escaping @Sendable (String) -> Void) throws -> URL {
        if let bundledPythonURL {
            return bundledPythonURL
        }
        if self.isInstalled {
            return self.pythonURL
        }

        let systemPython = try Self.findSystemPython()
        progress("Creating Python environment…")
        if self.fileManager.fileExists(atPath: self.venvURL.path) {
            try self.fileManager.removeItem(at: self.venvURL)
        }
        try Self.run(
            executable: systemPython,
            arguments: ["-m", "venv", self.venvURL.path],
            environment: [:],
            timeout: 120)

        progress("Installing GLiNER2.5 (first time only, may take a few minutes)…")
        try Self.run(
            executable: self.pythonURL,
            arguments: ["-m", "pip", "install", "--upgrade", "pip"],
            environment: [:],
            timeout: 180)
        try Self.run(
            executable: self.pythonURL,
            arguments: [
                "-m", "pip", "install",
                "gliner2[local]",
                "transformers>=4.44,<4.52",
                "protobuf>=4",
            ],
            environment: [:],
            timeout: 900)

        try "\(Self.modelID)\n".write(to: self.markerURL, atomically: true, encoding: .utf8)
        return self.pythonURL
    }

    // MARK: - Model download

    private func ensureModel(progress: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        if self.isModelInstalled { return }

        try self.fileManager.createDirectory(at: self.modelDirectory, withIntermediateDirectories: true)
        let downloadCount = Self.modelFiles.count + Self.modelParts.count
        var completed = 0

        for file in Self.modelFiles {
            try Task.checkCancellation()
            progress("Downloading GLiNER2.5 (\(completed + 1)/\(downloadCount))…")
            let temporary = try await Self.download(file)
            let destination = self.modelDirectory.appendingPathComponent(file.path)
            try self.fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? self.fileManager.removeItem(at: destination)
            try self.fileManager.moveItem(at: temporary, to: destination)
            completed += 1
        }

        let model = self.modelDirectory.appendingPathComponent("model.safetensors")
        let stagedModel = model.appendingPathExtension("download")
        try? self.fileManager.removeItem(at: stagedModel)
        self.fileManager.createFile(atPath: stagedModel.path, contents: nil)

        do {
            let output = try FileHandle(forWritingTo: stagedModel)
            defer { try? output.close() }
            for part in Self.modelParts {
                try Task.checkCancellation()
                progress("Downloading GLiNER2.5 (\(completed + 1)/\(downloadCount))…")
                let temporary = try await Self.download(part)
                try Self.append(temporary, to: output)
                try? self.fileManager.removeItem(at: temporary)
                completed += 1
            }
        } catch {
            try? self.fileManager.removeItem(at: stagedModel)
            throw error
        }

        guard try Self.sha256(of: stagedModel) == Self.modelSHA256 else {
            try? self.fileManager.removeItem(at: stagedModel)
            throw SmartFillError.glinerUnavailable("The downloaded model failed verification.")
        }
        try? self.fileManager.removeItem(at: model)
        try self.fileManager.moveItem(at: stagedModel, to: model)
        try "\(Self.modelRevision)\n".write(to: self.modelMarkerURL, atomically: true, encoding: .utf8)
    }

    private static func download(_ file: Download) async throws -> URL {
        let url = Self.modelBaseURL.appendingPathComponent(file.path)
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw SmartFillError.glinerUnavailable("Couldn't download \(file.path).")
        }
        let byteCount = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard byteCount == file.byteCount, try Self.sha256(of: temporary) == file.sha256 else {
            try? FileManager.default.removeItem(at: temporary)
            throw SmartFillError.glinerUnavailable("The downloaded \(file.path) failed verification.")
        }
        return temporary
    }

    private static func append(_ source: URL, to destination: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let data = try input.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            try destination.write(contentsOf: data)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let data = try input.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Worker process

    private func spawnWorker(python: URL) throws {
        self.shutdown()

        guard let script = Self.workerScriptURL() else {
            throw SmartFillError.glinerUnavailable("gliner_worker.py is missing from the app bundle.")
        }

        try self.fileManager.createDirectory(at: self.hubURL, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path]
        process.environment = Self.workerEnvironment(hub: self.hubURL, model: self.modelDirectory)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            fputs("[gliner] \(line)", stderr)
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        try process.run()
        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.handleStdout(data) }
        }
    }

    private func send(_ payload: [String: Any], timeoutSeconds: TimeInterval) async throws -> GLiNERWorkerResponse {
        try Task.checkCancellation()
        guard let stdin = self.stdinHandle, self.process?.isRunning == true else {
            throw SmartFillError.glinerUnavailable("GLiNER worker is not running.")
        }
        let requestID = self.nextRequestID
        self.nextRequestID += 1
        var body = payload
        body["id"] = requestID
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        var line = data
        line.append(0x0A)

        let timeout = timeoutSeconds
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.pending[requestID] = continuation
                do {
                    try stdin.write(contentsOf: line)
                } catch {
                    self.failRequest(requestID, error)
                    return
                }
                Task {
                    try await Task.sleep(for: .seconds(timeout))
                    await self.timeout(requestID)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(requestID) }
        }
    }

    private func cancelRequest(_ id: Int) {
        self.failRequest(id, CancellationError())
    }

    private func timeout(_ id: Int) async {
        self.failRequest(id, SmartFillError.extractionFailed("GLiNER timed out."))
    }

    private func failRequest(_ id: Int, _ error: Error) {
        if let pending = self.pending.removeValue(forKey: id) {
            pending.resume(throwing: error)
            self.shutdown()
        }
    }

    private func handleStdout(_ data: Data) {
        if data.isEmpty {
            self.handleTermination()
            return
        }
        self.stdoutBuffer.append(data)
        while let newline = self.stdoutBuffer.firstIndex(of: 0x0A) {
            let line = self.stdoutBuffer.subdata(in: self.stdoutBuffer.startIndex..<newline)
            self.stdoutBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let response = try GLiNERWorkerResponse.decode(line)
                if let id = response.id, let pending = self.pending.removeValue(forKey: id) {
                    pending.resume(returning: response)
                }
            } catch {
                // Skip malformed lines; the request will time out or the next
                // well-formed error object will complete it.
            }
        }
    }

    private func handleTermination() {
        self.failAllPending(SmartFillError.glinerUnavailable("GLiNER worker exited."))
        (self.process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (self.process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        self.process = nil
        self.stdinHandle = nil
    }

    private func failAllPending(_ error: Error) {
        let pending = self.pending
        self.pending.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Python discovery

    static func findSystemPython() throws -> URL {
        let names = ["python3.12", "python3.13", "python3.11", "python3.10", "python3"]
        let directories = ["/opt/homebrew/bin", "/usr/local/bin"]
        for name in names {
            for directory in directories {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path), Self.isSupportedPython(url) {
                    return url
                }
            }
            if let found = Self.which(name), Self.isSupportedPython(found) {
                return found
            }
        }
        throw SmartFillError.pythonMissing
    }

    private static func isSupportedPython(_ url: URL) -> Bool {
        guard
            let output = try? Self.run(
                executable: url,
                arguments: ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"],
                environment: [:],
                timeout: 10)
        else { return false }
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }),
              parts.count >= 2,
              let minor = Int(parts[1])
        else { return false }
        // 3.10–3.13: torch wheels exist. 3.14 is still too new.
        return major == 3 && (10...13).contains(minor)
    }

    private static func which(_ name: String) -> URL? {
        guard
            let output = try? Self.run(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["which", name],
                environment: [:],
                timeout: 5)
        else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    @discardableResult
    private static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval) throws -> String
    {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            environment.forEach { env[$0] = $1 }
            process.environment = env
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try Task.checkCancellation()
        if process.isRunning {
            process.terminate()
            throw SmartFillError.glinerUnavailable("Timed out running \(executable.lastPathComponent).")
        }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let detail = err.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SmartFillError.glinerUnavailable(
                detail.isEmpty
                    ? "\(executable.lastPathComponent) exited \(process.terminationStatus)."
                    : detail)
        }
        return output
    }

    private static func workerEnvironment(hub: URL, model: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["HF_HOME"] = hub.path
        env["HF_HUB_OFFLINE"] = "1"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        env["MARKY_GLINER_MODEL"] = model.path
        return env
    }

    nonisolated static func workerScriptURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "gliner_worker", withExtension: "py") {
            return bundled
        }
        let nearby = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("gliner_worker.py")
        return FileManager.default.fileExists(atPath: nearby.path) ? nearby : nil
    }

    private static func clip(_ text: String) -> String {
        if text.count <= Self.maxClipboardCharacters { return text }
        let end = text.index(text.startIndex, offsetBy: Self.maxClipboardCharacters)
        return String(text[..<end])
    }
}

struct GLiNERWorkerResponse: Decodable, Sendable {
    var id: Int?
    var ok: Bool
    var error: String?
    var values: [ExtractedFieldValue]

    static func decode(_ data: Data) throws -> GLiNERWorkerResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case id, ok, error, values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(Int.self, forKey: .id)
        self.ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        let values = try container.decodeIfPresent([ExtractedFieldValue].self, forKey: .values) ?? []
        self.values = values.compactMap { value in
            let text = value.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? nil
                : ExtractedFieldValue(
                    fieldID: value.fieldID,
                    value: text,
                    confidence: value.confidence)
        }
    }
}
