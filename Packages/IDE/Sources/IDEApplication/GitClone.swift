import Foundation

public struct GitCloneRequest: Equatable, Sendable {
    public let source: String
    public let parent: String
    public let name: String
    public var destination: String { URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(name).path }

    public init(source: String, parent: String, name: String) { self.source = source; self.parent = parent; self.name = name }

    public func validate() throws {
        try Self.validateSource(source)
        guard parent.hasPrefix("/"), !parent.contains("\0"),
              !name.isEmpty, name != ".", name != "..", !name.contains("/"), name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GitInspectionError.failed("Choose a parent folder and a single new folder name")
        }
    }
    public static func validateSource(_ source: String) throws {
        guard !source.isEmpty, source.utf8.count <= 8192, !source.hasPrefix("-"),
              !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GitInspectionError.failed("Enter a repository URL or an absolute local path")
        }

        if source.hasPrefix("/") { return }
        if source.contains("://") {
            guard let url = URLComponents(string: source), let scheme = url.scheme,
                  ["https", "http", "ssh", "git", "file"].contains(scheme), url.password == nil, url.query == nil, url.fragment == nil,
                  !["http", "https"].contains(scheme) || url.user == nil else {
                throw GitInspectionError.failed("Use a supported URL without embedded credentials; configure Git credentials separately")
            }

            return
        }

        guard !source.contains("::"), let colon = source.firstIndex(of: ":"), !source[..<colon].contains("/"),
              !source[..<colon].isEmpty, !source[source.index(after: colon)...].isEmpty else {
            throw GitInspectionError.failed("Enter an HTTPS, SSH, git or file URL, or an absolute local path")
        }
    }
}

public protocol GitCloning: Sendable {
    func clone(_ request: GitCloneRequest, output: @escaping @Sendable (String) -> Void) async throws -> String
}

/// One explicit clone attempt at a time. Input and output stay in memory, not preferences.
@MainActor
public final class GitClone {
    public private(set) var state = GitOperationState.idle
    public private(set) var output = ""
    public private(set) var destination: String?
    public var onSuccess: ((String) -> Void)?
    private let service: any GitCloning
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var stopped = false
    private var observers: [UUID: () -> Void] = [:]

    public init(service: any GitCloning) { self.service = service }

    public func start(_ request: GitCloneRequest) {
        guard !stopped, !state.isBusy else { return }

        do { try request.validate() } catch { state = .failed(error.localizedDescription); changed(); return }
        let token = UUID(); generation = token
        destination = request.destination; output = ""; state = .running; changed()
        task = Task { [weak self, service] in
            do {
                let path = try await service.clone(request) { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        guard let self, !self.stopped, self.generation == token else { return }

                        self.output = String((self.output + chunk).suffix(32_000)); self.changed()
                    }
                }
                try Task.checkCancellation()
                guard let self, !stopped, generation == token else { return }

                state = .succeeded; task = nil; changed(); onSuccess?(path)
            } catch {
                guard let self, !stopped, generation == token else { return }

                state = error is CancellationError || Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
                task = nil; changed()
            }
        }
    }
    public func cancel() {
        guard state.isBusy else { return }

        state = .cancelling; task?.cancel(); changed()
    }
    public func stop() { stopped = true; generation = UUID(); task?.cancel(); onSuccess = nil }
    @discardableResult public func subscribe(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID(); observers[id] = observer; return id
    }
    public func unsubscribe(_ id: UUID) { observers[id] = nil }
    private func changed() { for observer in Array(observers.values) { observer() } }
}
