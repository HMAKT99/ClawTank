// Rules for the RDP password the user chooses. NTLM/NLA exchanges can be attacked offline if
// captured, so require length over cleverness: 12+ characters, not a common or repetitive one.

import Foundation

enum PasswordPolicy {
    enum Problem: Hashable {
        case tooShort(minimum: Int)
        case common
        case repetitive
        case containsUsername
    }

    static let minimumLength = 12

    private static let common: Set<String> = [
        "password1234", "123456789012", "qwertyuiopas", "passwordpassword", "letmeinletmein",
        "administrator", "iloveyou1234", "welcome12345", "000000000000", "111111111111"
    ]

    static func problems(_ password: String, username: String) -> [Problem] {
        var found: [Problem] = []
        if password.count < minimumLength { found.append(.tooShort(minimum: minimumLength)) }
        let lower = password.lowercased()
        if common.contains(lower) || lower.hasPrefix("password") || lower.hasPrefix("qwerty") { found.append(.common) }
        if Set(password).count <= 3 { found.append(.repetitive) }
        if !username.isEmpty, lower.contains(username.lowercased()) { found.append(.containsUsername) }
        return found
    }

    static func message(for problem: Problem) -> String {
        switch problem {
        case .tooShort(let minimum): "Use at least \(minimum) characters."
        case .common: "That password is too common."
        case .repetitive: "Use more than a few different characters."
        case .containsUsername: "Don't include your username."
        }
    }
}
