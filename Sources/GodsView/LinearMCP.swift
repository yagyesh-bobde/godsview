import Foundation

struct LinearIssue: Identifiable, Sendable {
    let id: String
    let title: String
    let status: String?
    let url: URL

    static func references(in text: String) -> [String] {
        let pattern = #"(?i)(?<![a-z0-9])([a-z][a-z0-9]{0,15}-[1-9][0-9]*)(?![a-z0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let id = text[range].uppercased()
            return seen.insert(id).inserted ? id : nil
        }
    }
}

struct LinearError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A Streamable HTTP session belongs to one batch of issue reads.
final class LinearMCP {
    static let defaultEndpoint = "http://127.0.0.1:3050/mcp"
    private let endpoint: URL
    private let transport: URLSession
    private var sessionID: String?
    private var version = "2025-03-26"
    private var sequence = 0
    private var tool: String?
    private var acceptsFields = false

    init(endpoint: String, transport: URLSession = .shared) throws {
        guard let url = URL(string: endpoint), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw LinearError(message: "Enter an HTTPS MCP URL or a local HTTP address.")
        }
        self.endpoint = url
        self.transport = transport
    }

    func connect() async throws {
        let result = try await rpc("initialize", ["protocolVersion": version, "capabilities": [:],
                                                  "clientInfo": ["name": "GodsView", "version": "0.4"]])
        if let negotiated = result["protocolVersion"] as? String { version = negotiated }
        _ = try await rpc("notifications/initialized", [:], notification: true)
        var cursor: String?
        repeat {
            let page = try await rpc("tools/list", cursor.map { ["cursor": $0] } ?? [:])
            let tools = page["tools"] as? [[String: Any]] ?? []
            if let entry = tools.first(where: {
                guard let name = $0["name"] as? String else { return false }
                return name == "get_issue" || (name.contains("linear") && name.hasSuffix("get_issue"))
            }) {
                tool = entry["name"] as? String
                let schema = entry["inputSchema"] as? [String: Any]
                acceptsFields = (schema?["properties"] as? [String: Any])?["fields"] != nil
                return
            }
            cursor = page["nextCursor"] as? String
        } while cursor != nil
        throw LinearError(message: "This MCP server does not advertise a Linear get_issue tool.")
    }

    func issue(_ id: String) async throws -> LinearIssue {
        guard let tool else { throw LinearError(message: "Connect to Linear first.") }
        var args: [String: Any] = ["id": id]
        if acceptsFields { args["fields"] = ["id", "title", "status", "url"] }
        let result = try await rpc("tools/call", ["name": tool, "arguments": args])
        let content = result["content"] as? [[String: Any]]
        let text = content?.compactMap { $0["text"] as? String }.first ?? ""
        let object = result["structuredContent"] as? [String: Any] ??
            ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
        guard result["isError"] as? Bool != true, let object, let title = object["title"] as? String,
              let address = object["url"] as? String, let url = URL(string: address), url.scheme == "https" else {
            throw LinearError(message: "Couldn’t read \(id) from Linear.")
        }
        return LinearIssue(id: id, title: title, status: object["status"] as? String, url: url)
    }

    func close() async {
        guard sessionID != nil else { return }
        var request = makeRequest()
        request.httpMethod = "DELETE"
        _ = try? await transport.data(for: request)
        sessionID = nil
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        return request
    }

    private func rpc(_ method: String, _ params: [String: Any], notification: Bool = false) async throws -> [String: Any] {
        var request = makeRequest()
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        sequence += 1
        if !notification { body["id"] = sequence }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LinearError(message: "The MCP endpoint returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
        if notification { return [:] }
        let messages: [Data]
        if http.mimeType == "text/event-stream" {
            let stream = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
            messages = stream.components(separatedBy: "\n\n").map { event in
                let payload = event.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5) }
                return Data(payload.joined(separator: "\n").utf8)
            }
        } else { messages = [bytes] }
        for message in messages {
            guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any],
                  object["id"] as? Int == sequence else { continue }
            if let result = object["result"] as? [String: Any] { return result }
            if let error = object["error"] as? [String: Any], let details = error["message"] as? String {
                throw LinearError(message: details)
            }
        }
        throw LinearError(message: "The MCP server returned an unreadable response.")
    }
}

actor LinkedIssueCache {
    static let shared = LinkedIssueCache()
    private struct Entry { let issue: LinearIssue; let date: Date }
    private var entries: [String: Entry] = [:]

    func lookup(_ ids: [String], endpoint: String) async throws -> (issues: [LinearIssue], missing: [String]) {
        entries = entries.filter { Date().timeIntervalSince($0.value.date) < 300 }
        var found = ids.compactMap { entries[endpoint + "/" + $0]?.issue }
        let pending = ids.filter { id in !found.contains { $0.id == id } }
        var missing: [String] = []
        if !pending.isEmpty {
            let session = try LinearMCP(endpoint: endpoint)
            do {
                try await session.connect()
                for id in pending {
                    try Task.checkCancellation()
                    do {
                        let issue = try await session.issue(id)
                        entries[endpoint + "/" + id] = Entry(issue: issue, date: .now)
                        found.append(issue)
                    } catch { missing.append(id) }
                }
            } catch { await session.close(); throw error }
            await session.close()
        }
        return (ids.compactMap { id in found.first { $0.id == id } }, missing)
    }
}
