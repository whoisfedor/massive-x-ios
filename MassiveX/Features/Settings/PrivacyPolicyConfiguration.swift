import Foundation

enum PrivacyPolicyConfiguration {
    static let ownerVerifiedPolicyURL: String? = "https://massive-x.com/privacy/"
    static var publishedURL: URL? { validatedURL(ownerVerifiedPolicyURL) }

    static func validatedURL(_ value: String?) -> URL? {
        guard let value, !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }
        return components.url
    }
}
