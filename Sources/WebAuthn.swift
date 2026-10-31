import Foundation
import CryptoKit

/// Rocket as a WebAuthn authenticator: ES256 keys kept in the vault, attestation
/// "none". Everything here is pure data work so it runs in a harness; the page shim and
/// the native sheets live in `Passkeys.swift`.
///
/// The client half (what a browser normally does) is here too, because Rocket is both:
/// `clientDataJSON` is built natively from the frame's real security origin, never from
/// anything the page sends, which is what stops a page from getting a signature that
/// verifies for another site.
enum WebAuthn {

    /// Thrown back to the page as a `DOMException` of this name.
    enum Failure: LocalizedError, Equatable {
        case notAllowed(String)
        case invalidState(String)
        case notSupported(String)
        case security(String)

        var name: String {
            switch self {
            case .notAllowed: return "NotAllowedError"
            case .invalidState: return "InvalidStateError"
            case .notSupported: return "NotSupportedError"
            case .security: return "SecurityError"
            }
        }

        var message: String {
            switch self {
            case .notAllowed(let m), .invalidState(let m), .notSupported(let m), .security(let m): return m
            }
        }

        var reply: [String: Any] { ["error": name, "message": message] }
        var errorDescription: String? { message }
    }

    static let es256 = -7

    // MARK: Origins

    /// The caller's origin, taken from `WKSecurityOrigin`. Only a secure context may use
    /// WebAuthn: https, or http on loopback, which browsers also treat as secure.
    struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int

        init?(scheme: String, host: String, port: Int) {
            let scheme = scheme.lowercased(), host = host.lowercased()
            guard !host.isEmpty else { return nil }
            guard scheme == "https" || (scheme == "http" && SiteMatcher.isLoopback(host)) else { return nil }
            self.scheme = scheme
            self.host = host
            self.port = port
        }

        var serialized: String {
            let isDefault = port == 0 || (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            return isDefault ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
        }
    }

    /// An RP id must be the origin's host or a parent of it, and never wider than the
    /// registrable domain: "github.com" may serve "gist.github.com", but nobody may
    /// claim "com" or a shared suffix like "github.io".
    static func isValid(rpID: String, for host: String) -> Bool {
        let rpID = rpID.lowercased()
        guard !rpID.isEmpty, host == rpID || host.hasSuffix("." + rpID) else { return false }
        let registrable = SiteMatcher.registrableDomain(of: host)
        return rpID == registrable || rpID.hasSuffix("." + registrable)
    }

    // MARK: Requests (parsed at the boundary: the page sends loosely typed JSON)

    struct Creation {
        let rpID: String
        let userHandle: Data
        let userName: String
        let displayName: String?
        let challenge: Data
        let excludedIDs: Set<Data>
        let wantsCredProps: Bool

        init(_ json: [String: Any], origin: Origin) throws {
            let rp = json["rp"] as? [String: Any] ?? [:]
            rpID = (rp["id"] as? String)?.lowercased() ?? origin.host
            guard isValid(rpID: rpID, for: origin.host) else {
                throw Failure.security("\(rpID) is not a valid relying party for \(origin.host).")
            }
            guard let user = json["user"] as? [String: Any],
                  let handle = (user["id"] as? String).flatMap(Base64URL.decode),
                  (1...64).contains(handle.count) else {
                throw Failure.notSupported("user.id must be 1 to 64 bytes.")
            }
            userHandle = handle
            userName = user["name"] as? String ?? ""
            displayName = (user["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            guard let challenge = (json["challenge"] as? String).flatMap(Base64URL.decode), !challenge.isEmpty else {
                throw Failure.notSupported("A challenge is required.")
            }
            self.challenge = challenge
            // An empty list means "anything the authenticator likes", per the spec.
            let params = json["pubKeyCredParams"] as? [[String: Any]] ?? []
            guard params.isEmpty || params.contains(where: {
                ($0["type"] as? String ?? "public-key") == "public-key" && ($0["alg"] as? Int) == es256
            }) else {
                throw Failure.notSupported("Rocket's passkeys use ES256, which this site did not offer.")
            }
            let excluded = json["excludeCredentials"] as? [[String: Any]] ?? []
            excludedIDs = Set(excluded.compactMap { ($0["id"] as? String).flatMap(Base64URL.decode) })
            wantsCredProps = (json["extensions"] as? [String: Any])?["credProps"] as? Bool ?? false
        }
    }

