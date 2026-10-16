import CryptoKit
import Foundation

// MARK: - GitHubTokenAccess
//
// Whether the GitHub token may write: approve, request changes, comment, merge, re-run CI.
// A classic token lists its scopes in the X-OAuth-Scopes header of every answer ("repo" is
// read and write). A fine-grained token (github_pat_…) says nothing: it stays unknown until
// GitHub refuses one of its writes, which is remembered for that token.

enum GitHubWriteAccess: Equatable { case unknown, readWrite, readOnly }

@MainActor
final class GitHubTokenAccess: ObservableObject {
    static let shared = GitHubTokenAccess()

    @Published private(set) var access: GitHubWriteAccess = .unknown

    nonisolated static let readOnlyMessage = "This GitHub token is read-only: Coucou can show pull requests and CI, but not approve, merge or re-run them. Use a classic token with repo, or a fine-grained one with Pull requests (and Contents, Actions) set to read and write."

    /// The fingerprint of the token GitHub last refused a write to.
    private static let refusedKey = "githubTokenWriteRefused"

    private init() { reload() }

    /// The token changed: forget what was learned about the last one.
    func reload() {
        guard let token = KeychainStore.shared.get("github-token") else { access = .unknown; return }
        access = UserDefaults.standard.string(forKey: Self.refusedKey) == Self.fingerprint(token) ? .readOnly : .unknown
    }

    /// The X-OAuth-Scopes header of an answer to the token. Ignored for a fine-grained token,
    /// which has no scopes.
    func noteScopes(_ header: String?) {
        guard let header, let token = KeychainStore.shared.get("github-token"),
              !token.hasPrefix("github_pat_") else { return }
        let scopes = header.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        access = scopes.contains("repo") ? .readWrite : .readOnly
    }

    func noteWriteRefused() {
        access = .readOnly
        if let token = KeychainStore.shared.get("github-token") {
            UserDefaults.standard.set(Self.fingerprint(token), forKey: Self.refusedKey)
        }
    }

    func noteWriteAccepted() {
        access = .readWrite
        UserDefaults.standard.removeObject(forKey: Self.refusedKey)
    }

    /// GitHub's 403 to a token lacking the permission: "Resource not accessible by personal
    /// access token". Other 403s (rate limits, a repository rule) don't make it read-only.
    nonisolated static func isReadOnlyRefusal(status: Int, message: String) -> Bool {
        status == 403 && message.localizedCaseInsensitiveContains("not accessible by personal access token")
    }

    private static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
