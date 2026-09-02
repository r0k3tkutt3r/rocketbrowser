import Foundation

/// RFC 4180: quoted fields, doubled quotes, commas and newlines inside quotes, CRLF or
/// lone CR line breaks, an optional UTF-8 BOM. Blank lines are dropped.
enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var index = 0
        func endField() { row.append(String(field)); field = String.UnicodeScalarView() }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(scalar)
                }
            } else {
                switch scalar {
                case "\"": inQuotes = true
                case ",": endField()
                case "\r":
                    if index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                    endRow()
                case "\n": endRow()
                default: field.append(scalar)
                }
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

struct ImportedCredential: Equatable {
    var host: String
    var url: String?
    var username: String
    var password: String
    var title: String?
    var notes: String?
    var otpAuth: String?
}

struct ImportResult {
    var credentials: [ImportedCredential]
    /// Rows with no password or no usable site — counted, never silently dropped.
    var unreadableRows: Int
}

/// Maps a password CSV by header name, so Apple Passwords, Chrome/Google and Firefox
/// exports all import without the user having to say which one it is.
enum PasswordImport {

    private static let aliases: [String: [String]] = [
        "url": ["url", "website", "web site", "site", "login_uri", "formactionorigin", "hostname"],
        "username": ["username", "user name", "login", "user", "login_username", "email"],
        "password": ["password", "login_password", "pass"],
        "title": ["title", "name"],
        "notes": ["notes", "note", "extra", "comments", "comment"],
        "otpauth": ["otpauth", "totp", "otp", "one-time password"],
    ]

    static func parse(csv: String) -> ImportResult? {
        let rows = CSVParser.parse(csv)
        guard let header = rows.first else { return nil }
        var columns: [String: Int] = [:]
        for (position, raw) in header.enumerated() {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            for (field, names) in aliases where names.contains(name) && columns[field] == nil {
                columns[field] = position
            }
        }
        guard let passwordColumn = columns["password"], columns["url"] != nil || columns["title"] != nil else {
            return nil
        }
        var credentials: [ImportedCredential] = []
        var unreadable = 0
        for row in rows.dropFirst() {
            func value(_ field: String) -> String? {
                guard let column = columns[field], column < row.count else { return nil }
                let text = row[column].trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            guard passwordColumn < row.count, !row[passwordColumn].isEmpty else { unreadable += 1; continue }
            let rawURL = value("url")
            guard let (host, url) = site(from: rawURL, title: value("title")) else { unreadable += 1; continue }
            credentials.append(ImportedCredential(
                host: host, url: url,
                username: value("username") ?? "",
                password: row[passwordColumn],
                title: value("title"), notes: value("notes"), otpAuth: value("otpauth")))
        }
        return ImportResult(credentials: credentials, unreadableRows: unreadable)
    }

    /// A schemeless "example.org" becomes https://example.org; with no URL at all, a
    /// title that looks like a host is used, so hand-made spreadsheets still import.
    private static func site(from rawURL: String?, title: String?) -> (String, String?)? {
        var candidate = rawURL ?? ""
        if candidate.isEmpty, let title, title.contains("."), !title.contains(" ") { candidate = title }
        guard !candidate.isEmpty else { return nil }
        if !candidate.contains("://") { candidate = "https://" + candidate }
        guard let url = URL(string: candidate), let host = SiteMatcher.host(from: url) else { return nil }
        return (host, candidate)
    }

    struct MergePlan {
        var additions: [ImportedCredential] = []
        var updates: [(entry: PasswordEntry, credential: ImportedCredential)] = []
        var skipped = 0
    }

    /// Same site + username + password → skipped; same site + username, new password →
    /// update; anything else → add. Repeats inside the file collapse the same way.
    static func merge(_ credentials: [ImportedCredential], into existing: [PasswordEntry],
                      passwordFor: (UUID) -> String?) -> MergePlan {
        var plan = MergePlan()
        var seen: [String: Int] = [:]           // key → index into plan.additions
        var updated: Set<UUID> = []
        for credential in credentials {
            let key = "\(SiteMatcher.displayHost(credential.host))\u{0}\(credential.username)"
            if let match = existing.first(where: {
                SiteMatcher.isExact(entryHost: $0.host, pageHost: credential.host) && $0.username == credential.username
            }) {
                if passwordFor(match.id) == credential.password || updated.contains(match.id) {
                    plan.skipped += 1
                } else {
                    plan.updates.append((match, credential))
                    updated.insert(match.id)
                }
                continue
            }
            if let position = seen[key] {
                if plan.additions[position].password == credential.password {
                    plan.skipped += 1
                } else {
                    plan.additions[position] = credential
                }
                continue
            }
            seen[key] = plan.additions.count
            plan.additions.append(credential)
        }
        return plan
    }
}

/// Apple's column set, so the file goes straight back into Passwords or Chrome.
enum PasswordExport {
    static let header = "Title,URL,Username,Password,Notes,OTPAuth"

    static func csv(entries: [PasswordEntry], secrets: VaultSecrets) -> String {
        var lines = [header]
        for entry in entries {
            let secret = secrets[entry.id]
            // Only the descriptive columns are defused: a spreadsheet treats a leading
            // =, +, - or @ as a formula, and a title or note can come from a site or an
            // imported file. Usernames and passwords are left byte-exact, because a
            // credential that survives the round trip matters more than a spreadsheet
            // someone opened this file in by mistake.
            let fields = [defuse(entry.title ?? SiteMatcher.displayHost(entry.host)),
                          defuse(entry.url ?? "https://\(entry.host)"),
                          entry.username,
                          secret?.password ?? "",
                          defuse(secret?.notes ?? ""),
                          defuse(secret?.otpAuth ?? "")]
            lines.append(fields.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Neutralises spreadsheet formula injection without changing what the text says.
    static func defuse(_ field: String) -> String {
        guard let first = field.first, "=+-@\t\r".contains(first) else { return field }
        return "'" + field
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