    struct Request {
        let rpID: String
        let challenge: Data
        let allowedIDs: [Data]

        init(_ json: [String: Any], origin: Origin) throws {
            rpID = (json["rpId"] as? String)?.lowercased() ?? origin.host
            guard isValid(rpID: rpID, for: origin.host) else {
                throw Failure.security("\(rpID) is not a valid relying party for \(origin.host).")
            }
            guard let challenge = (json["challenge"] as? String).flatMap(Base64URL.decode), !challenge.isEmpty else {
                throw Failure.notSupported("A challenge is required.")
            }
            self.challenge = challenge
            let allowed = json["allowCredentials"] as? [[String: Any]] ?? []
            allowedIDs = allowed.compactMap { ($0["id"] as? String).flatMap(Base64URL.decode) }
        }

        func admits(_ passkey: PasskeyEntry) -> Bool {
            passkey.rpID == rpID && (allowedIDs.isEmpty || allowedIDs.contains(passkey.credentialID))
        }
    }

    // MARK: Ceremonies

    /// Makes the key pair and the registration response. The caller stores `entry` in
    /// the index and `privateKey` in the secrets, and hands `response` to the page.
    static func register(_ creation: Creation, origin: Origin, crossOrigin: Bool = false,
                         now: Date = Date()) -> (entry: PasskeyEntry, privateKey: Data, response: [String: Any]) {
        let key = P256.Signing.PrivateKey()
        var credentialID = Data(count: 16)
        credentialID.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let entry = PasskeyEntry(id: UUID(), rpID: creation.rpID, credentialID: credentialID,
                                 userHandle: creation.userHandle, userName: creation.userName,
                                 displayName: creation.displayName, created: now, lastUsed: nil)
        let clientData = clientDataJSON(type: "webauthn.create", challenge: creation.challenge,
                                        origin: origin, crossOrigin: crossOrigin)
        let authData = authenticatorData(rpID: creation.rpID, flags: 0x45,
                                         attested: (credentialID, coseKey(key.publicKey)))
        let attestation = CBOR.map([
            (.text("fmt"), .text("none")),
            (.text("attStmt"), .map([])),
            (.text("authData"), .bytes(authData)),
        ]).encoded
        let id = Base64URL.encode(credentialID)
        let extensions: [String: Any] = creation.wantsCredProps ? ["credProps": ["rk": true]] : [:]
        let attestationResponse: [String: Any] = [
            "clientDataJSON": Base64URL.encode(clientData),
            "attestationObject": Base64URL.encode(attestation),
            "authenticatorData": Base64URL.encode(authData),
            "publicKey": Base64URL.encode(key.publicKey.derRepresentation),
            "publicKeyAlgorithm": es256,
            "transports": ["internal"],
        ]
        let response: [String: Any] = [
            "id": id, "rawId": id, "type": "public-key", "authenticatorAttachment": "platform",
            "clientExtensionResults": extensions, "response": attestationResponse,
        ]
        return (entry, key.rawRepresentation, response)
    }

