#if !APPSTORE
import Foundation

// MARK: - GitHubReview
//
// The pull requests page of the Coucou window: every open pull request the reviewing account
// can see, their files, and the reviews it sends. The reviewing account is the one of
// "github-review-token" when set (another account of yours, which may approve your own pull
// requests), else the one of "github-token".

struct ReviewPR: Identifiable, Equatable {
    var repo: String          // "owner/name"
    var number: Int
    var title: String
    var url: String
    var author: String
    var isDraft: Bool
    var updatedAt: Date?
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var headRef: String
    var baseRef: String
    var review: ReviewState
    /// The reviewing account's last review: "APPROVED", "CHANGES_REQUESTED", "COMMENTED"…
    var viewerReview: String?
    var requestedReviewers: [String]

    var id: String { "\(repo)#\(number)" }
}

struct ReviewFile: Identifiable, Equatable {
    var path: String
    var status: String        // "added", "modified", "removed", "renamed"…
    var diff: FileDiff
    var id: String { path }
}

enum ReviewEvent: String {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"
}

enum GitHubReview {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The token reviews go out with: the review account's, else the main one.
    static var token: String? {
        KeychainStore.shared.get("github-review-token") ?? KeychainStore.shared.get("github-token")
    }

    static var usesReviewAccount: Bool { KeychainStore.shared.get("github-review-token") != nil }

    // MARK: Inbox

