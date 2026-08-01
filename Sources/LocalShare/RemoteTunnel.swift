import Foundation

struct RemoteSettings: Equatable {
    var publicOrigin = ""
    var sshHost = ""
    var sshPort = 2200
    var identityPath = ""

    var publicURL: URL? {
        let raw = publicOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }

    var customDomain: String? { publicURL?.host }

    var isValid: Bool {
        guard publicURL != nil,
              !sshHost.isEmpty,
              !sshHost.contains(where: { $0.isWhitespace || $0 == "/" }),
              (1...65535).contains(sshPort) else { return false }
        return true
    }

    func tunnelConfiguration(localAddress: String, localPort: in_port_t) -> RemoteTunnel.Configuration? {
        guard isValid, let customDomain else { return nil }
        let identity = identityPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return RemoteTunnel.Configuration(
            sshHost: sshHost,
            sshPort: sshPort,
            identityPath: identity.isEmpty ? nil : (identity as NSString).expandingTildeInPath,
            customDomain: customDomain,
            localAddress: localAddress,
            localPort: localPort
        )
    }
}

@MainActor
final class RemoteTunnel {
    enum Status: Equatable {
        case disabled
        case connecting
        case online
        case offline
    }

    struct Configuration: Equatable {
        let sshHost: String
        let sshPort: Int
        let identityPath: String?
        let customDomain: String
        let localAddress: String
        let localPort: in_port_t
    }

    private(set) var status: Status = .disabled
    private(set) var lastError: String?
    var onStateChange: ((Status, String?) -> Void)?

    private var process: Process?
    private var stderrPipe: Pipe?
    private var retryTask: Task<Void, Never>?
    private var configuration: Configuration?
    private var shouldRun = false
    private var retryDelay: TimeInterval = 1

    nonisolated static func arguments(for config: Configuration) -> [String] {
        var args = [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ClearAllForwardings=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
            "-p", String(config.sshPort),
        ]
        if let identityPath = config.identityPath {
            args += ["-i", identityPath]
        }
        args += [
            "-R", ":80:\(config.localAddress):\(config.localPort)",
            "v0@\(config.sshHost)",
            "http",
            "--proxy_name", "localshare",
            "--custom_domain", config.customDomain,
        ]
        return args
    }

    func start(_ configuration: Configuration) {
        shouldRun = true
        self.configuration = configuration
        retryTask?.cancel()
        retryTask = nil
        retryDelay = 1
        stopProcess()
        launch()
    }

    func stop() {
        shouldRun = false
        configuration = nil
        retryTask?.cancel()
        retryTask = nil
        stopProcess()
        setStatus(.disabled, error: nil)
    }

    private func launch() {
        guard shouldRun, let configuration else { return }
        setStatus(.connecting, error: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(for: configuration)
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")

        let stderr = Pipe()
        process.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            Task { @MainActor [weak self] in self?.lastError = message }
        }
        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in self?.handleTermination(terminated) }
        }
        self.process = process
        self.stderrPipe = stderr

        do {
            try process.run()
            retryDelay = 1
            setStatus(.online, error: nil)
        } catch {
            self.process = nil
            self.stderrPipe = nil
            setStatus(.offline, error: error.localizedDescription)
            scheduleRetry()
        }
    }

    private func handleTermination(_ terminated: Process) {
        guard process === terminated else { return }
        process = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        guard shouldRun else {
            setStatus(.disabled, error: nil)
            return
        }
        let error = lastError ?? "ssh exited with status \(terminated.terminationStatus)"
        setStatus(.offline, error: error)
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard shouldRun, configuration != nil else { return }
        retryTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard let self, self.shouldRun else { return }
            self.launch()
        }
    }

    private func stopProcess() {
        guard let process else { return }
        process.terminationHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        self.process = nil
        stderrPipe = nil
    }

    private func setStatus(_ status: Status, error: String?) {
        self.status = status
        lastError = error
        onStateChange?(status, error)
    }
}