    static func assert(_ request: Request, passkey: PasskeyEntry, privateKey: Data, origin: Origin,
                       crossOrigin: Bool = false) throws -> [String: Any] {
        guard let key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw Failure.notAllowed("This passkey's key is damaged.")
        }
        let clientData = clientDataJSON(type: "webauthn.get", challenge: request.challenge,
                                        origin: origin, crossOrigin: crossOrigin)
        let authData = authenticatorData(rpID: passkey.rpID, flags: 0x05, attested: nil)
        // ES256 signs SHA-256(authData || SHA-256(clientDataJSON)); CryptoKit applies the
        // outer hash itself.
        guard let signature = try? key.signature(for: authData + Data(SHA256.hash(data: clientData))) else {
            throw Failure.notAllowed("Signing failed.")
        }
        let id = Base64URL.encode(passkey.credentialID)
        return [
            "id": id, "rawId": id, "type": "public-key", "authenticatorAttachment": "platform",
            "clientExtensionResults": [String: Any](),
            "response": [
                "clientDataJSON": Base64URL.encode(clientData),
                "authenticatorData": Base64URL.encode(authData),
                "signature": Base64URL.encode(signature.derRepresentation),
                "userHandle": Base64URL.encode(passkey.userHandle),
            ],
        ]
    }

    // MARK: Encoding

    /// Key order is the one the spec's "limited verification algorithm" expects.
    static func clientDataJSON(type: String, challenge: Data, origin: Origin, crossOrigin: Bool) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quotedOrigin = String(decoding: (try? encoder.encode(origin.serialized)) ?? Data("\"\"".utf8), as: UTF8.self)
        let json = "{\"type\":\"\(type)\",\"challenge\":\"\(Base64URL.encode(challenge))\",\"origin\":\(quotedOrigin),\"crossOrigin\":\(crossOrigin)}"
        return Data(json.utf8)
    }

    /// rpIdHash ‖ flags ‖ signCount ‖ [aaguid ‖ credIdLen ‖ credId ‖ COSE key].
    /// Flags: UP 0x01, UV 0x04, AT 0x40. The counter stays 0, as Apple's and Google's
    /// synced passkeys do: a counter only means something for a key that cannot be copied.
    static func authenticatorData(rpID: String, flags: UInt8, attested: (id: Data, coseKey: Data)?) -> Data {
        var data = Data(SHA256.hash(data: Data(rpID.utf8)))
        data.append(flags)
        data.append(contentsOf: [0, 0, 0, 0])
        if let attested {
            data.append(Data(count: 16))
            data.append(contentsOf: [UInt8(attested.id.count >> 8), UInt8(attested.id.count & 0xFF)])
            data.append(attested.id)
            data.append(attested.coseKey)
        }
        return data
    }

    static func coseKey(_ key: P256.Signing.PublicKey) -> Data {
        let raw = key.rawRepresentation   // x ‖ y
        return CBOR.map([
            (.int(1), .int(2)),            // kty: EC2
            (.int(3), .int(es256)),        // alg: ES256
            (.int(-1), .int(1)),           // crv: P-256
            (.int(-2), .bytes(raw.prefix(32))),
            (.int(-3), .bytes(raw.suffix(32))),
        ]).encoded
    }
}

/// The handful of CBOR shapes an attestation object needs, in the canonical encoding
/// (shortest-form lengths, map keys in the order given, which callers keep canonical).
indirect enum CBOR {
    case int(Int)
    case bytes(Data)
    case text(String)
    case map([(CBOR, CBOR)])

    var encoded: Data {
        switch self {
        case .int(let value):
            return value >= 0 ? Self.head(0, UInt64(value)) : Self.head(1, UInt64(-1 - value))
        case .bytes(let data):
            return Self.head(2, UInt64(data.count)) + data
        case .text(let string):
            let utf8 = Data(string.utf8)
            return Self.head(3, UInt64(utf8.count)) + utf8
        case .map(let pairs):
            return pairs.reduce(Self.head(5, UInt64(pairs.count))) { $0 + $1.0.encoded + $1.1.encoded }
        }
    }

    private static func head(_ major: UInt8, _ value: UInt64) -> Data {
        let type = major << 5
        switch value {
        case 0..<24: return Data([type | UInt8(value)])
        case 24..<0x100: return Data([type | 24, UInt8(value)])
        case 0x100..<0x10000: return Data([type | 25, UInt8(value >> 8), UInt8(value & 0xFF)])
        default:
            return Data([type | 26] + (0..<4).reversed().map { UInt8((value >> (UInt64($0) * 8)) & 0xFF) })
        }
    }
}

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
