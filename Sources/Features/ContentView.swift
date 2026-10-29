
import SwiftUI
import Foundation

// MARK: - Steam 风格配色

private enum SteamStyle {
    static let background = Color(red: 0.055, green: 0.090, blue: 0.145)
    static let card = Color(red: 0.085, green: 0.145, blue: 0.220)
    static let cardLight = Color(red: 0.115, green: 0.185, blue: 0.270)
    static let blue = Color(red: 0.20, green: 0.55, blue: 0.82)
    static let cyan = Color(red: 0.35, green: 0.75, blue: 0.88)
    static let green = Color(red: 0.30, green: 0.78, blue: 0.48)
    static let text = Color.white
    static let secondary = Color(red: 0.66, green: 0.73, blue: 0.81)
    static let red = Color(red: 1.0, green: 0.40, blue: 0.38)
}

// MARK: - 数据模型

struct SteamGame: Identifiable, Hashable {
    let id: Int
    let name: String
    var originalPrice: String?

    var headerImage: String {
        "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/header.jpg"
    }

    var capsuleImage: String {
        "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/capsule_231x87.jpg"
    }

    var storeURL: URL {
        URL(string: "https://store.steampowered.com/app/\(id)/")!
    }
}

struct SteamGameDetails {
    let name: String
    let headerImage: String
    let description: String
    let developers: [String]
    let publishers: [String]
    let genres: [String]
    let originalPrice: String?
    let screenshots: [String]
}

struct SteamReviewSummary {
    let description: String
    let totalReviews: Int
    let positiveReviews: Int
    let negativeReviews: Int

    var positivePercent: Int {
        guard totalReviews > 0 else { return 0 }
        return Int((Double(positiveReviews) / Double(totalReviews) * 100).rounded())
    }
}

// MARK: - Steam API

enum SteamAPIError: LocalizedError {
    case invalidURL
    case badResponse
    case invalidJSON
    case noGameIDs
    case noFreeGames
    case detailUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Steam 接口地址无效"
        case .badResponse:
            return "Steam 接口暂时无法访问，请稍后重试"
        case .invalidJSON:
            return "Steam 返回的数据格式异常，可能是接口限流或网络异常"
        case .noGameIDs:
            return "Steam 搜索接口已返回数据，但没有解析到游戏编号，请稍后重试"
        case .noFreeGames:
            return "暂时没有找到符合条件的限时免费游戏，请稍后刷新"
        case .detailUnavailable:
            return "暂时无法获取游戏详情，请稍后重试"
        }
    }
}

enum SteamAPI {

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // 统一请求与 JSON 解析
    private static func requestJSON(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(
            "application/json, text/javascript, */*; q=0.01",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "https://store.steampowered.com/",
            forHTTPHeaderField: "Referer"
        )

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw SteamAPIError.badResponse
        }

