import Cocoa
import Network
import WebKit

/// MCP over loopback HTTP, so Claude Code, Codex and anything else that speaks the
/// protocol can drive Rocket without computer use. Rocket is the server itself: one
/// `POST /mcp` endpoint on 127.0.0.1, JSON-RPC in, JSON out — no second binary, no
/// shim process, and `curl` works too.
///
/// The endpoint is a door into the user's logged-in sessions, so the checks are the
/// point of this file, not the parsing:
///  - loopback bind, and `Host` must be loopback too (a DNS-rebound page arrives with
///    its own host name);
///  - any request carrying `Origin` or `Sec-Fetch-Site` is refused — a web page's
///    `fetch` always sends one, an agent's HTTP client never does;
///  - `Content-Type` must be `application/json`, which no page can send cross-origin
///    without a preflight this server never answers;
///  - a bearer token, generated once, which is what keeps another macOS account on
///    the same Mac out (loopback is shared between users).
/// Off by default: `AgentAccess` reads `?? false`, like `RestoreSession`, because it
/// changes who can act in the browser and that is something to opt into.
///
/// The protocol served is the initialize-handshake flavour of MCP. The 2026-07-28
/// revision replaced that with a stateless `server/discover`; clients that speak it
/// still probe, get method-not-found here, and fall back to `initialize` — which is
/// the documented path, so one small server covers both generations.
final class AgentServer {
    static let shared = AgentServer()
    static let defaultPort: UInt16 = 9317
    static let version = "1"
    private static let knownProtocolVersions: Set<String> = ["2025-03-26", "2025-06-18", "2025-11-25"]
    private static let maxRequestBytes = 4 * 1024 * 1024

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "AgentAccess") }
        set { UserDefaults.standard.set(newValue, forKey: "AgentAccess") }
    }

    static var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: "AgentPort")
        return (1...65535).contains(stored) ? UInt16(stored) : defaultPort
    }

    /// 256 random bits, made once and kept in UserDefaults. Same trust level as the
    /// rest of what lives there: readable by this account, nobody else.
    static var token: String {
        if let existing = UserDefaults.standard.string(forKey: "AgentToken"), !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(fresh, forKey: "AgentToken")
        return fresh
    }

    static var url: String { "http://127.0.0.1:\(port)/mcp" }

    /// One line to paste; `--scope user` so every project's Claude Code sees Rocket.
    static var claudeCodeSetupCommand: String {
        "claude mcp add --transport http --scope user rocket \(url) --header \"Authorization: Bearer \(token)\""
    }

    /// Codex has no CLI flag for a static header; this goes in ~/.codex/config.toml.
    static var codexSetupSnippet: String {
        """
        [mcp_servers.rocket]
        url = "\(url)"
        http_headers = { "Authorization" = "Bearer \(token)" }
        """
    }

    /// Set by AppDelegate before `start()`. Incognito tabs are filtered out here, not
    /// by the tools — a tool must not be able to reach one by mistake.
    var context: AgentContext?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "rocket.agent")

    var isRunning: Bool { listener != nil }

    func start() {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.async { self?.stop() }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - HTTP

    struct HTTPRequest {
        let method: String
        let path: String
        /// Lower-cased names.
        let headers: [String: String]
        let body: Data
    }

    /// nil while the bytes so far do not hold a whole request yet.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                           headers: headers, body: data[bodyStart..<bodyStart + length])
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(into: Data(), on: connection)
    }

    private func receive(into buffer: Data, on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if let request = Self.parse(buffer) {
                self.handle(request) { status, body in
                    self.respond(status: status, body: body, on: connection)
                }
            } else if error != nil || isComplete || buffer.count > Self.maxRequestBytes {
                connection.cancel()
            } else {
                self.receive(into: buffer, on: connection)
            }
        }
    }

    private func respond(status: Int, body: Data, on connection: NWConnection) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized",
                      403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                      415: "Unsupported Media Type"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Checks

    /// Everything a request must pass before its body is even parsed. Pure, so the
    /// rules can be read in one place.
    static func rejection(for request: HTTPRequest, token: String) -> (Int, String)? {
        guard request.path == "/mcp" else { return (404, "not found") }
        guard request.method == "POST" else { return (405, "POST only") }
        let host = request.headers["host"]?.split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost", "[::1]"].contains(host) else { return (403, "host is not loopback") }
        guard request.headers["origin"] == nil, request.headers["sec-fetch-site"] == nil else {
            return (403, "browser-originated requests are refused")
        }
        guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
            return (415, "Content-Type must be application/json")
        }
        guard request.headers["authorization"] == "Bearer \(token)" else { return (401, "bad token") }
        return nil
    }

    private func handle(_ request: HTTPRequest, completion: @escaping (Int, Data) -> Void) {
        if let (status, message) = Self.rejection(for: request, token: Self.token) {
            completion(status, Self.json(["error": message]))
            return
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            completion(400, Self.json(Self.rpcError(id: nil, code: -32700, message: "expected one JSON-RPC 2.0 request")))
            return
        }
        // A notification has no id and gets no body — 202 is what the transport asks for.
        guard let id = message["id"], !(id is NSNull) else {
            completion(202, Data())
            return
        }
        dispatch(method: method, params: message["params"] as? [String: Any] ?? [:]) { outcome in
            switch outcome {
            case .success(let result):
                completion(200, Self.json(["jsonrpc": "2.0", "id": id, "result": result]))
            case .failure(let error):
                completion(200, Self.json(Self.rpcError(id: id, code: error.code, message: error.message)))
            }
        }
    }

    // MARK: - JSON-RPC

    private struct RPCError: Error {
        let code: Int
        let message: String
    }

    private func dispatch(method: String, params: [String: Any],
                          completion: @escaping (Result<[String: Any], RPCError>) -> Void) {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            completion(.success([
                "protocolVersion": Self.knownProtocolVersions.contains(requested) ? requested : "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "Rocket", "version": Self.version],
                "instructions": AgentTools.instructions,
            ]))
        case "ping":
            completion(.success([:]))
        case "tools/list":
            completion(.success(["tools": AgentTools.all.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema]
            }]))
        case "tools/call":
            guard let name = params["name"] as? String,
                  let tool = AgentTools.all.first(where: { $0.name == name }) else {
                completion(.failure(RPCError(code: -32602, message: "unknown tool")))
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            DispatchQueue.main.async { [self] in
                guard let context else {
                    completion(.failure(RPCError(code: -32603, message: "server not attached to the app")))
                    return
                }
                tool.run(arguments, context) { result in
                    // A tool's own failure is in-band (`isError`), so the model reads
                    // it and tries something else; only protocol trouble is an RPC error.
                    switch result {
                    case .success(let content):
                        completion(.success(["content": content.map(Self.block), "isError": false]))
                    case .failure(let error):
                        completion(.success(["content": [Self.block(.text(error.message))], "isError": true]))
                    }
                }
            }
        default:
            completion(.failure(RPCError(code: -32601, message: "Method not found")))
        }
    }

    private static func block(_ content: AgentContent) -> [String: Any] {
        switch content {
        case .text(let text):
            return ["type": "text", "text": text]
        case .image(let pngBase64):
            return ["type": "image", "data": pngBase64, "mimeType": "image/png"]
        }
    }

    private static func rpcError(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