    /// The reviewing account's login, and the open pull requests of the 50 repositories it
    /// pushed to last (20 per repository, most recently updated first).
    // lean-ctx: 50 repos × 20 PRs in one query, upgrade to paging when someone needs more
    static func inbox() async throws -> (login: String, prs: [ReviewPR]) {
        let json = try await graphQL(inboxQuery)
        guard let viewer = (json["data"] as? [String: Any])?["viewer"] as? [String: Any] else {
            let message = ((json["errors"] as? [[String: Any]])?.first?["message"] as? String) ?? "GitHub sent no data"
            throw Failure(message: message)
        }
        let login = viewer["login"] as? String ?? ""
        let repos = ((viewer["repositories"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let iso = ISO8601DateFormatter()
        var prs: [ReviewPR] = []
        for repo in repos {
            guard let name = repo["nameWithOwner"] as? String else { continue }
            let nodes = ((repo["pullRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for node in nodes {
                guard let number = node["number"] as? Int, let title = node["title"] as? String,
                      let url = node["url"] as? String else { continue }
                let requests = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
                prs.append(ReviewPR(
                    repo: name, number: number, title: title, url: url,
                    author: (node["author"] as? [String: Any])?["login"] as? String ?? "ghost",
                    isDraft: node["isDraft"] as? Bool ?? false,
                    updatedAt: (node["updatedAt"] as? String).flatMap { iso.date(from: $0) },
                    additions: node["additions"] as? Int ?? 0,
                    deletions: node["deletions"] as? Int ?? 0,
                    changedFiles: node["changedFiles"] as? Int ?? 0,
                    headRef: node["headRefName"] as? String ?? "",
                    baseRef: node["baseRefName"] as? String ?? "",
                    review: ReviewState(rawGitHub: node["reviewDecision"] as? String),
                    viewerReview: (node["viewerLatestReview"] as? [String: Any])?["state"] as? String,
                    requestedReviewers: requests.compactMap {
                        ($0["requestedReviewer"] as? [String: Any])?["login"] as? String
                    }))
            }
        }
        prs.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return (login, prs)
    }

    // MARK: One pull request

    /// Its description and its files, up to 300 (GitHub lists 100 per page).
    static func details(of pr: ReviewPR) async throws -> (body: String, files: [ReviewFile]) {
        let base = "https://api.github.com/repos/\(pr.repo)/pulls/\(pr.number)"
        let pull = try await rest(base) as? [String: Any]
        var files: [ReviewFile] = []
        for page in 1...3 {
            let list = try await rest("\(base)/files?per_page=100&page=\(page)") as? [[String: Any]] ?? []
            for item in list {
                guard let path = item["filename"] as? String else { continue }
                files.append(ReviewFile(
                    path: path, status: item["status"] as? String ?? "modified",
                    diff: DiffEngine.fromPatch(item["patch"] as? String, path: path,
                                               added: item["additions"] as? Int ?? 0,
                                               removed: item["deletions"] as? Int ?? 0)))
            }
            if list.count < 100 { break }
        }
        return (pull?["body"] as? String ?? "", files)
    }

    /// Sends a review. GitHub requires a body to request changes or comment.
    static func submit(_ event: ReviewEvent, body: String, on pr: ReviewPR) async throws {
        var payload: [String: Any] = ["event": event.rawValue]
        if !body.isEmpty { payload["body"] = body }
        _ = try await rest("https://api.github.com/repos/\(pr.repo)/pulls/\(pr.number)/reviews",
                           method: "POST", body: payload)
    }

    // MARK: HTTP

    private static func request(_ url: String, method: String, body: [String: Any]?) throws -> URLRequest {
        guard let token else { throw Failure(message: "Add a GitHub token in Settings → Integrations") }
        guard let u = URL(string: url) else { throw Failure(message: "Bad address") }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private static func rest(_ url: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Any? {
        let (data, response) = try await URLSession.shared.data(for: request(url, method: method, body: body))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(code) else { throw failure(code: code, json: json) }
        return json
    }

    private static func graphQL(_ query: String) async throws -> [String: Any] {
        let json = try await rest("https://api.github.com/graphql", method: "POST", body: ["query": query])
        return json as? [String: Any] ?? [:]
    }

    /// GitHub's own words ("Can not approve your own pull request"…), with what to change
    /// for the usual permission errors.
    private static func failure(code: Int, json: Any?) -> Failure {
        let dict = json as? [String: Any]
        var message = dict?["message"] as? String ?? "GitHub answered \(code)"
        if let details = (dict?["errors"] as? [Any])?.compactMap({ ($0 as? String) ?? ($0 as? [String: Any])?["message"] as? String }),
           !details.isEmpty {
            message = details.joined(separator: " ")
        }
        switch code {
        case 401: return Failure(message: "GitHub refused the token. Check it in Settings → Integrations.")
        case 403:
            return Failure(message: "\(message). The token needs Pull requests: read and write (or a classic token with repo).")
        default: return Failure(message: message)
        }
    }

    private static let inboxQuery = """
    query {
      viewer {
        login
        repositories(first: 50, isArchived: false, orderBy: {field: PUSHED_AT, direction: DESC},
                     affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
                     ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER]) {
          nodes {
            nameWithOwner
            pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title url isDraft updatedAt additions deletions changedFiles
                headRefName baseRefName reviewDecision
                author { login }
                viewerLatestReview { state }
                reviewRequests(first: 10) {
                  nodes { requestedReviewer { ... on User { login } } }
                }
              }
            }
          }
        }
      }
    }
    """
}

// MARK: - Inbox model

@MainActor
final class PullRequestInbox: ObservableObject {
    static let shared = PullRequestInbox()

    @Published private(set) var prs: [ReviewPR] = []
    @Published private(set) var login = ""
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var fetchedAt: Date?

    /// Loads when never loaded, or when the last load is older than `maxAge`.
    func refresh(maxAge: TimeInterval = 0) {
        guard !loading else { return }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < maxAge { return }
        guard GitHubReview.token != nil else {
            prs = []; login = ""; error = nil
            return
        }
        loading = true
        Task {
            do {
                let (login, prs) = try await GitHubReview.inbox()
                self.login = login
                self.prs = prs
                self.error = nil
                self.fetchedAt = Date()
            } catch {
                self.error = error.localizedDescription
            }
            self.loading = false
        }
    }
}
#endif