        do {
            return try JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            )
        } catch {
            throw SteamAPIError.invalidJSON
        }
    }

    private static func makeSearchURL() throws -> URL {
        var components = URLComponents(
            string: "https://store.steampowered.com/search/results/"
        )

        components?.queryItems = [
            URLQueryItem(name: "specials", value: "1"),
            URLQueryItem(name: "maxprice", value: "free"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "count", value: "50"),
            URLQueryItem(name: "cc", value: "sg"),
            URLQueryItem(name: "l", value: "schinese")
        ]

        guard let url = components?.url else {
            throw SteamAPIError.invalidURL
        }

        return url
    }

    // 兼容 Steam 搜索结果中的不同字段和 HTML 格式
    private static func extractCandidates(from json: Any)
        -> [(id: Int, name: String)] {

        var names: [Int: String] = [:]
        var orderedIDs: [Int] = []

        func add(_ id: Int, _ name: String?) {
            guard id > 0 else { return }

            if !orderedIDs.contains(id) {
                orderedIDs.append(id)
            }

            if let name = name?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                names[id] = name
            }
        }

        func extractIDs(from text: String) {
            let patterns = [
                #"/app/(\d+)"#,
                #"/apps/(\d+)/"#,
                #"steam/apps/(\d+)/"#
            ]

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.caseInsensitive]
                ) else { continue }

                let nsText = text as NSString
                let matches = regex.matches(
                    in: text,
                    range: NSRange(location: 0, length: nsText.length)
                )

                for match in matches where match.numberOfRanges > 1 {
                    let value = nsText.substring(with: match.range(at: 1))
                    if let id = Int(value) {
                        add(id, nil)
                    }
                }
            }
        }

        // 先解析 JSON 中可能存在的 items 数组
        if let dictionary = json as? [String: Any] {
            if let items = dictionary["items"] as? [[String: Any]] {
                for item in items {
                    var appID: Int?

                    if let value = item["appid"] as? Int {
                        appID = value
                    } else if let value = item["id"] as? Int {
                        appID = value
                    } else if let value = item["appid"] as? String {
                        appID = Int(value)
                    }

                    let name = item["name"] as? String

                    if let appID {
                        add(appID, name)
                    }

                    // 某些返回格式只有 logo 地址
                    if let logo = item["logo"] as? String {
                        extractIDs(from: logo)
                    }
                }
            }

            // 兼容 items 为其他 JSON 结构的情况
            if let items = dictionary["items"] as? [String: Any] {
                if let html = items["results_html"] as? String {
                    extractIDs(from: html)
                }

                if let results = items["results"] as? [[String: Any]] {
                    for item in results {
                        let id = (item["appid"] as? Int)
                            ?? (item["id"] as? Int)

                        if let id {
                            add(id, item["name"] as? String)
                        }
                    }
                }
            }

            if let html = dictionary["results_html"] as? String {
                extractIDs(from: html)
            }

            // 部分接口会把 HTML 放在 items 字符串中
            if let html = dictionary["items"] as? String {
                extractIDs(from: html)
            }
        }

        // 兼容直接返回字符串的情况
        if let html = json as? String {
            extractIDs(from: html)
        }

        return orderedIDs.map { ($0, names[$0] ?? "") }
    }

    private static func cleanHTML(_ html: String) -> String {
        var result = html

        let replacements: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&#x27;", "'")
        ]

        for (source, target) in replacements {
            result = result.replacingOccurrences(
                of: source,
                with: target
            )
        }

        return result
            .replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatPrice(
        cents: Int?,
        currency: String?
    ) -> String? {
        guard let cents, cents > 0 else { return nil }

        let amount = Double(cents) / 100.0

        switch currency?.uppercased() {
        case "CNY":
            return String(format: "¥%.2f", amount)
        case "SGD":
            return String(format: "S$%.2f", amount)
        case "USD":
            return String(format: "$%.2f", amount)
        case "EUR":
            return String(format: "€%.2f", amount)
        case "GBP":
            return String(format: "£%.2f", amount)
        default:
            return String(format: "%.2f", amount)
        }
    }

    private static func appDetailsJSON(appID: Int) async throws
        -> [String: Any] {

        var components = URLComponents(
            string: "https://store.steampowered.com/api/appdetails/"
        )

        components?.queryItems = [
            URLQueryItem(name: "appids", value: String(appID)),
            URLQueryItem(name: "cc", value: "sg"),
            URLQueryItem(name: "l", value: "schinese")
        ]

        guard let url = components?.url else {
            throw SteamAPIError.invalidURL
        }

        let json = try await requestJSON(url)

        guard let root = json as? [String: Any],
              let result = root[String(appID)] as? [String: Any],
              (result["success"] as? Bool) == true,
              let data = result["data"] as? [String: Any] else {
            throw SteamAPIError.detailUnavailable
        }

        return data
    }

    private static func promotionInfo(
        from data: [String: Any]
    ) -> (isFree: Bool, originalPrice: String?) {

        guard let groups = data["package_groups"] as? [[String: Any]]
        else {
            return (false, nil)
        }

        for group in groups {
            guard let subs = group["subs"] as? [[String: Any]]
            else { continue }

            for sub in subs {
                let optionText = (
                    sub["option_text"] as? String ?? ""
                ).lowercased()

                let discountPrice =
                    (sub["price_in_cents_with_discount"] as? Int)
                    ?? Int(
                        sub["price_in_cents_with_discount"] as? String ?? ""
                    )

                let originalCents =
                    (sub["price_in_cents_without_discount"] as? Int)
                    ?? Int(
                        sub["price_in_cents_without_discount"] as? String ?? ""
                    )

                let isLimitedPromotion =
                    optionText.contains("limited free promotional package")
                    || optionText.contains("limited-time free")
                    || optionText.contains("限时免费")

                if isLimitedPromotion, discountPrice == 0 {
                    return (
                        true,
                        formatPrice(
                            cents: originalCents,
                            currency: "SGD"
                        )
                    )
                }
            }
        }

        return (false, nil)
    }

    // MARK: 获取限时免费游戏列表

    static func fetchFreeGames() async throws -> [SteamGame] {
        let searchURL = try makeSearchURL()
        let json = try await requestJSON(searchURL)
        let candidates = extractCandidates(from: json)

        guard !candidates.isEmpty else {
            throw SteamAPIError.noGameIDs
        }

        var games: [SteamGame] = []
        var checked = 0

        // 保留原先的核验方式：
        // 搜索接口负责发现游戏，appdetails 负责核实限时免费资格。
        for candidate in candidates {
            if Task.isCancelled { break }

            do {
                let data = try await appDetailsJSON(appID: candidate.id)
                checked += 1

                let promotion = promotionInfo(from: data)

                guard promotion.isFree else { continue }

                let name = data["name"] as? String
                    ?? candidate.name

                guard !name.isEmpty else { continue }

                let game = SteamGame(
                    id: candidate.id,
                    name: name,
                    originalPrice: promotion.originalPrice
                )

                if !games.contains(where: { $0.id == game.id }) {
                    games.append(game)
                }
            } catch {
                // 单个游戏接口失败，不影响其他游戏继续核验
                continue
            }
        }

        if games.isEmpty && checked == 0 {
            throw SteamAPIError.badResponse
        }

        return games.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending
        }
    }

    // MARK: 获取详情

    static func fetchDetails(appID: Int) async throws -> SteamGameDetails {
        let data = try await appDetailsJSON(appID: appID)

        let screenshots = (data["screenshots"] as? [[String: Any]] ?? [])
            .compactMap { $0["path_full"] as? String }

        let developers = data["developers"] as? [String] ?? []
        let publishers = data["publishers"] as? [String] ?? []

        let genres = (data["genres"] as? [[String: Any]] ?? [])
            .compactMap { $0["description"] as? String }

        var originalPrice: String?

        if let priceOverview = data["price_overview"] as? [String: Any] {
            originalPrice =
                priceOverview["initial_formatted"] as? String

            if originalPrice?.isEmpty == true {
                originalPrice = nil
            }
        }

        if originalPrice == nil {
            originalPrice = promotionInfo(from: data).originalPrice
        }

        return SteamGameDetails(
            name: data["name"] as? String ?? "未知游戏",
            headerImage: data["header_image"] as? String
                ?? "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/header.jpg",
            description: cleanHTML(
                data["short_description"] as? String ?? "暂无游戏介绍"
            ),
            developers: developers,
            publishers: publishers,
            genres: genres,
            originalPrice: originalPrice,
            screenshots: screenshots
        )
    }

    // MARK: 获取 Steam 评价

    static func fetchReviews(appID: Int) async throws
        -> SteamReviewSummary {

        var components = URLComponents(
            string: "https://store.steampowered.com/appreviews/\(appID)"
        )

        components?.queryItems = [
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "language", value: "all"),
            URLQueryItem(name: "purchase_type", value: "all"),
            URLQueryItem(name: "num_per_page", value: "10")
        ]

        guard let url = components?.url else {
            throw SteamAPIError.invalidURL
        }

        let json = try await requestJSON(url)

        guard let root = json as? [String: Any],
              let summary = root["query_summary"] as? [String: Any] else {
            throw SteamAPIError.invalidJSON
        }

        return SteamReviewSummary(
            description: summary["review_score_desc"] as? String
                ?? "暂无评价",
            totalReviews: summary["total_reviews"] as? Int ?? 0,
            positiveReviews: summary["total_positive"] as? Int ?? 0,
            negativeReviews: summary["total_negative"] as? Int ?? 0
        )
    }
}

