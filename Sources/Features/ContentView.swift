
import SwiftUI
import Combine
import Foundation

// MARK: - Steam 风格

private enum SteamStyle {
    static let background = Color(red: 0.055, green: 0.075, blue: 0.12)
    static let card = Color(red: 0.085, green: 0.115, blue: 0.17)
    static let cardLight = Color(red: 0.12, green: 0.16, blue: 0.23)
    static let blue = Color(red: 0.25, green: 0.65, blue: 0.96)
    static let cyan = Color(red: 0.35, green: 0.83, blue: 0.91)
    static let green = Color(red: 0.35, green: 0.83, blue: 0.55)
    static let secondary = Color.white.opacity(0.62)
    static let border = Color.white.opacity(0.08)
}

// MARK: - 游戏类型

enum SteamAppKind: String {
    case game = "游戏本体"
    case dlc = "DLC 内容"
    case other = "其他内容"
}

// MARK: - 游戏模型

struct SteamGame: Identifiable, Hashable {
    let id: Int
    var name: String
    var imageURL: String
    var originalPrice: String
    var kind: SteamAppKind

    var storeURL: URL {
        URL(string: "https://store.steampowered.com/app/\(id)/")!
    }

    var isDLC: Bool {
        kind == .dlc
    }

    static func == (lhs: SteamGame, rhs: SteamGame) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct SteamGameDetails {
    var name: String
    var description: String
    var developers: [String]
    var publishers: [String]
    var headerImage: String
    var screenshots: [String]
    var originalPrice: String
    var isFree: Bool
}

struct SteamReviewSummary {
    var totalReviews: Int
    var positiveReviews: Int
    var negativeReviews: Int

    var positivePercent: Int {
        guard totalReviews > 0 else { return 0 }
        return Int(
            (Double(positiveReviews) / Double(totalReviews) * 100).rounded()
        )
    }

    var totalText: String {
        totalReviews.formatted(
            .number.locale(Locale(identifier: "zh_CN"))
        )
    }
}

// MARK: - Steam API

enum SteamAPI {
    private static let countryCode = "sg"
    private static let language = "schinese"

    private static func makeRequest(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        request.setValue(
            "application/json, text/javascript, */*; q=0.01",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "https://store.steampowered.com/",
            forHTTPHeaderField: "Referer"
        )
        request.setValue(
            "Mozilla/5.0",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "SteamAPI",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "无法获取服务器响应"
                ]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(
                domain: "SteamAPI",
                code: httpResponse.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Steam 服务器返回 HTTP \(httpResponse.statusCode)"
                ]
            )
        }

