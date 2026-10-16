#if !APPSTORE
import AppKit
import SwiftUI

/// Coucou window → Pull requests: the open pull requests the reviewing account can see on the
/// left, the one chosen on the right with its files and the review buttons.
struct HubPullRequestsPage: View {
    @ObservedObject var router: HubRouter
    @ObservedObject private var inbox = PullRequestInbox.shared
    @State private var selected: String?
    @State private var filter: PRFilter = .all
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HubHero(page: .pullRequests, title: HubPage.pullRequests.title, subtitle: subtitle, compact: true) {
                HubIconButton(symbol: "arrow.clockwise", help: "Refresh") { inbox.refresh() }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            if GitHubReview.token == nil {
                HubCard {
                    Text("Add a GitHub token to review pull requests here.")
                        .font(.system(size: 13.5, weight: .medium))
                    Text("Settings → Integrations → GitHub. A second account's token, in Review account, lets you approve your own pull requests.")
                        .font(.system(size: 12))
                        .foregroundColor(HubTheme.secondary)
                    Button("Open Integrations") { router.page = .integrations }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
                .padding(28)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 0) {
                    list
                        .frame(width: 320)
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
                    Group {
                        if let pr = shown {
                            HubPullRequestDetail(pr: pr, reviewer: inbox.login)
                                .id(pr.id)
                        } else {
                            Text(inbox.loading ? "Loading pull requests…" : "No pull request open")
                                .font(.system(size: 13))
                                .foregroundColor(HubTheme.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .onAppear { inbox.refresh(maxAge: 60) }
    }

    private var subtitle: String {
        guard !inbox.login.isEmpty else { return "Every open pull request you can see, its diff, and your review." }
        return GitHubReview.usesReviewAccount
            ? "Reviewing as \(inbox.login), your review account."
            : "Reviewing as \(inbox.login)."
    }

    /// Your own login: the main token's account, which differs from the reviewer's once a
    /// review account is set.
    private var mainLogin: String { AppState.shared.githubPulse?.login ?? inbox.login }

    private var filtered: [ReviewPR] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return inbox.prs.filter { pr in
            switch filter {
            case .all: break
            case .requested: guard pr.requestedReviewers.contains(inbox.login) else { return false }
            case .yours: guard pr.author == mainLogin else { return false }
            }
            guard !query.isEmpty else { return true }
            return pr.title.lowercased().contains(query) || pr.id.lowercased().contains(query)
                || pr.author.lowercased().contains(query)
        }
    }

    private var shown: ReviewPR? {
        let list = filtered
        return list.first { $0.id == selected } ?? list.first
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubField(placeholder: "Search title, repository, author", text: $search)
                .padding(.top, 16)
            HStack(spacing: 6) {
                ForEach(PRFilter.allCases) { f in
                    HubFilterChip(title: f.title, selected: filter == f) { filter = f }
                }
            }
            if let error = inbox.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered) { pr in
                        HubPullRequestRow(pr: pr, selected: pr.id == shown?.id) { selected = pr.id }
                    }
                    if filtered.isEmpty && !inbox.loading {
                        Text(inbox.prs.isEmpty ? "No pull request open" : "Nothing matches")
                            .font(.system(size: 12))
                            .foregroundColor(HubTheme.secondary)
                            .padding(.top, 8)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

private enum PRFilter: String, CaseIterable, Identifiable {
    case all, requested, yours
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:       return "All"
        case .requested: return "Review requested"
        case .yours:     return "Yours"
        }
    }
}

private struct HubFilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? HubTheme.text : HubTheme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.1 : 0.04)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct HubPullRequestRow: View {
    let pr: ReviewPR
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(pr.title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? HubTheme.text : Color(hex: "#D5D7DB"))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text("\(pr.id) · \(pr.author)")
                        .font(.system(size: 11.5))
                        .foregroundColor(HubTheme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    HubReviewBadge(pr: pr)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(selected ? 0.07 : (hover ? 0.035 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// "Draft", "Approved", "Changes requested": where the pull request stands.
private struct HubReviewBadge: View {
    let pr: ReviewPR

    var body: some View {
        if let badge {
            Text(badge.text)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(badge.color)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule().fill(badge.color.opacity(0.14)))
        }
    }

    private var badge: (text: String, color: Color)? {
        if pr.isDraft { return ("Draft", HubTheme.muted) }
        switch pr.review {
        case .approved:         return ("Approved", HubTheme.green)
        case .changesRequested: return ("Changes requested", HubTheme.red)
        case .pending:          return ("Review required", HubTheme.accent)
        case .unknown:          return nil
        }
    }
}

// MARK: - Detail

private struct HubPullRequestDetail: View {
    let pr: ReviewPR
    /// The reviewing account: GitHub refuses its approval on its own pull requests.
    let reviewer: String

    @State private var prBody = ""
    @State private var files: [ReviewFile] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var comment = ""
    @State private var sending: ReviewEvent?
    @State private var result: (text: String, ok: Bool)?

    private var isOwn: Bool { !reviewer.isEmpty && pr.author == reviewer }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                composer
                if loading {
                    Text("Loading files…").font(.system(size: 12)).foregroundColor(HubTheme.secondary)
                } else if let loadError {
                    Text(loadError).font(.system(size: 12)).foregroundColor(HubTheme.accent)
                } else {
                    HubLabel("\(files.count) files changed")
                    ForEach(files) { file in
                        HubReviewFileCard(file: file, filesURL: pr.url + "/files",
                                          startsOpen: files.count <= 30)
                    }
                    if pr.changedFiles > files.count {
                        Text("\(pr.changedFiles - files.count) more files on GitHub")
                            .font(.system(size: 12))
                            .foregroundColor(HubTheme.secondary)
                    }
                }
            }
            .padding(24)
        }
        .scrollIndicators(.automatic)
        .task(id: pr.id) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text(pr.title)
                    .font(.system(size: 20, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Open on GitHub") { openOnGitHub(pr.url) }
                    .buttonStyle(HubButtonStyle())
            }
            HStack(spacing: 8) {
                Text("\(pr.id) · \(pr.author) · \(pr.headRef) → \(pr.baseRef)")
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("+\(pr.additions)").font(.system(size: 12, weight: .medium).monospaced()).foregroundColor(HubDiffColors.added)
                Text("−\(pr.deletions)").font(.system(size: 12, weight: .medium).monospaced()).foregroundColor(HubDiffColors.removed)
                HubReviewBadge(pr: pr)
            }
            if !prBody.isEmpty {
                Text(prBody)
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var composer: some View {
        HubCard(padding: 14) {
            TextEditor(text: $comment)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 56, maxHeight: 120)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubTheme.field))
                .overlay(alignment: .topLeading) {
                    if comment.isEmpty {
                        Text("Leave a comment (needed to request changes)")
                            .font(.system(size: 13))
                            .foregroundColor(HubTheme.muted)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 8) {
                Button(sending == .approve ? "Approving…" : "Approve") { send(.approve) }
                    .buttonStyle(HubButtonStyle(primary: true))
                    .disabled(sending != nil || isOwn)
                Button("Request changes") { send(.requestChanges) }
                    .buttonStyle(HubButtonStyle())
                    .disabled(sending != nil || isOwn || trimmed.isEmpty)
                Button("Comment") { send(.comment) }
                    .buttonStyle(HubButtonStyle())
                    .disabled(sending != nil || trimmed.isEmpty)
                Spacer(minLength: 0)
                if let result {
                    Text(result.text)
                        .font(.system(size: 12))
                        .foregroundColor(result.ok ? HubTheme.green : HubTheme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isOwn {
                Text("\(reviewer) opened this pull request, and GitHub doesn't let an account approve its own. Add another account's token in Settings → Integrations → Review account.")
                    .font(.system(size: 11.5))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let review = pr.viewerReview {
                Text("Your last review: \(review.replacingOccurrences(of: "_", with: " ").lowercased())")
                    .font(.system(size: 11.5))
                    .foregroundColor(HubTheme.secondary)
            }
        }
    }

    private var trimmed: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func load() async {
        loading = true
        loadError = nil
        do {
            let (text, list) = try await GitHubReview.details(of: pr)
            prBody = text
            files = list
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    /// Sent only from a click on one of the three buttons.
    private func send(_ event: ReviewEvent) {
        sending = event
        result = nil
        let text = trimmed
        Task {
            do {
                try await GitHubReview.submit(event, body: text, on: pr)
                switch event {
                case .approve:        result = ("Approved", true)
                case .requestChanges: result = ("Changes requested", true)
                case .comment:        result = ("Comment sent", true)
                }
                comment = ""
                PullRequestInbox.shared.refresh()
            } catch {
                result = (error.localizedDescription, false)
            }
            sending = nil
        }
    }
}

private func openOnGitHub(_ string: String) {
    if let url = safeWebURL(string), url.host == "github.com" { NSWorkspace.shared.open(url) }
}

/// The notch's diff colours, for the window.
private enum HubDiffColors {
    static let added = Color(hex: "#22C55E")
    static let removed = Color(hex: "#F4505E")
}

/// One file of the pull request: its name and counts, and its diff, cut after `maxLines`.
private struct HubReviewFileCard: View {
    let file: ReviewFile
    let filesURL: String
    @State private var open: Bool

    private static let maxLines = 400

    init(file: ReviewFile, filesURL: String, startsOpen: Bool) {
        self.file = file
        self.filesURL = filesURL
        _open = State(initialValue: startsOpen)
    }

    private var lines: [DiffLine] { file.diff.hunks.flatMap(\.lines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(HubTheme.muted)
                        .frame(width: 12)
                    Text(file.path)
                        .font(.system(size: 12.5, weight: .medium).monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                    if file.status != "modified" {
                        Text(file.status)
                            .font(.system(size: 10.5))
                            .foregroundColor(HubTheme.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("+\(file.diff.added)").font(.system(size: 11.5).monospaced()).foregroundColor(HubDiffColors.added)
                    Text("−\(file.diff.removed)").font(.system(size: 11.5).monospaced()).foregroundColor(HubDiffColors.removed)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                HubDivider()
                if file.diff.tooLarge {
                    notice("This file is binary or too large to show here.")
                } else {
                    let all = lines
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(all.prefix(Self.maxLines).enumerated()), id: \.offset) { index, line in
                            if index > 0, startsHunk(at: index, in: all) {
                                Text("⋯")
                                    .font(.system(size: 11).monospaced())
                                    .foregroundColor(HubTheme.muted)
                                    .padding(.leading, 12)
                                    .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                                    .background(Color.white.opacity(0.03))
                            }
                            HubReviewDiffRow(line: line)
                        }
                    }
                    .padding(.vertical, 4)
                    if all.count > Self.maxLines {
                        notice("\(all.count - Self.maxLines) more lines.")
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HubTheme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// A line that doesn't follow the one before it in the old or new file starts a new hunk.
    private func startsHunk(at index: Int, in all: [DiffLine]) -> Bool {
        let prev = all[index - 1], line = all[index]
        if line.newLine > 0, prev.newLine > 0 { return line.newLine != prev.newLine + 1 }
        if line.origLine > 0, prev.origLine > 0 { return line.origLine != prev.origLine + 1 }
        return false
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 12)).foregroundColor(HubTheme.secondary)
            Button("Open on GitHub") { openOnGitHub(filesURL) }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(HubTheme.accent)
        }
        .padding(12)
    }
}

private struct HubReviewDiffRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            number(line.origLine)
            number(line.newLine)
            Text(symbol)
                .foregroundColor(symbolColor)
                .frame(width: 16, alignment: .center)
            Text(line.text)
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12).monospaced())
        .padding(.trailing, 10)
        .background(background)
        .textSelection(.enabled)
    }

    private func number(_ n: Int) -> some View {
        Text(n > 0 ? "\(n)" : "")
            .foregroundColor(HubTheme.muted)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var symbol: String {
        switch line.kind {
        case .added:   return "+"
        case .removed: return "−"
        case .context: return ""
        }
    }
    private var symbolColor: Color {
        switch line.kind {
        case .added:   return HubDiffColors.added
        case .removed: return HubDiffColors.removed
        case .context: return HubTheme.muted
        }
    }
    private var textColor: Color {
        switch line.kind {
        case .added:   return Color(hex: "#86EFAC")
        case .removed: return Color(hex: "#FCA5A5")
        case .context: return Color(hex: "#A4A9B1")
        }
    }
    private var background: Color {
        switch line.kind {
        case .added:   return HubDiffColors.added.opacity(0.12)
        case .removed: return HubDiffColors.removed.opacity(0.12)
        case .context: return .clear
        }
    }
}
#endif