// MARK: - 列表状态管理

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var lastUpdated: Date?

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        do {
            let result = try await SteamAPI.fetchFreeGames()
            games = result
            lastUpdated = Date()

            if result.isEmpty {
                errorMessage = SteamAPIError.noFreeGames.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - 主页

struct ContentView: View {
    @StateObject private var store = SteamStore()

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                SteamStyle.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
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
                            gameGrid
                        }

                        footer
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 30)
                }
                .refreshable {
                    await store.refresh()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if store.games.isEmpty && !store.isLoading {
                    await store.refresh()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(SteamStyle.cyan)

                Text("STEAM")
                    .font(.system(size: 29, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white)

                Text("限免助手")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SteamStyle.cyan)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text("发现正在限时免费的 Steam 游戏")
                .font(.system(size: 13))
                .foregroundStyle(SteamStyle.secondary)

            HStack(spacing: 6) {
                Circle()
                    .fill(SteamStyle.green)
                    .frame(width: 7, height: 7)

                Text("STEAM STORE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(SteamStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(SteamStyle.blue.opacity(0.20))
                    .frame(width: 54, height: 54)

                Image(systemName: "gift.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(SteamStyle.cyan)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("今日限免发现")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)

                Text("符合条件的限时免费游戏")
                    .font(.system(size: 12))
                    .foregroundStyle(SteamStyle.secondary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(store.games.count)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(SteamStyle.cyan)
                    .contentTransition(.numericText())

                Text("款游戏")
                    .font(.system(size: 11))
                    .foregroundStyle(SteamStyle.secondary)
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [SteamStyle.cardLight, SteamStyle.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(SteamStyle.cyan.opacity(0.15), lineWidth: 1)
        }
    }

    private var gameGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("限免游戏")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    Task {
                        await store.refresh()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                        Text("刷新")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SteamStyle.cyan)
                }
                .disabled(store.isLoading)
            }

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(store.games) { game in
                    NavigationLink(value: game) {
                        GameCard(game: game)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationDestination(for: SteamGame.self) { game in
                SteamGameDetailView(game: game)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 15) {
            ProgressView()
                .tint(SteamStyle.cyan)
                .scaleEffect(1.25)

            Text("正在连接 Steam，核实限免资格…")
                .font(.system(size: 13))
                .foregroundStyle(SteamStyle.secondary)

            Text("首次加载可能需要一点时间")
                .font(.system(size: 11))
                .foregroundStyle(SteamStyle.secondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(SteamStyle.red)

            Text("暂时无法读取 Steam 游戏列表")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button {
                Task {
                    await store.refresh()
                }
            } label: {
                Label("重新获取", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(SteamStyle.blue)
                    .clipShape(Capsule())
            }
            .disabled(store.isLoading)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(SteamStyle.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 38))
                .foregroundStyle(SteamStyle.secondary)

            Text("暂时没有找到限免游戏")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            Text("可以下拉页面刷新，重新检查 Steam 商店")
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)

            Button("重新检查") {
                Task {
                    await store.refresh()
                }
            }
            .tint(SteamStyle.cyan)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 45)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let updated = store.lastUpdated {
                Text("最近检查：\(updated.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 10))
                    .foregroundStyle(SteamStyle.secondary.opacity(0.8))
            }

            Text("数据来自 Steam 商店 · 领取前请以商店页面为准")
                .font(.system(size: 10))
                .foregroundStyle(SteamStyle.secondary.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

// MARK: - 游戏卡片

struct GameCard: View {
    let game: SteamGame

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                AsyncImage(url: URL(string: game.capsuleImage)) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            SteamStyle.cardLight

                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(SteamStyle.secondary)
                        }
                    }
                }
                .frame(height: 105)
                .frame(maxWidth: .infinity)
                .clipped()

                Text("限时免费")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.04, green: 0.16, blue: 0.09))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(SteamStyle.green)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 10,
                            bottomTrailingRadius: 9
                        )
                    )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(game.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 36, alignment: .topLeading)

                Divider()
                    .overlay(.white.opacity(0.08))

                HStack(alignment: .center, spacing: 5) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前价格")
                            .font(.system(size: 9))
                            .foregroundStyle(SteamStyle.secondary)

                        Text("¥0.00")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(SteamStyle.green)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SteamStyle.cyan)
                        .frame(width: 28, height: 28)
                        .background(SteamStyle.blue.opacity(0.20))
                        .clipShape(Circle())
                }
            }
            .padding(11)
        }
        .background(SteamStyle.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        }
    }
}

