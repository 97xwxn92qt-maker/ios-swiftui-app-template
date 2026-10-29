
import SwiftUI

// MARK: - 游戏模型

struct SteamGame: Identifiable, Hashable {
    let id: String
    let name: String

    var url: URL {
        URL(string: "https://store.steampowered.com/app/\(id)/")!
    }

    var capsuleURL: URL {
        URL(
            string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/capsule_184x69.jpg"
        )!
    }
}

struct SteamGameDetails {
    var headerImage: URL?
    var description: String = ""
    var screenshots: [URL] = []
    var developers: [String] = []
    var genres: [String] = []
}

struct SteamReviewSummary {
    var description: String = "暂无评价数据"
    var positive: Int = 0
    var negative: Int = 0
    var total: Int = 0

    var positivePercentage: Int {
        guard total > 0 else { return 0 }
        return Int((Double(positive) / Double(total) * 100).rounded())
    }
}

// MARK: - Steam 数据接口

enum SteamAPI {
    static func fetchJSON(from url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONSerialization.jsonObject(with: data)
    }

    static func extractAppID(from logo: String) -> String? {
        let pattern = #"/apps/(\d+)/"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern
        ) else {
            return nil
        }

        let range = NSRange(
            logo.startIndex..<logo.endIndex,
            in: logo
        )

        guard let match = regex.firstMatch(
            in: logo,
            range: range
        ),
        let idRange = Range(match.range(at: 1), in: logo) else {
            return nil
        }

        return String(logo[idRange])
    }

    static func cleanHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
    }

    static func isPermanentFree(_ appID: String) async -> Bool {
        guard let url = URL(
            string: "https://store.steampowered.com/api/appdetails/?appids=\(appID)&cc=sg&l=schinese"
        ) else {
            return false
        }

        do {
            let json = try await fetchJSON(from: url)

            guard let root = json as? [String: Any],
                  let app = root[appID] as? [String: Any],
                  app["success"] as? Bool == true,
                  let details = app["data"] as? [String: Any],
                  let groups = details["package_groups"] as? [[String: Any]]
            else {
                return false
            }

            for group in groups {
                guard let subs = group["subs"] as? [[String: Any]]
                else {
                    continue
                }

                for sub in subs {
                    let option = (
                        sub["option_text"] as? String ?? ""
                    ).lowercased()

                    let price = sub[
                        "price_in_cents_with_discount"
                    ] as? Int

                    if option.contains(
                        "limited free promotional package"
                    ), price == 0 {
                        return true
                    }
                }
            }
        } catch {
            return false
        }

        return false
    }

    static func fetchDetails(
        appID: String
    ) async throws -> SteamGameDetails {
        let url = URL(
            string: "https://store.steampowered.com/api/appdetails/?appids=\(appID)&cc=sg&l=schinese"
        )!

        let json = try await fetchJSON(from: url)

        guard let root = json as? [String: Any],
              let app = root[appID] as? [String: Any],
              app["success"] as? Bool == true,
              let data = app["data"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        var result = SteamGameDetails()

        if let header = data["header_image"] as? String {
            result.headerImage = URL(string: header)
        }

        if let description = data["short_description"] as? String {
            result.description = cleanHTML(description)
        }

        if let screenshots = data["screenshots"] as? [[String: Any]] {
            result.screenshots = screenshots.compactMap {
                guard let path = $0["path_full"] as? String else {
                    return nil
                }
                return URL(string: path)
            }
        }

        result.developers = data["developers"] as? [String] ?? []

        if let genres = data["genres"] as? [[String: Any]] {
            result.genres = genres.compactMap {
                $0["description"] as? String
            }
        }

        return result
    }

    static func fetchReviews(
        appID: String
    ) async throws -> SteamReviewSummary {
        var components = URLComponents(
            string: "https://store.steampowered.com/appreviews/\(appID)"
        )!

        components.queryItems = [
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "language", value: "all"),
            URLQueryItem(name: "purchase_type", value: "all"),
            URLQueryItem(name: "num_per_page", value: "0")
        ]

        let json = try await fetchJSON(from: components.url!)

        guard let root = json as? [String: Any],
              let summary = root["query_summary"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }

        return SteamReviewSummary(
            description: summary["review_score_desc"] as? String
                ?? "暂无评价数据",
            positive: summary["total_positive"] as? Int ?? 0,
            negative: summary["total_negative"] as? Int ?? 0,
            total: summary["total_reviews"] as? Int ?? 0
        )
    }
}

