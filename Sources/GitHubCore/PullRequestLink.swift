import Foundation

public struct PullRequestLink: Equatable, Sendable {
    public let owner: String
    public let repository: String
    public let number: Int
    public var nameWithOwner: String { owner + "/" + repository }

    public init?(_ input: String) {
        var string = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.lowercased().hasPrefix("github.com/") { string = "https://" + string }
        guard let url = URLComponents(string: string), url.scheme?.lowercased() == "https",
              ["github.com", "www.github.com"].contains(url.host?.lowercased()), url.port == nil, url.user == nil,
              url.password == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 4, parts[2] == "pull", let n = Int32(parts[3]), n > 0,
              parts[3].allSatisfy(\.isNumber) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.prefix(2).allSatisfy({ $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        owner = String(parts[0])
        repository = String(parts[1])
        number = Int(n)
    }
}