// MARK: - 游戏详情页

struct SteamGameDetailView: View {
    let game: SteamGame

    @State private var details: SteamGameDetails?
    @State private var reviews: SteamReviewSummary?

    @State private var detailsError: String?
    @State private var reviewsError: String?

    @State private var loadingDetails = true
    @State private var loadingReviews = true

    var body: some View {
        ZStack {
            SteamStyle.background
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroImage

                    titleSection

                    priceSection

                    reviewSection

                    descriptionSection

                    informationSection

                    screenshotsSection

                    claimButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("游戏详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(SteamStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task {
            await loadDetails()
            await loadReviews()
        }
    }

    private var heroImage: some View {
        AsyncImage(
            url: URL(string: details?.headerImage ?? game.headerImage)
        ) { phase in
            if let image = phase.image {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    SteamStyle.card
                    ProgressView()
                        .tint(SteamStyle.cyan)
                }
                .frame(height: 180)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(details?.name ?? game.name)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(SteamStyle.green)

                Text("Steam 限时免费活动")
                    .foregroundStyle(SteamStyle.secondary)
            }
            .font(.system(size: 12))
        }
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("价格信息")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("当前价格")
                        .font(.system(size: 11))
                        .foregroundStyle(SteamStyle.secondary)

                    Text("¥0.00")
                        .font(.system(size: 27, weight: .heavy, design: .rounded))
                        .foregroundStyle(SteamStyle.green)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 5) {
                    Text("原价")
                        .font(.system(size: 11))
                        .foregroundStyle(SteamStyle.secondary)

                    if let price = details?.originalPrice ?? game.originalPrice,
                       !price.isEmpty,
                       price != "¥0.00",
                       price != "S$0.00" {
                        Text(price)
                            .font(.system(size: 16, weight: .semibold))
                            .strikethrough(color: SteamStyle.red)
                            .foregroundStyle(SteamStyle.secondary)
                    } else if loadingDetails {
                        ProgressView()
                            .tint(SteamStyle.cyan)
                    } else {
                        Text("以商店页面为准")
                            .font(.system(size: 11))
                            .foregroundStyle(SteamStyle.secondary)
                    }
                }
            }
            .padding(15)
            .background(SteamStyle.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text("限免活动可能随时结束，领取前请确认商店页面仍显示免费。")
                .font(.system(size: 11))
                .foregroundStyle(SteamStyle.secondary)
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Steam 玩家评价")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            if let reviews {
                HStack(spacing: 15) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(reviews.description)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(
                                reviews.positivePercent >= 70
                                    ? SteamStyle.green : SteamStyle.cyan
                            )

                        Text("\(reviews.totalReviews) 条玩家评价")
                            .font(.system(size: 11))
                            .foregroundStyle(SteamStyle.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(reviews.positivePercent)%")
                            .font(.system(size: 25, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)

                        Text("好评率")
                            .font(.system(size: 11))
                            .foregroundStyle(SteamStyle.secondary)
                    }
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(SteamStyle.red.opacity(0.75))

                        Capsule()
                            .fill(SteamStyle.green)
                            .frame(
                                width: geometry.size.width
                                    * CGFloat(reviews.positivePercent) / 100
                            )
                    }
                }
                .frame(height: 7)

                HStack {
                    Text("好评 \(reviews.positiveReviews)")
                    Spacer()
                    Text("差评 \(reviews.negativeReviews)")
                }
                .font(.system(size: 11))
                .foregroundStyle(SteamStyle.secondary)

            } else if loadingReviews {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(SteamStyle.cyan)

                    Text("正在读取 Steam 评价…")
                        .font(.system(size: 12))
                        .foregroundStyle(SteamStyle.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SteamStyle.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(reviewsError ?? "暂时无法读取评价")
                        .font(.system(size: 12))
                        .foregroundStyle(SteamStyle.secondary)

                    Button("重新加载评价") {
                        Task {
                            await loadReviews()
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .tint(SteamStyle.cyan)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SteamStyle.card)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("游戏介绍")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            if let details {
                Text(details.description.isEmpty ? "暂无游戏介绍" : details.description)
                    .font(.system(size: 13))
                    .foregroundStyle(SteamStyle.secondary)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            } else if loadingDetails {
                ProgressView()
                    .tint(SteamStyle.cyan)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(detailsError ?? "详情加载失败")
                        .font(.system(size: 12))
                        .foregroundStyle(SteamStyle.secondary)

                    Button("重新加载详情") {
                        Task {
                            await loadDetails()
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .tint(SteamStyle.cyan)
                }
            }
        }
    }

    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("游戏信息")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            if let details {
                infoRow("开发商", details.developers.joined(separator: "、"))
                infoRow("发行商", details.publishers.joined(separator: "、"))
                infoRow("类型", details.genres.joined(separator: "、"))
            } else if loadingDetails {
                ProgressView()
                    .tint(SteamStyle.cyan)
            } else {
                Text("游戏信息暂时不可用")
                    .font(.system(size: 12))
                    .foregroundStyle(SteamStyle.secondary)
            }
        }
        .padding(15)
        .background(SteamStyle.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)
                .frame(width: 55, alignment: .leading)

            Text(value.isEmpty ? "暂无信息" : value)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var screenshotsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("游戏截图")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            if let screenshots = details?.screenshots,
               !screenshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(
                            Array(screenshots.prefix(8).enumerated()),
                            id: \.offset
                        ) { _, url in
                            AsyncImage(url: URL(string: url)) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    SteamStyle.cardLight
                                }
                            }
                            .frame(width: 250, height: 140)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            } else if loadingDetails {
                ProgressView()
                    .tint(SteamStyle.cyan)
            } else {
                Text("暂无截图")
                    .font(.system(size: 12))
                    .foregroundStyle(SteamStyle.secondary)
            }
        }
    }

    private var claimButton: some View {
        Button {
            UIApplicationHelper.open(game.storeURL)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 17, weight: .bold))

                Text("确认领取")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [
                        SteamStyle.blue,
                        Color(red: 0.12, green: 0.39, blue: 0.66)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func loadDetails() async {
        loadingDetails = true
        detailsError = nil

        defer {
            loadingDetails = false
        }

        do {
            details = try await SteamAPI.fetchDetails(appID: game.id)
        } catch {
            detailsError = error.localizedDescription
        }
    }

    @MainActor
    private func loadReviews() async {
        loadingReviews = true
        reviewsError = nil

        defer {
            loadingReviews = false
        }

        do {
            reviews = try await SteamAPI.fetchReviews(appID: game.id)
        } catch {
            reviewsError = error.localizedDescription
        }
    }
}

// MARK: - 打开领取页面

enum UIApplicationHelper {
    static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif

#Preview {
    ContentView()
}