// MARK: - 游戏列表数据管理

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var message = "点击按钮查询当前永久限免游戏"

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        message = "正在查询 Steam……"

        defer {
            isLoading = false
        }

        do {
            let url = URL(
                string: "https://store.steampowered.com/search/results/?specials=1&maxprice=free&json=1&count=50&cc=sg&l=schinese"
            )!

            let json = try await SteamAPI.fetchJSON(from: url)

            guard let root = json as? [String: Any],
                  let items = root["items"] as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }

            var candidates: [SteamGame] = []
            var seen = Set<String>()

            for item in items {
                guard let name = item["name"] as? String,
                      let logo = item["logo"] as? String,
                      let appID = SteamAPI.extractAppID(from: logo),
                      seen.insert(appID).inserted else {
                    continue
                }

                candidates.append(
                    SteamGame(
                        id: appID,
                        name: SteamAPI.cleanHTML(name)
                    )
                )
            }

            var results: [SteamGame] = []

            for candidate in candidates {
                guard !Task.isCancelled else { return }

                if await SteamAPI.isPermanentFree(candidate.id) {
                    results.append(candidate)
                }
            }

            games = results

            message = results.isEmpty
                ? "暂时没有检测到符合条件的永久限免游戏"
                : "查询完成，共找到 \(results.count) 款游戏"

        } catch {
            message = "查询失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 主页面

struct ContentView: View {
    @StateObject private var store = SteamStore()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(
                        alignment: .leading,
                        spacing: 12
                    ) {
                        Text("永久限免助手")
                            .font(.largeTitle.bold())

                        Text("发现 Steam 免费入库游戏")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button {
                            Task {
                                await store.refresh()
                            }
                        } label: {
                            HStack {
                                if store.isLoading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }

                                Text(
                                    store.isLoading
                                    ? "正在查询……"
                                    : "刷新限免列表"
                                )
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLoading)

                        Text(store.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section("永久限免游戏") {
                    if store.games.isEmpty {
                        Text(
                            store.isLoading
                            ? "正在检查 Steam 商店……"
                            : "点击上方按钮开始查询"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.games) { game in
                            NavigationLink(value: game) {
                                HStack(spacing: 12) {
                                    AsyncImage(url: game.capsuleURL) { phase in
                                        if let image = phase.image {
                                            image
                                                .resizable()
                                                .aspectRatio(
                                                    contentMode: .fill
                                                )
                                        } else if phase.error != nil {
                                            Image(
                                                systemName: "gamecontroller.fill"
                                            )
                                            .font(.title2)
                                            .foregroundStyle(.secondary)
                                            .frame(
                                                maxWidth: .infinity,
                                                maxHeight: .infinity
                                            )
                                            .background(.quaternary)
                                        } else {
                                            ProgressView()
                                        }
                                    }
                                    .frame(width: 110, height: 52)
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: 8)
                                    )

                                    VStack(
                                        alignment: .leading,
                                        spacing: 5
                                    ) {
                                        Text(game.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)

                                        Text("永久入库优惠")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }
                }

                Section {
                    Text(
                        "点击游戏查看详情、截图和 Steam 玩家评价。领取需要前往 Steam 商店确认。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Steam 限免")
            .navigationDestination(for: SteamGame.self) { game in
                SteamGameDetailView(game: game)
            }
        }
    }
}

// MARK: - 游戏详情页面

struct SteamGameDetailView: View {
    let game: SteamGame

    @State private var details: SteamGameDetails?
    @State private var reviews: SteamReviewSummary?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let details {
                    if let header = details.headerImage {
                        AsyncImage(url: header) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .aspectRatio(
                                        contentMode: .fit
                                    )
                            } else {
                                Rectangle()
                                    .fill(.quaternary)
                                    .aspectRatio(460.0 / 215.0, contentMode: .fit)
                                    .overlay {
                                        ProgressView()
                                    }
                            }
                        }
                        .clipShape(
                            RoundedRectangle(cornerRadius: 12)
                        )
                    }

                    Text(game.name)
                        .font(.title.bold())

                    Label(
                        "永久入库限免",
                        systemImage: "gift.fill"
                    )
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)

                    // 评价信息

                    GroupBox("Steam 玩家评价") {
                        if let reviews {
                            VStack(
                                alignment: .leading,
                                spacing: 10
                            ) {
                                Text(reviews.description)
                                    .font(.title3.bold())

                                if reviews.total > 0 {
                                    Text(
                                        "\(reviews.positivePercentage)% 好评"
                                    )
                                    .font(.headline)
                                    .foregroundStyle(
                                        reviews.positivePercentage >= 70
                                        ? .green
                                        : .orange
                                    )

                                    HStack {
                                        Text("好评 \(reviews.positive)")
                                        Spacer()
                                        Text("差评 \(reviews.negative)")
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                    Text(
                                        "共 \(reviews.total) 条评价"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("目前没有可显示的玩家评价")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Link(
                                    "查看 Steam 完整评价",
                                    destination: URL(
                                        string: "https://store.steampowered.com/app/\(game.id)/#app_reviews_hash"
                                    )!
                                )
                                .font(.subheadline)
                            }
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                        } else {
                            ProgressView("正在加载评价……")
                                .frame(maxWidth: .infinity)
                        }
                    }

                    // 游戏介绍

                    if !details.description.isEmpty {
                        VStack(
                            alignment: .leading,
                            spacing: 8
                        ) {
                            Text("游戏简介")
                                .font(.title3.bold())

                            Text(details.description)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !details.developers.isEmpty {
                        VStack(
                            alignment: .leading,
                            spacing: 6
                        ) {
                            Text("开发商")
                                .font(.headline)

                            Text(details.developers.joined(separator: "、"))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !details.genres.isEmpty {
                        VStack(
                            alignment: .leading,
                            spacing: 6
                        ) {
                            Text("游戏类型")
                                .font(.headline)

                            Text(details.genres.joined(separator: "、"))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 游戏截图

                    if !details.screenshots.isEmpty {
                        VStack(
                            alignment: .leading,
                            spacing: 10
                        ) {
                            Text("游戏截图")
                                .font(.title3.bold())

                            ScrollView(.horizontal) {
                                HStack(spacing: 12) {
                                    ForEach(
                                        Array(
                                            details.screenshots.enumerated()
                                        ),
                                        id: \.offset
                                    ) { _, screenshot in
                                        AsyncImage(url: screenshot) { phase in
                                            if let image = phase.image {
                                                image
                                                    .resizable()
                                                    .aspectRatio(
                                                        contentMode: .fit
                                                    )
                                            } else {
                                                Rectangle()
                                                    .fill(.quaternary)
                                                    .overlay {
                                                        ProgressView()
                                                    }
                                            }
                                        }
                                        .frame(width: 280, height: 158)
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: 10)
                                        )
                                    }
                                }
                            }
                            .scrollIndicators(.hidden)
                        }
                    }

                    // 确认领取按钮

                    Link(destination: game.url) {
                        Label(
                            "确认领取",
                            systemImage: "arrow.up.right.square.fill"
                        )
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)

                    Text(
                        "点击后将打开 Steam 商店。请在 Steam 页面登录账号并确认领取；本应用不会自动操作你的账号。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                } else if isLoading {
                    ProgressView("正在加载游戏详情……")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)

                } else {
                    Text(
                        errorMessage ?? "暂时无法加载游戏详情"
                    )
                    .foregroundStyle(.secondary)

                    Button("重新加载") {
                        Task {
                            await loadDetails()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .navigationTitle("游戏详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if details == nil && isLoading {
                await loadDetails()
            }
        }
    }

    @MainActor
    private func loadDetails() async {
        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            async let detailRequest = SteamAPI.fetchDetails(
                appID: game.id
            )

            async let reviewRequest = SteamAPI.fetchReviews(
                appID: game.id
            )

            let (loadedDetails, loadedReviews) = try await (
                detailRequest,
                reviewRequest
            )

            details = loadedDetails
            reviews = loadedReviews

        } catch {
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }
}