        return data
    }

    private static func requestJSON(_ url: URL) async throws -> Any {
        let data = try await makeRequest(url)

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NSError(
                domain: "SteamAPI",
                code: -2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Steam 返回的数据无法解析"
                ]
            )
        }
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String] ?? []).filter { !$0.isEmpty }
    }

    private static func makeURL(
        _ string: String,
        queryItems: [URLQueryItem]
    ) -> URL? {
        guard var components = URLComponents(string: string) else {
            return nil
        }

        components.queryItems = queryItems
        return components.url
    }

    // 搜索 Steam 商店的免费商品
    static func fetchFreeGames() async throws -> [SteamGame] {
        guard let url = makeURL(
            "https://store.steampowered.com/search/results/",
            queryItems: [
                URLQueryItem(name: "specials", value: "1"),
                URLQueryItem(name: "maxprice", value: "free"),
                URLQueryItem(name: "json", value: "1"),
                URLQueryItem(name: "count", value: "50"),
                URLQueryItem(name: "cc", value: countryCode),
                URLQueryItem(name: "l", value: language)
            ]
        ) else {
            throw URLError(.badURL)
        }

        let json = try await requestJSON(url)
        let root = dictionary(json)

        var candidates: [(id: Int, name: String)] = []
        var seen = Set<Int>()

        func addCandidate(_ id: Int, _ name: String) {
            guard id > 0, !seen.contains(id) else { return }
            seen.insert(id)
            candidates.append((id: id, name: name))
        }

        // 优先解析搜索结果 items
        if let items = root["items"] as? [[String: Any]] {
            for item in items {
                let id = (item["id"] as? Int)
                    ?? Int(string(item["id"]))
                    ?? (item["appid"] as? Int)
                    ?? Int(string(item["appid"]))
                    ?? 0

                addCandidate(id, string(item["name"]))
            }
        }

        // 兼容搜索结果 HTML
        let html = string(root["results_html"])

        if !html.isEmpty {
            let patterns = [
                #"/app/(\d+)(?:/|")"#,
                #"data-ds-appid="(\d+)""#
            ]

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(
                    pattern: pattern
                ) else {
                    continue
                }

                let nsHTML = html as NSString
                let matches = regex.matches(
                    in: html,
                    range: NSRange(
                        location: 0,
                        length: nsHTML.length
                    )
                )

                for match in matches where match.numberOfRanges > 1 {
                    let idString = nsHTML.substring(
                        with: match.range(at: 1)
                    )

                    if let id = Int(idString) {
                        let name = extractName(
                            around: match.range.location,
                            html: html
                        )
                        addCandidate(id, name)
                    }
                }
            }
        }

        // 兼容部分搜索接口返回的 logo URL
        if let items = root["items"] as? [[String: Any]] {
            for item in items {
                let logo = string(item["logo"])

                let patterns = [
                    #"/steam/apps/(\d+)/"#,
                    #"/apps/(\d+)/"#
                ]

                for pattern in patterns {
                    guard let regex = try? NSRegularExpression(
                        pattern: pattern
                    ) else {
                        continue
                    }

                    let nsLogo = logo as NSString
                    let range = NSRange(
                        location: 0,
                        length: nsLogo.length
                    )

                    if let match = regex.firstMatch(
                        in: logo,
                        range: range
                    ), match.numberOfRanges > 1 {
                        let idString = nsLogo.substring(
                            with: match.range(at: 1)
                        )

                        if let id = Int(idString) {
                            addCandidate(id, string(item["name"]))
                        }
                    }
                }
            }
        }

        guard !candidates.isEmpty else {
            throw NSError(
                domain: "SteamAPI",
                code: -3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "没有解析到 Steam 商品，请稍后重试"
                ]
            )
        }

        var games: [SteamGame] = []

        // 逐个确认是否为限时免费促销
        for candidate in candidates {
            do {
                guard let detailURL = makeURL(
                    "https://store.steampowered.com/api/appdetails",
                    queryItems: [
                        URLQueryItem(
                            name: "appids",
                            value: "\(candidate.id)"
                        ),
                        URLQueryItem(
                            name: "cc",
                            value: countryCode
                        ),
                        URLQueryItem(
                            name: "l",
                            value: language
                        )
                    ]
                ) else {
                    continue
                }

                let detailJSON = try await requestJSON(detailURL)
                let appRoot = dictionary(
                    dictionary(detailJSON)["\(candidate.id)"]
                )

                guard appRoot["success"] as? Bool == true else {
                    continue
                }

                let data = dictionary(appRoot["data"])
                let name = string(data["name"])
                let appType = string(data["type"]).lowercased()
                let isDLC = appType == "dlc"

                guard appType == "game" || isDLC else {
                    continue
                }

                let packageGroups =
                    data["package_groups"] as? [[String: Any]] ?? []

                var isLimitedFree = false
                var originalPriceCents: Int?

                for group in packageGroups {
                    let subs = group["subs"] as? [[String: Any]] ?? []

                    for sub in subs {
                        let optionText = string(
                            sub["option_text"]
                        ).lowercased()

                        let discountPrice =
                            (sub["price_in_cents_with_discount"] as? Int)
                            ?? Int(
                                string(
                                    sub["price_in_cents_with_discount"]
                                )
                            )

                        let originalCents =
                            (sub["price_in_cents_without_discount"] as? Int)
                            ?? Int(
                                string(
                                    sub["price_in_cents_without_discount"]
                                )
                            )

                        let promotionTextMatches =
                            optionText.contains(
                                "limited free promotional package"
                            )
                            || optionText.contains("limited-time free")
                            || optionText.contains("limited time free")
                            || optionText.contains("限时免费")
                            || optionText.contains("限时免费促销")

                        if promotionTextMatches && discountPrice == 0 {
                            isLimitedFree = true
                            originalPriceCents = originalCents
                            break
                        }
                    }

                    if isLimitedFree {
                        break
                    }
                }

                guard isLimitedFree else {
                    continue
                }

                let imageURL = string(data["header_image"])

                let priceText: String
                if let cents = originalPriceCents, cents > 0 {
                    priceText = formatSGD(cents)
                } else {
                    priceText = "限时免费"
                }

                games.append(
                    SteamGame(
                        id: candidate.id,
                        name: name.isEmpty ? candidate.name : name,
                        imageURL: imageURL,
                        originalPrice: priceText,
                        kind: isDLC ? .dlc : .game
                    )
                )
            } catch {
                // 单个商品失败不影响其他商品
                continue
            }
        }

        return games.sorted {
            if $0.isDLC != $1.isDLC {
                return !$0.isDLC
            }

            return $0.name.localizedCompare($1.name)
                == .orderedAscending
        }
    }

    private static func extractName(
        around location: Int,
        html: String
    ) -> String {
        let start = max(0, location - 500)
        let end = min(html.count, location + 1000)

        let lowerIndex = html.index(
            html.startIndex,
            offsetBy: start
        )
        let upperIndex = html.index(
            html.startIndex,
            offsetBy: end
        )

        let fragment = String(html[lowerIndex..<upperIndex])

        guard let regex = try? NSRegularExpression(
            pattern: #"class="title">([^<]+)</span>"#
        ) else {
            return ""
        }

        let nsFragment = fragment as NSString
        let range = NSRange(
            location: 0,
            length: nsFragment.length
        )

        guard let match = regex.firstMatch(
            in: fragment,
            range: range
        ), match.numberOfRanges > 1 else {
            return ""
        }

        return nsFragment.substring(with: match.range(at: 1))
    }

    private static func formatSGD(_ cents: Int) -> String {
        let amount = Double(cents) / 100

        return amount.formatted(
            .currency(code: "SGD")
                .locale(Locale(identifier: "en_SG"))
        )
    }

    // 获取游戏详情
    static func fetchDetails(appID: Int) async throws -> SteamGameDetails {
        guard let url = makeURL(
            "https://store.steampowered.com/api/appdetails",
            queryItems: [
                URLQueryItem(name: "appids", value: "\(appID)"),
                URLQueryItem(name: "cc", value: countryCode),
                URLQueryItem(name: "l", value: language)
            ]
        ) else {
            throw URLError(.badURL)
        }

        let json = try await requestJSON(url)
        let root = dictionary(
            dictionary(json)["\(appID)"]
        )

        guard root["success"] as? Bool == true else {
            throw NSError(
                domain: "SteamAPI",
                code: -4,
                userInfo: [
                    NSLocalizedDescriptionKey: "无法获取游戏详情"
                ]
            )
        }

        let data = dictionary(root["data"])
        let priceOverview = dictionary(data["price_overview"])

        let originalCents = (priceOverview["initial"] as? Int)
            ?? (priceOverview["final"] as? Int)
            ?? 0

        let screenshots =
            (data["screenshots"] as? [[String: Any]] ?? [])
            .compactMap { $0["path_full"] as? String }
            .filter { !$0.isEmpty }

        return SteamGameDetails(
            name: string(data["name"]),
            description: string(data["short_description"]),
            developers: stringArray(data["developers"]),
            publishers: stringArray(data["publishers"]),
            headerImage: string(data["header_image"]),
            screenshots: screenshots,
            originalPrice: originalCents > 0
                ? formatSGD(originalCents)
                : "免费",
            isFree: originalCents == 0
        )
    }

    // 获取 Steam 评价摘要
    static func fetchReviews(appID: Int) async throws -> SteamReviewSummary {
        let attempts: [(String, String)] = [
            ("all", "0"),
            ("all", "10"),
            ("schinese", "10")
        ]

        var lastError: Error?

        for (reviewLanguage, count) in attempts {
            do {
                guard let url = makeURL(
                    "https://store.steampowered.com/appreviews/\(appID)",
                    queryItems: [
                        URLQueryItem(name: "json", value: "1"),
                        URLQueryItem(
                            name: "language",
                            value: reviewLanguage
                        ),
                        URLQueryItem(
                            name: "purchase_type",
                            value: "all"
                        ),
                        URLQueryItem(
                            name: "num_per_page",
                            value: count
                        )
                    ]
                ) else {
                    continue
                }

                let json = try await requestJSON(url)
                let root = dictionary(json)
                let summary = dictionary(root["query_summary"])

                if !summary.isEmpty {
                    let total = (summary["total_reviews"] as? Int)
                        ?? Int(string(summary["total_reviews"]))
                        ?? 0

                    let positive = (summary["total_positive"] as? Int)
                        ?? Int(string(summary["total_positive"]))
                        ?? 0

                    let negative = (summary["total_negative"] as? Int)
                        ?? Int(string(summary["total_negative"]))
                        ?? 0

                    return SteamReviewSummary(
                        totalReviews: total,
                        positiveReviews: positive,
                        negativeReviews: negative
                    )
                }

                if root["success"] as? Int == 1 {
                    return SteamReviewSummary(
                        totalReviews: 0,
                        positiveReviews: 0,
                        negativeReviews: 0
                    )
                }
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NSError(
            domain: "SteamAPI",
            code: -5,
            userInfo: [
                NSLocalizedDescriptionKey: "Steam 评价暂时无法加载"
            ]
        )
    }
}

// MARK: - 首页数据管理

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadGames() async {
        guard !isLoading else {
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            games = try await SteamAPI.fetchFreeGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 点击动效

private struct SteamCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .offset(y: configuration.isPressed ? 1.5 : 0)
            .shadow(
                color: .black.opacity(
                    configuration.isPressed ? 0.08 : 0.24
                ),
                radius: configuration.isPressed ? 4 : 12,
                x: 0,
                y: configuration.isPressed ? 2 : 7
            )
            .animation(
                .spring(response: 0.28, dampingFraction: 0.68),
                value: configuration.isPressed
            )
    }
}

// MARK: - 首页

struct ContentView: View {
    @StateObject private var store = SteamStore()

    private let horizontalPadding: CGFloat = 22

    private var games: [SteamGame] {
        store.games.filter { !$0.isDLC }
    }

    private var dlcs: [SteamGame] {
        store.games.filter { $0.isDLC }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SteamStyle.background
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        header

                        summaryCard

                        if store.isLoading && store.games.isEmpty {
                            loadingView
                        } else if let error = store.errorMessage,
                                  store.games.isEmpty {
                            errorView(error)
                        } else if store.games.isEmpty {
                            emptyView
                        } else {
                            if !games.isEmpty {
                                gameSection(
                                    title: "限时免费游戏",
                                    subtitle: "限时领取，错过可能恢复原价",
                                    items: games
                                )
                            }

                            if !dlcs.isEmpty {
                                gameSection(
                                    title: "免费 DLC 内容",
                                    subtitle: "扩展内容与附加组件",
                                    items: dlcs
                                )
                            }

                            footer
                        }
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, 18)
                    .padding(.bottom, 34)
                }
                .refreshable {
                    await store.loadGames()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SteamGame.self) { game in
                SteamGameDetailView(game: game)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if store.games.isEmpty {
                await store.loadGames()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(
                            colors: [
                                SteamStyle.blue,
                                Color(
                                    red: 0.16,
                                    green: 0.37,
                                    blue: 0.75
                                )
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 54, height: 54)

                Image(systemName: "gift.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("永久限免助手")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.white)

                Text("发现 Steam 限时免费好游戏")
                    .font(.system(size: 12))
                    .foregroundStyle(SteamStyle.secondary)
            }

            Spacer(minLength: 0)

            Button {
                Task {
                    await store.loadGames()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SteamStyle.cyan)
                    .frame(width: 42, height: 42)
                    .background(
                        SteamStyle.cardLight,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新游戏")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryCard: some View {
        HStack(spacing: 0) {
            summaryItem(
                icon: "gamecontroller.fill",
                title: "游戏本体",
                value: "\(games.count)",
                color: SteamStyle.blue
            )

            Rectangle()
                .fill(SteamStyle.border)
                .frame(width: 1, height: 42)

            summaryItem(
                icon: "square.stack.3d.up.fill",
                title: "DLC 内容",
                value: "\(dlcs.count)",
                color: SteamStyle.cyan
            )

            Rectangle()
                .fill(SteamStyle.border)
                .frame(width: 1, height: 42)

            summaryItem(
                icon: "tag.fill",
                title: "当前价格",
                value: "免费",
                color: SteamStyle.green
            )
        }
        .padding(.vertical, 19)
        .padding(.horizontal, 8)
        .background(
            LinearGradient(
                colors: [
                    SteamStyle.cardLight,
                    SteamStyle.card
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(SteamStyle.border, lineWidth: 1)
        }
    }

    private func summaryItem(
        icon: String,
        title: String,
        value: String,
        color: Color
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)

            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(SteamStyle.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 单列横向长条卡片布局

    private func gameSection(
        title: String,
        subtitle: String,
        items: [SteamGame]
    ) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SteamStyle.blue)
                    .frame(width: 4, height: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SteamStyle.secondary)
                }

                Spacer(minLength: 0)

                Text("\(items.count)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SteamStyle.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        SteamStyle.blue.opacity(0.15),
                        in: Capsule()
                    )
            }

            LazyVStack(spacing: 15) {
                ForEach(items) { game in
                    NavigationLink(value: game) {
                        GameCard(game: game)
                    }
                    .buttonStyle(SteamCardButtonStyle())
                    .buttonBorderShape(.roundedRectangle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var loadingView: some View {
        VStack(spacing: 15) {
            ProgressView()
                .tint(SteamStyle.cyan)
                .scaleEffect(1.2)

            Text("正在寻找限时免费游戏…")
                .font(.system(size: 14))
                .foregroundStyle(SteamStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 65)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(SteamStyle.cyan)

            Text("暂时无法获取游戏")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)
                .multilineTextAlignment(.center)

            Button {
                Task {
                    await store.loadGames()
                }
            } label: {
                Label(
                    "重新加载",
                    systemImage: "arrow.clockwise"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(
                    SteamStyle.blue,
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(
            SteamStyle.card,
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "gift")
                .font(.system(size: 36))
                .foregroundStyle(SteamStyle.cyan)

            Text("暂时没有找到限时免费内容")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)

            Text("可以下拉刷新，稍后再试")
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var footer: some View {
        Text("数据来自 Steam 商店 · 限免状态可能随时变化")
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 2)
    }
}

// MARK: - 横向长条游戏卡片

private struct GameCard: View {
    let game: SteamGame

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: game.imageURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)

                case .failure:
                    imagePlaceholder

                case .empty:
                    imagePlaceholder
                        .overlay {
                            ProgressView()
                                .tint(SteamStyle.cyan)
                                .scaleEffect(0.8)
                        }

                @unknown default:
                    imagePlaceholder
                }
            }
            .frame(width: 132, height: 82)
            .clipped()
            .clipShape(
                RoundedRectangle(cornerRadius: 11)
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(game.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )

                HStack(spacing: 6) {
                    Image(systemName: game.isDLC
                          ? "square.stack.3d.up.fill"
                          : "gamecontroller.fill")

                    Text(game.kind.rawValue)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(
                    game.isDLC
                        ? SteamStyle.cyan
                        : SteamStyle.blue
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    (
                        game.isDLC
                            ? SteamStyle.cyan
                            : SteamStyle.blue
                    ).opacity(0.12),
                    in: Capsule()
                )

                HStack(spacing: 5) {
                    Text("当前免费")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SteamStyle.green)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 5) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(SteamStyle.green)

                Text("免费")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SteamStyle.green)
            }
            .frame(width: 38)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    SteamStyle.cardLight,
                    SteamStyle.card
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 17)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 17)
                .stroke(SteamStyle.border, lineWidth: 1)
        }
        .contentShape(
            RoundedRectangle(cornerRadius: 17)
        )
    }

    private var imagePlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [
                    SteamStyle.cardLight,
                    SteamStyle.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 26))
                .foregroundStyle(SteamStyle.blue.opacity(0.8))
        }
        .frame(width: 132, height: 82)
    }
}

