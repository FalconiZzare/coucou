#if !APPSTORE
import Foundation

// MARK: - GitHubReview
//
// The pull requests page of the Coucou window: the pull requests of the GitHub token's account's
// inbox (merged or not, as GitHub's mobile app shows them) and the open ones of its
// repositories, their files, and the reviews it sends. To approve your own pull requests, put
// the token of another account of yours: GitHub never lets an account approve its own.

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
    /// "OPEN", "MERGED" or "CLOSED".
    var state = "OPEN"
    /// When it was merged or closed.
    var closedAt: Date? = nil
    /// Why it is in the account's GitHub inbox ("review_requested", also for a team the account
    /// is in, "mention", "author"…). Nil when it only comes from the account's repositories.
    var reason: String? = nil
    var unread = false
    /// Its thread in the GitHub inbox, to mark it read once opened here.
    var threadId: String? = nil
    /// The thread's last activity in the inbox.
    var threadUpdatedAt: Date? = nil

    /// The fields GitHub gives for the pull request itself, keeping what the inbox says of it.
    func refreshed(with fresh: ReviewPR) -> ReviewPR {
        var pr = fresh
        pr.reason = reason
        pr.unread = unread
        pr.threadId = threadId
        pr.threadUpdatedAt = threadUpdatedAt
        return pr
    }

    var id: String { "\(repo)#\(number)" }
    var isOpen: Bool { state == "OPEN" }
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
        var status = 0
        /// GitHub refused a write because the token may only read.
        var readOnly = false
        var errorDescription: String? { message }
    }

    static var token: String? { KeychainStore.shared.get("github-token") }

    // MARK: Inbox

    /// The account's login and its pull requests, most recently updated first:
    /// - the pull requests of its last 100 GitHub inbox threads, merged, closed or open, as
    ///   GitHub's mobile app lists them (team review requests come in this way);
    /// - the open ones of the 50 repositories it pushed to last (20 per repository).
    /// `note` says why part of it is missing (a fine-grained token has no inbox, an organisation
    /// wants the token authorised for its single sign-on).
    // lean-ctx: 100 threads and 50 repos × 20 PRs, upgrade to paging when someone needs more
    static func inbox() async throws -> (login: String, prs: [ReviewPR], note: String?) {
        // The repositories and the inbox go to GitHub at the same time: one after the other, a
        // refresh took about ten seconds.
        async let repoAnswer = graphQLData(inboxQuery)
        let fromInbox = await inboxPullRequests()
        let json = try JSONSerialization.jsonObject(with: await repoAnswer) as? [String: Any] ?? [:]
        guard let viewer = (json["data"] as? [String: Any])?["viewer"] as? [String: Any] else {
            throw Failure(message: errorMessages(json).first ?? "GitHub sent no data")
        }
        let login = viewer["login"] as? String ?? ""
        let note = fromInbox.failed ? fromInbox.note : ssoNote(json) ?? fromInbox.note
        var byId: [String: ReviewPR] = [:]
        let repos = ((viewer["repositories"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        for repo in repos {
            guard let name = repo["nameWithOwner"] as? String else { continue }
            let nodes = ((repo["pullRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            for node in nodes {
                if let pr = pullRequest(node, repo: name) { byId[pr.id] = pr }
            }
        }
        for pr in fromInbox.prs { byId[pr.id] = pr }

        let prs = byId.values.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        return (login, prs, note)
    }

    /// The pull requests of the inbox threads, and why part of them is missing (`failed`: none
    /// came, the note says why).
    private static func inboxPullRequests() async -> (prs: [ReviewPR], note: String?, failed: Bool) {
        do {
            let threads = try await inboxThreads()
            let (nodes, answers, timedOut) = try await pullRequests(threads.map { ($0.repo, $0.number) })
            var note = answers.lazy.compactMap(ssoNote).first
            if timedOut {
                note = note ?? "Part of your GitHub inbox didn't load: GitHub took too long. Refresh to try again."
            }
            var prs: [ReviewPR] = []
            for (thread, node) in zip(threads, nodes) {
                guard let node, var pr = pullRequest(node, repo: thread.repo) else { continue }
                pr.reason = thread.reason
                pr.unread = thread.unread
                pr.threadId = thread.id
                pr.threadUpdatedAt = thread.updatedAt
                prs.append(pr)
            }
            return (prs, note, false)
        } catch let failure as Failure where failure.status == 403 {
            return ([], "Your GitHub inbox needs a classic token (repo or notifications scope), so only the open pull requests of your repositories show.", true)
        } catch {
            return ([], "Couldn't read your GitHub inbox: \(error.localizedDescription)", true)
        }
    }

    /// A pull request thread of the account's GitHub inbox.
    private struct InboxThread {
        var id: String
        var repo: String
        var number: Int
        var reason: String
        var unread: Bool
        var updatedAt: Date?
    }

    /// The pull request threads of the account's last 100 inbox threads, read or not.
    private static func inboxThreads() async throws -> [InboxThread] {
        // Both pages at once (Data across the tasks: GitHub's JSON is not Sendable).
        func page(_ n: Int) async throws -> Data {
            let list = try await rest("https://api.github.com/notifications?all=true&per_page=50&page=\(n)")
            return try JSONSerialization.data(withJSONObject: list as? [[String: Any]] ?? [])
        }
        async let first = page(1)
        async let second = page(2)
        var threads: [InboxThread] = []
        var seen = Set<String>()
        for data in try await [first, second] {
            let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            for item in list {
                guard let id = item["id"] as? String,
                      let subject = item["subject"] as? [String: Any],
                      subject["type"] as? String == "PullRequest",
                      let number = (subject["url"] as? String).flatMap({ Int($0.split(separator: "/").last ?? "") }),
                      let repo = (item["repository"] as? [String: Any])?["full_name"] as? String,
                      seen.insert("\(repo)#\(number)").inserted else { continue }
                threads.append(InboxThread(id: id, repo: repo, number: number,
                                           reason: item["reason"] as? String ?? "",
                                           unread: item["unread"] as? Bool ?? false,
                                           updatedAt: date(item["updated_at"])))
            }
        }
        return threads
    }

    /// How many pull requests one query asks for. GitHub gives up on a query after about ten
    /// seconds and answers 502: 100 at once took that long, 20 take about two.
    private static let batchSize = 20

    /// Each pull request's fields, in the order asked (nil for one GitHub no longer shows the
    /// account), GitHub's answers, and whether a batch timed out twice and was left out. The
    /// batches go in parallel.
    private static func pullRequests(_ refs: [(repo: String, number: Int)]) async throws
        -> (nodes: [[String: Any]?], answers: [[String: Any]], timedOut: Bool) {
        // Owner and repository names are letters, digits, ".", "-" and "_": anything else is
        // left out rather than written into the query.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        func safe(_ s: Substring) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { allowed.contains($0) } }
        var fields: [String] = []
        for (i, ref) in refs.enumerated() {
            let parts = ref.repo.split(separator: "/")
            guard parts.count == 2, safe(parts[0]), safe(parts[1]) else { continue }
            fields.append("p\(i): repository(owner: \"\(parts[0])\", name: \"\(parts[1])\") { pullRequest(number: \(ref.number)) { ...pr } }")
        }
        let queries = stride(from: 0, to: fields.count, by: batchSize).map { start in
            "query {\n\(fields[start..<min(start + batchSize, fields.count)].joined(separator: "\n"))\n}\n" + prFragment
        }

        var answers: [[String: Any]] = []
        var timedOut = false
        // Data across the tasks: GitHub's JSON is not Sendable.
        try await withThrowingTaskGroup(of: Data?.self) { group in
            for query in queries {
                group.addTask {
                    // A 502 or 504 is GitHub giving up on a slow query: once more, then without it.
                    for attempt in 0..<2 {
                        do {
                            return try await graphQLData(query)
                        } catch let failure as Failure where failure.status == 502 || failure.status == 504 {
                            if attempt == 1 { return nil }
                        }
                    }
                    return nil
                }
            }
            for try await data in group {
                guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    timedOut = true
                    continue
                }
                answers.append(json)
            }
        }

        var data: [String: Any] = [:]
        for answer in answers {
            for (key, value) in answer["data"] as? [String: Any] ?? [:] { data[key] = value }
        }
        let nodes = refs.indices.map { i in
            (data["p\(i)"] as? [String: Any])?["pullRequest"] as? [String: Any]
        }
        return (nodes, answers, timedOut)
    }

    /// A pull request from GitHub's GraphQL fields (`prFragment`).
    private static func pullRequest(_ node: [String: Any], repo: String) -> ReviewPR? {
        guard let number = node["number"] as? Int, let title = node["title"] as? String,
              let url = node["url"] as? String else { return nil }
        let requests = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        return ReviewPR(
            repo: repo, number: number, title: title, url: url,
            author: (node["author"] as? [String: Any])?["login"] as? String ?? "ghost",
            isDraft: node["isDraft"] as? Bool ?? false,
            updatedAt: date(node["updatedAt"]),
            additions: node["additions"] as? Int ?? 0,
            deletions: node["deletions"] as? Int ?? 0,
            changedFiles: node["changedFiles"] as? Int ?? 0,
            headRef: node["headRefName"] as? String ?? "",
            baseRef: node["baseRefName"] as? String ?? "",
            review: ReviewState(rawGitHub: node["reviewDecision"] as? String),
            viewerReview: (node["viewerLatestReview"] as? [String: Any])?["state"] as? String,
            requestedReviewers: requests.compactMap {
                ($0["requestedReviewer"] as? [String: Any])?["login"] as? String
            },
            state: node["state"] as? String ?? "OPEN",
            closedAt: date(node["closedAt"]))
    }

    /// GitHub's dates ("2026-10-24T09:41:00Z").
    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    private static func errorMessages(_ json: [String: Any]) -> [String] {
        ((json["errors"] as? [[String: Any]]) ?? []).compactMap { $0["message"] as? String }
    }

    /// An organisation that hides its repositories until the token is authorised for its SSO.
    private static func ssoNote(_ json: [String: Any]) -> String? {
        errorMessages(json).contains { $0.localizedCaseInsensitiveContains("SAML") }
            ? "An organisation needs this token authorised for its single sign-on: GitHub → Settings → Developer settings → Personal access tokens → Configure SSO."
            : nil
    }

    // MARK: One pull request

    /// The pull request as GitHub has it now (nil if it no longer shows it), its description,
    /// and its files, up to 300 (GitHub lists 100 per page).
    static func details(of pr: ReviewPR) async throws -> (pr: ReviewPR?, body: String, files: [ReviewFile]) {
        async let fresh = current(pr)
        let files = try await files(of: pr)
        let (now, body) = try await fresh
        return (now, body, files)
    }

    /// Where the pull request stands now: after a review, GitHub may also have merged it.
    static func current(_ pr: ReviewPR) async throws -> (pr: ReviewPR?, body: String) {
        let parts = pr.repo.split(separator: "/")
        guard parts.count == 2 else { throw Failure(message: "Bad repository \(pr.repo)") }
        let json = try await graphQL(pullRequestQuery, variables: [
            "owner": String(parts[0]), "name": String(parts[1]), "number": pr.number])
        guard let repository = (json["data"] as? [String: Any])?["repository"] as? [String: Any] else {
            throw Failure(message: errorMessages(json).first ?? "GitHub sent no data")
        }
        let node = repository["pullRequest"] as? [String: Any]
        return (node.flatMap { pullRequest($0, repo: pr.repo) }.map(pr.refreshed),
                node?["body"] as? String ?? "")
    }

    private static func files(of pr: ReviewPR) async throws -> [ReviewFile] {
        let base = "https://api.github.com/repos/\(pr.repo)/pulls/\(pr.number)"
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
        return files
    }

    /// Sends a review. GitHub requires a body to request changes or comment.
    static func submit(_ event: ReviewEvent, body: String, on pr: ReviewPR) async throws {
        var payload: [String: Any] = ["event": event.rawValue]
        if !body.isEmpty { payload["body"] = body }
        do {
            _ = try await rest("https://api.github.com/repos/\(pr.repo)/pulls/\(pr.number)/reviews",
                               method: "POST", body: payload)
            await GitHubTokenAccess.shared.noteWriteAccepted()
        } catch let failure as Failure where failure.readOnly {
            await GitHubTokenAccess.shared.noteWriteRefused()
            throw failure
        }
    }

    /// Marks an inbox thread read, as opening it in GitHub's mobile app does.
    static func markRead(threadId: String) async throws {
        guard threadId.allSatisfy(\.isNumber) else { return }
        _ = try await rest("https://api.github.com/notifications/threads/\(threadId)", method: "PATCH")
    }

    // MARK: HTTP

    private static func request(_ url: String, method: String, body: [String: Any]?) throws -> URLRequest {
        guard let token else { throw Failure(message: "Add a GitHub token in Settings → Integrations") }
        guard let u = URL(string: url) else { throw Failure(message: "Bad address") }
        // GitHub lets its answers be kept a minute: a list fetched again right after a review or
        // a read came back as it was before.
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
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
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let scopes = http?.value(forHTTPHeaderField: "X-OAuth-Scopes")
        await GitHubTokenAccess.shared.noteScopes(scopes)
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(code) else { throw failure(code: code, json: json) }
        return json
    }

    private static func graphQL(_ query: String, variables: [String: Any] = [:]) async throws -> [String: Any] {
        var body: [String: Any] = ["query": query]
        if !variables.isEmpty { body["variables"] = variables }
        let json = try await rest("https://api.github.com/graphql", method: "POST", body: body)
        return json as? [String: Any] ?? [:]
    }

    /// GitHub's answer as Data, to cross tasks (its JSON is not Sendable).
    private static func graphQLData(_ query: String) async throws -> Data {
        try JSONSerialization.data(withJSONObject: try await graphQL(query))
    }

    /// GitHub's own words ("Can not approve your own pull request"…), with what to change
    /// for the usual permission errors.
    private static func failure(code: Int, json: Any?) -> Failure {
        let dict = json as? [String: Any]
        let raw = dict?["message"] as? String ?? ""
        if GitHubTokenAccess.isReadOnlyRefusal(status: code, message: raw) {
            return Failure(message: GitHubTokenAccess.readOnlyMessage, status: code, readOnly: true)
        }
        var message = raw.isEmpty ? "GitHub answered \(code)" : raw
        if let details = (dict?["errors"] as? [Any])?.compactMap({ ($0 as? String) ?? ($0 as? [String: Any])?["message"] as? String }),
           !details.isEmpty {
            message = details.joined(separator: " ")
        }
        if code == 401 { message = "GitHub refused the token. Check it in Settings → Integrations." }
        return Failure(message: message, status: code)
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
              nodes { ...pr }
            }
          }
        }
      }
    }
    """ + prFragment

    private static let pullRequestQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { ...pr body }
      }
    }
    """ + prFragment

    /// The fields of a pull request the page shows.
    private static let prFragment = """
    fragment pr on PullRequest {
      number title url isDraft updatedAt additions deletions changedFiles state
      headRefName baseRefName reviewDecision closedAt
      author { login }
      viewerLatestReview { state }
      reviewRequests(first: 10) {
        nodes { requestedReviewer { ... on User { login } } }
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
    /// Why part of the list is missing, when GitHub gave only part of it.
    @Published private(set) var note: String?
    private var fetchedAt: Date?
    /// Inbox threads read here, and when. A refresh already on its way brings them back unread,
    /// and so does the merge that follows an approval (auto-merge): both stay read.
    private var readAt: [String: Date] = [:]
    /// Pull requests fetched one by one, and when: a whole refresh that left before keeps them.
    private var currentAt: [String: Date] = [:]

    /// Opened in the page: no longer unread, here and in the GitHub inbox, and the GitHub card's
    /// counter goes down.
    func markRead(_ pr: ReviewPR) {
        guard let thread = pr.threadId else { return }
        readAt[thread] = Date()
        guard pr.unread, let index = prs.firstIndex(where: { $0.id == pr.id }) else { return }
        prs[index].unread = false
        Task {
            try? await GitHubReview.markRead(threadId: thread)
            GithubPoller.shared.refreshUnreadPRs()
        }
    }

    /// One pull request as GitHub has it now (opened in the page, or just reviewed).
    func update(_ fresh: ReviewPR) {
        guard let index = prs.firstIndex(where: { $0.id == fresh.id }) else { return }
        currentAt[fresh.id] = Date()
        let pr = prs[index].refreshed(with: fresh)
        if prs[index] != pr { prs[index] = pr }
    }

    /// A review GitHub accepted: it shows at once, then as GitHub has it, and again a few seconds
    /// later for a merge the approval starts (auto-merge). Reviewing it is reading it.
    func reviewed(_ pr: ReviewPR, _ event: ReviewEvent) {
        markRead(pr)
        if event != .comment, let index = prs.firstIndex(where: { $0.id == pr.id }) {
            prs[index].viewerReview = event == .approve ? "APPROVED" : "CHANGES_REQUESTED"
            currentAt[pr.id] = Date()
        }
        Task {
            for delay in [0, 5, 20] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                if let fresh = try? await GitHubReview.current(pr).pr { update(fresh) }
            }
        }
    }

    /// A whole refresh's pull requests, sent at `startedAt`, with what happened here since.
    private func apply(_ fetched: [ReviewPR], startedAt: Date) {
        let known = Dictionary(prs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var readAgain: [String] = []
        prs = fetched.map { fetchedPR in
            var pr = fetchedPR
            if let at = currentAt[pr.id], at > startedAt, let newer = known[pr.id] {
                pr = pr.refreshed(with: newer)
            }
            guard pr.unread, let thread = pr.threadId, let read = readAt[thread] else { return pr }
            let activity = pr.threadUpdatedAt ?? .distantFuture
            if activity <= read {
                pr.unread = false   // GitHub's answer is older than the read
            } else if let closed = pr.closedAt, closed > read, abs(activity.timeIntervalSince(closed)) < 120 {
                pr.unread = false   // nothing new since but the merge (or the close)
                readAgain.append(thread)
            } else {
                readAt[thread] = nil   // something new: unread, as GitHub says
            }
            return pr
        }
        guard !readAgain.isEmpty else { return }
        Task {
            for thread in readAgain { try? await GitHubReview.markRead(threadId: thread) }
            GithubPoller.shared.refreshUnreadPRs()
        }
    }

    /// Loads when never loaded, or when the last load is older than `maxAge`.
    func refresh(maxAge: TimeInterval = 0) {
        guard !loading else { return }
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < maxAge { return }
        guard GitHubReview.token != nil else {
            prs = []; login = ""; error = nil
            return
        }
        loading = true
        let startedAt = Date()
        Task {
            do {
                let (login, prs, note) = try await GitHubReview.inbox()
                self.login = login
                apply(prs, startedAt: startedAt)
                self.note = note
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
