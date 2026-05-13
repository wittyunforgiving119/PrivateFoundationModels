import Foundation

/// Foreground-`URLSession` HuggingFace repo mirror used to populate a model
/// directory from a plain CLI / Mac / iOS Simulator process.
///
/// `CoreML-LLM`'s upstream `ModelDownloader` uses
/// `URLSessionConfiguration.background(withIdentifier:)`, which requires an
/// app delegate + suspension protocol that don't exist outside a hosted
/// app. From `swift run`, Xcode Previews, or a unit test harness, it
/// fails with `NSURLErrorDomain Code=-1 "unknown error"`. `HFFetcher`
/// bypasses that path: it walks the repo tree via the public HuggingFace
/// API and downloads each file with a standard foreground request.
///
/// This is also useful in production iOS apps that want a deterministic,
/// observable download (per-file progress + per-file caching) without
/// CoreML-LLM's persisted-resume state machine.
public actor HFFetcher {

    /// One progress event per file in the repo. Emitted in tree order.
    public struct ProgressEvent: Sendable, CustomStringConvertible {
        public let path: String
        public let index: Int
        public let total: Int
        public let bytes: Int?
        public let cached: Bool

        public var description: String {
            let bytesText: String
            if let bytes {
                bytesText = " (\(formatBytes(bytes)))"
            } else {
                bytesText = ""
            }
            return "[\(index)/\(total)] \(path)\(bytesText)\(cached ? " — cached" : "")"
        }
    }

    public enum FetchError: Error, CustomStringConvertible {
        case invalidRepo(String)
        case httpStatus(code: Int, url: URL)
        case treeDecode(underlying: Error)

        public var description: String {
            switch self {
            case .invalidRepo(let repo):
                return "HFFetcher: invalid HuggingFace repo path \"\(repo)\""
            case .httpStatus(let code, let url):
                return "HFFetcher: HTTP \(code) for \(url.absoluteString)"
            case .treeDecode(let underlying):
                return "HFFetcher: failed to decode tree listing — \(underlying)"
            }
        }
    }

    public init() {}

    /// Bring every file in the `main` branch of `repo` down to `directory`,
    /// preserving the repo's nested structure. Files whose on-disk size
    /// matches the HF-reported size are skipped. Directories are created
    /// on demand. Set `token` for gated repos.
    public func ensure(
        repo: String,
        in directory: URL,
        token: String? = nil,
        onProgress: (@Sendable (ProgressEvent) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = try await fetchTree(repo: repo, token: token)
        let total = files.count
        for (idx, file) in files.enumerated() {
            let dest = directory.appendingPathComponent(file.path)
            if let existing = sizeOnDisk(at: dest), let expected = file.size, existing == expected {
                onProgress?(.init(path: file.path, index: idx + 1, total: total, bytes: file.size, cached: true))
                continue
            }
            onProgress?(.init(path: file.path, index: idx + 1, total: total, bytes: file.size, cached: false))
            try await downloadFile(path: file.path, repo: repo, to: dest, token: token)
        }
    }

    /// Download a hand-picked list of file paths from `repo` into `directory`.
    /// Used when only a subset of a repo (typically tokenizer files from the
    /// source HuggingFace repo) is needed alongside a CoreML bundle.
    public func ensureFiles(
        _ paths: [String],
        repo: String,
        in directory: URL,
        token: String? = nil,
        onProgress: (@Sendable (ProgressEvent) -> Void)? = nil
    ) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = paths.count
        for (idx, path) in paths.enumerated() {
            let dest = directory.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: dest.path) {
                onProgress?(.init(path: path, index: idx + 1, total: total, bytes: nil, cached: true))
                continue
            }
            onProgress?(.init(path: path, index: idx + 1, total: total, bytes: nil, cached: false))
            try await downloadFile(path: path, repo: repo, to: dest, token: token)
        }
    }

    // MARK: - Tree

    private func fetchTree(repo: String, token: String?) async throws -> [HFFile] {
        guard var components = URLComponents(string: "https://huggingface.co/api/models/\(repo)/tree/main") else {
            throw FetchError.invalidRepo(repo)
        }
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        guard let url = components.url else { throw FetchError.invalidRepo(repo) }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        try check(response: response, url: url)
        do {
            let decoded = try JSONDecoder().decode([HFFile].self, from: data)
            return decoded.filter { $0.type == "file" }
        } catch {
            throw FetchError.treeDecode(underlying: error)
        }
    }

    private func downloadFile(path: String, repo: String, to destination: URL, token: String?) async throws {
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(path)") else {
            throw FetchError.invalidRepo(repo)
        }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        // Retry on transient network failures. HF's Xet LFS backend
        // (cas-bridge.xethub.hf.co) drops multi-GB downloads more often
        // than fresh S3 would; on a dropped connection the temp file
        // URLSession wrote to is discarded by the runtime, so a clean
        // retry is safe.
        let maxAttempts = 4
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let (tempURL, response) = try await session.download(for: request)
                try check(response: response, url: url)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tempURL, to: destination)
                return
            } catch {
                lastError = error
                if !isRetriable(error) || attempt == maxAttempts {
                    throw error
                }
                // Backoff: 1s, 2s, 4s.
                let delayNanos = UInt64(1_000_000_000) << (attempt - 1)
                try? await Task.sleep(nanoseconds: delayNanos)
            }
        }
        throw lastError ?? FetchError.httpStatus(code: -1, url: url)
    }

    private func isRetriable(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorResourceUnavailable,
                 NSURLErrorBadServerResponse,
                 NSURLErrorCannotLoadFromNetwork:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func check(response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode >= 400 {
            throw FetchError.httpStatus(code: http.statusCode, url: url)
        }
    }

    private func sizeOnDisk(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.size] as? Int
    }

    // MARK: - URLSession

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Big artifact files (multi-GB) need a generous resource timeout.
        config.timeoutIntervalForResource = 3600
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    private struct HFFile: Decodable {
        let type: String
        let path: String
        let size: Int?
    }
}

private func formatBytes(_ bytes: Int) -> String {
    let units = ["B", "KB", "MB", "GB"]
    var size = Double(bytes)
    var idx = 0
    while size >= 1024 && idx < units.count - 1 {
        size /= 1024
        idx += 1
    }
    return String(format: idx == 0 ? "%.0f %@" : "%.1f %@", size, units[idx])
}
