import Foundation
import Testing
@testable import GodsView

@Test func markdownRetainsReviewHeadingsListsInlineLinksAndCode() {
    let blocks = MarkdownBlock.parse("""
    ## Validation

    1. Read the **review** on [GitHub](https://github.com/).
    2. Run the checks.

    ```swift
    let result = true
    ```
    """, relativeTo: nil)
    #expect(blocks.count == 4)
    #expect(blocks.first?.heading == 2)
    #expect(blocks[1].marker == "1.")
    #expect(blocks[2].marker == "2.")
    #expect(blocks.last?.code == true)
    #expect(blocks[1].text.runs.contains { $0.link?.host == "github.com" })
}

@Test func linkedIssueReferencesIncludeBranchNamesAndDeduplicate() {
    let text = "Fix APP-12 on feat/app-12-cache. See https://linear.app/example/issue/OPS-3/checks"
    #expect(LinearIssue.references(in: text) == ["APP-12", "OPS-3"])
}

private final class LinearProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let request = self.request
            var status = 200
            var headers = ["Content-Type": "application/json"]
            var payload = Data()
            if request.httpMethod == "DELETE" { status = 204 }
            else {
                var input = request.httpBody ?? Data()
                if input.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 2048)
                    while true {
                        let n = stream.read(&buffer, maxLength: buffer.count)
                        if n <= 0 { break }
                        input.append(contentsOf: buffer.prefix(n))
                    }
                }
                let body = try JSONSerialization.jsonObject(with: input) as? [String: Any]
                let method = body?["method"] as? String
                var result: [String: Any] = [:]
                if method != "initialize" && request.value(forHTTPHeaderField: "Mcp-Session-Id") != "fixture" {
                    throw URLError(.userAuthenticationRequired)
                }
                switch method {
                case "initialize":
                    headers["Mcp-Session-Id"] = "fixture"
                    result = ["protocolVersion": "2025-03-26"]
                case "notifications/initialized": status = 202
                case "tools/list":
                    result = ["tools": [["name": "linear_1mcp_get_issue", "inputSchema": ["properties": ["fields": [:]]]]]]
                case "tools/call":
                    let params = body?["params"] as? [String: Any]
                    let args = params?["arguments"] as? [String: Any]
                    guard params?["name"] as? String == "linear_1mcp_get_issue", args?["id"] as? String == "APP-2",
                          (args?["fields"] as? [String])?.contains("title") == true else { throw URLError(.badURL) }
                    result = ["content": [["type": "text", "text": #"{"title":"Example","url":"https://linear.app/example/issue/APP-2","status":"Done"}"#]]]
                default: throw URLError(.unsupportedURL)
                }
                if let id = body?["id"] {
                    payload = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":id, "result":result])
                    if method == "tools/call" {
                        headers["Content-Type"] = "text/event-stream"
                        payload = Data("event: message\r\ndata: ".utf8) + payload + Data("\r\n\r\n".utf8)
                    }
                }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Test func linearUsesNegotiatedSessionAndDecodesStreamableIssue() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [LinearProtocol.self]
    let mcp = try LinearMCP(endpoint: "http://127.0.0.1:3050/mcp", transport: URLSession(configuration: config))
    try await mcp.connect()
    let issue = try await mcp.issue("APP-2")
    #expect(issue.status == "Done" && issue.title == "Example")
    await mcp.close()
}