// MARK: - 游戏详情页

private struct SteamGameDetailView: View {
    let game: SteamGame

    @State private var details: SteamGameDetails?
    @State private var reviews: SteamReviewSummary?
    @State private var detailError: String?
    @State private var reviewError: String?
    @State private var isLoadingDetails = false
    @State private var isLoadingReviews = false

    var body: some View {
        ZStack {
            SteamStyle.background
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    coverSection
                    titleSection
                    reviewSection
                    priceSection
                    descriptionSection
                    infoSection
                    screenshotsSection
                    claimButton
                }
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 35)
            }
        }
        .navigationTitle("游戏详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(
            SteamStyle.background,
            for: .navigationBar
        )
        .toolbarBackground(
            .visible,
            for: .navigationBar
        )
        .task {
            await loadDetails()
            await loadReviews()
        }
    }

    private var coverSection: some View {
        AsyncImage(
            url: URL(
                string: details?.headerImage ?? game.imageURL
            )
        ) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)

            default:
                ZStack {
                    SteamStyle.cardLight

                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(SteamStyle.blue)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipped()
        .clipShape(
            RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(SteamStyle.border, lineWidth: 1)
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(details?.name ?? game.name)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(
                    horizontal: false,
                    vertical: true
                )

            HStack(spacing: 8) {
                Text(game.kind.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SteamStyle.cyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        SteamStyle.cyan.opacity(0.12),
                        in: Capsule()
                    )

                Label(
                    "Steam 商店",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(SteamStyle.secondary)
            }
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                "玩家评价",
                icon: "star.fill"
            )

            if isLoadingReviews && reviews == nil {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(SteamStyle.cyan)

                    Text("正在加载评价…")
                        .font(.system(size: 13))
                        .foregroundStyle(SteamStyle.secondary)
                }
                .padding(16)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .background(
                    SteamStyle.card,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            } else if let reviews {
                if reviews.totalReviews > 0 {
                    HStack(spacing: 16) {
                        VStack(spacing: 6) {
                            Text("\(reviews.positivePercent)%")
                                .font(
                                    .system(size: 30, weight: .bold)
                                )
                                .foregroundStyle(SteamStyle.green)

                            Text("好评率")
                                .font(.system(size: 11))
                                .foregroundStyle(SteamStyle.secondary)
                        }
                        .frame(width: 92)

                        Rectangle()
                            .fill(SteamStyle.border)
                            .frame(width: 1, height: 52)

                        VStack(alignment: .leading, spacing: 7) {
                            Text("\(reviews.totalText) 条用户评价")
                                .font(
                                    .system(size: 14, weight: .semibold)
                                )
                                .foregroundStyle(.white)

                            Text(
                                "好评 \(reviews.positiveReviews.formatted()) · 差评 \(reviews.negativeReviews.formatted())"
                            )
                            .font(.system(size: 11))
                            .foregroundStyle(SteamStyle.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        SteamStyle.card,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                } else {
                    reviewEmptyState("Steam 暂无可统计的评价")
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        reviewError ?? "暂时无法获取玩家评价"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(SteamStyle.secondary)

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                await loadReviews()
                            }
                        } label: {
                            Label(
                                "重试",
                                systemImage: "arrow.clockwise"
                            )
                            .font(
                                .system(size: 12, weight: .semibold)
                            )
                            .foregroundStyle(SteamStyle.cyan)
                        }
                        .buttonStyle(.plain)

                        Button {
                            openSteamReviews()
                        } label: {
                            Text("打开 Steam 评价")
                                .font(
                                    .system(size: 12, weight: .semibold)
                                )
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .background(
                    SteamStyle.card,
                    in: RoundedRectangle(cornerRadius: 14)
                )
            }
        }
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                "领取信息",
                icon: "gift.fill"
            )

            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前价格")
                        .font(.system(size: 12))
                        .foregroundStyle(SteamStyle.secondary)

                    Text("免费")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(SteamStyle.green)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("原价参考")
                        .font(.system(size: 12))
                        .foregroundStyle(SteamStyle.secondary)

                    Text(game.originalPrice)
                        .font(
                            .system(size: 14, weight: .semibold)
                        )
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .padding(17)
            .background(
                SteamStyle.card,
                in: RoundedRectangle(cornerRadius: 15)
            )

            Text(
                "限免活动可能随时结束，最终价格及领取条件请以 Steam 商店页面为准。"
            )
            .font(.system(size: 11))
            .foregroundStyle(SteamStyle.secondary)
            .fixedSize(
                horizontal: false,
                vertical: true
            )
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                "游戏介绍",
                icon: "text.alignleft"
            )

            if isLoadingDetails && details == nil {
                ProgressView()
                    .tint(SteamStyle.cyan)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .padding(16)
                    .background(
                        SteamStyle.card,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            } else if let description = details?.description,
                      !description.isEmpty {
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineSpacing(5)
                    .fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                    .padding(16)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                    .background(
                        SteamStyle.card,
                        in: RoundedRectangle(cornerRadius: 14)
                    )
            } else {
                Text(
                    detailError ?? "暂时没有获取到游戏介绍"
                )
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)
                .padding(16)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )
                .background(
                    SteamStyle.card,
                    in: RoundedRectangle(cornerRadius: 14)
                )

                Button("重新加载详情") {
                    Task {
                        await loadDetails()
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SteamStyle.cyan)
                .buttonStyle(.plain)
            }
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                "内容信息",
                icon: "info.circle.fill"
            )

            VStack(spacing: 0) {
                infoRow(
                    title: "内容类型",
                    value: game.kind.rawValue
                )

                Divider()
                    .overlay(SteamStyle.border)

                infoRow(
                    title: "开发商",
                    value: displayNames(
                        details?.developers
                    )
                )

                Divider()
                    .overlay(SteamStyle.border)

                infoRow(
                    title: "发行商",
                    value: displayNames(
                        details?.publishers
                    )
                )
            }
            .padding(.horizontal, 15)
            .background(
                SteamStyle.card,
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
    }

    // 修复原先 flatMap 导致的编译错误
    private func displayNames(_ names: [String]?) -> String {
        guard let names = names, !names.isEmpty else {
            return "暂无信息"
        }

        let result = names
            .filter { !$0.isEmpty }
            .joined(separator: "、")

        return result.isEmpty ? "暂无信息" : result
    }

    @ViewBuilder
    private var screenshotsSection: some View {
        if let screenshots = details?.screenshots,
           !screenshots.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(
                    "游戏截图",
                    icon: "photo.on.rectangle"
                )

                ScrollView(
                    .horizontal,
                    showsIndicators: false
                ) {
                    HStack(spacing: 12) {
                        ForEach(
                            Array(
                                screenshots.prefix(8).enumerated()
                            ),
                            id: \.offset
                        ) { _, url in
                            AsyncImage(
                                url: URL(string: url)
                            ) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .aspectRatio(
                                            contentMode: .fill
                                        )
                                } else {
                                    SteamStyle.cardLight
                                }
                            }
                            .frame(width: 245, height: 138)
                            .clipped()
                            .clipShape(
                                RoundedRectangle(cornerRadius: 12)
                            )
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var claimButton: some View {
        Button {
            UIApplication.shared.open(game.storeURL)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gift.fill")
                    .font(
                        .system(size: 17, weight: .bold)
                    )

                Text("前往 Steam 确认领取")
                    .font(
                        .system(size: 15, weight: .bold)
                    )

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(
                        .system(size: 13, weight: .bold)
                    )
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: [
                        Color(
                            red: 0.12,
                            green: 0.48,
                            blue: 0.82
                        ),
                        Color(
                            red: 0.12,
                            green: 0.35,
                            blue: 0.66
                        )
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
        .buttonStyle(SteamCardButtonStyle())
        .padding(.top, 4)
    }

    private func sectionHeading(
        _ title: String,
        icon: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(
                    .system(size: 15, weight: .semibold)
                )
                .foregroundStyle(SteamStyle.cyan)

            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func infoRow(
        title: String,
        value: String
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)
                .frame(width: 58, alignment: .leading)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.trailing)
                .frame(
                    maxWidth: .infinity,
                    alignment: .trailing
                )
        }
        .padding(.vertical, 14)
    }

    private func reviewEmptyState(
        _ message: String
    ) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(SteamStyle.secondary)
            .frame(
                maxWidth: .infinity,
                alignment: .leading
            )
            .padding(16)
            .background(
                SteamStyle.card,
                in: RoundedRectangle(cornerRadius: 14)
            )
    }

    private func loadDetails() async {
        guard !isLoadingDetails else {
            return
        }

        isLoadingDetails = true
        detailError = nil

        defer {
            isLoadingDetails = false
        }

        do {
            details = try await SteamAPI.fetchDetails(
                appID: game.id
            )
        } catch {
            detailError = error.localizedDescription
        }
    }

    private func loadReviews() async {
        guard !isLoadingReviews else {
            return
        }

        isLoadingReviews = true
        reviewError = nil

        defer {
            isLoadingReviews = false
        }

        do {
            reviews = try await SteamAPI.fetchReviews(
                appID: game.id
            )
        } catch {
            reviewError = error.localizedDescription
        }
    }

    private func openSteamReviews() {
        let url = URL(
            string: "https://steamcommunity.com/app/\(game.id)/reviews/"
        )!

        UIApplication.shared.open(url)
    }
}
