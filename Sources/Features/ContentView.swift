
import SwiftUI
import Foundation

// MARK: - Steam 风格配色

private enum SteamStyle {
    static let background = Color(red: 0.055, green: 0.090, blue: 0.145)
    static let surface = Color(red: 0.085, green: 0.135, blue: 0.205)
    static let surfaceLight = Color(red: 0.115, green: 0.175, blue: 0.250)
    static let steamBlue = Color(red: 0.30, green: 0.68, blue: 0.91)
    static let green = Color(red: 0.48, green: 0.83, blue: 0.43)
    static let text = Color.white
    static let secondaryText = Color(red: 0.65, green: 0.73, blue: 0.82)
    static let divider = Color.white.opacity(0.09)
}

// MARK: - 数据模型

struct SteamGame: Identifiable, Hashable {
    let id: Int
    var name: String
    var iconURL: URL? {
        URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/capsule_184x69.jpg")
    }
    var storeURL: URL {
        URL(string: "https://store.steampowered.com/app/\(id)/")!
    }
}

struct SteamGameDetails {
    let appID: Int
    let name: String
    let shortDescription: String
    let headerImage: URL?
    let screenshots: [URL]
    let developers: [String]
    let genres: [String]
    let originalPrice: String?
    let currentPrice: String?
    let currency: String?
}

struct SteamReviewSummary {
    let totalReviews: Int
    let totalPositive: Int
    let description: String

    var positivePercentage: Int {
        guard totalReviews > 0 else { return 0 }
        return Int((Double(totalPositive) / Double(totalReviews) * 100).rounded())
    }
}

// MARK: - Steam API

enum SteamAPI {
    private static func requestJSON(from url: URL) async throws -> Any {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://store.steampowered.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "SteamAPI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Steam 接口暂时无法访问，请稍后重试。"]
            )
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NSError(
                domain: "SteamAPI",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Steam 返回的数据格式异常，可能是接口限流或网络问题。"]
            )
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func htmlText(_ html: String) -> String {
        var result = html

        let replacements: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&#10;", " "),
            ("<br>", " "),
            ("<br/>", " "),
            ("<br />", " ")
        ]

        for (from, to) in replacements {
            result = result.replacingOccurrences(
                of: from,
                with: to,
                options: .caseInsensitive
            )
        }

        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func formatPrice(
        cents: Int,
        currency: String?
    ) -> String {
        let currencyCode = currency ?? "SGD"

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2

        let amount = NSNumber(value: Double(cents) / 100.0)
        return formatter.string(from: amount)
            ?? String(format: "%.2f", Double(cents) / 100.0)
    }

    // 搜索 Steam 限时免费促销列表
    static func fetchFreeGames() async throws -> [SteamGame] {
        var components = URLComponents(
            string: "https://store.steampowered.com/search/results/"
        )!

        components.queryItems = [
            URLQueryItem(name: "specials", value: "1"),
            URLQueryItem(name: "maxprice", value: "free"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "count", value: "50"),
            URLQueryItem(name: "cc", value: "sg"),
            URLQueryItem(name: "l", value: "schinese")
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let json = try await requestJSON(from: url)

        guard let root = json as? [String: Any],
              let html = root["results_html"] as? String else {
            throw NSError(
                domain: "SteamAPI",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "无法读取 Steam 游戏列表。"]
            )
        }

        // 从搜索结果的游戏链接中提取 app ID 和名称。
        let pattern = #"<a\b[^>]*href="https?://store\.steampowered\.com/app/(\d+)[^"]*"[^>]*>(.*?)</a>"#
        let regex = try NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )

        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHTML.length)
        )

        var games: [SteamGame] = []
        var seen = Set<Int>()

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let idRange = Range(match.range(at: 1), in: html),
                  let contentRange = Range(match.range(at: 2), in: html),
                  let appID = Int(html[idRange]),
                  !seen.contains(appID) else {
                continue
            }

            let content = String(html[contentRange])

            let titlePattern = #"<span[^>]*class="[^"]*\btitle\b[^"]*"[^>]*>(.*?)</span>"#
            let titleRegex = try? NSRegularExpression(
                pattern: titlePattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )

            var name = "Steam 游戏 \(appID)"

            if let titleRegex,
               let titleMatch = titleRegex.firstMatch(
                    in: content,
                    range: NSRange(location: 0, length: (content as NSString).length)
               ),
               titleMatch.numberOfRanges >= 2,
               let titleRange = Range(titleMatch.range(at: 1), in: content) {
                let title = htmlText(String(content[titleRange]))
                if !title.isEmpty {
                    name = title
                }
            }

            seen.insert(appID)
            games.append(SteamGame(id: appID, name: name))
        }

        // 兼容 Steam 搜索结果的 HTML 结构发生变化的情况。
        if games.isEmpty {
            let fallbackPattern = #"/app/(\d+)/"#
            let fallbackRegex = try NSRegularExpression(pattern: fallbackPattern)
            let fallbackMatches = fallbackRegex.matches(
                in: html,
                range: NSRange(location: 0, length: nsHTML.length)
            )

            for match in fallbackMatches {
                guard let range = Range(match.range(at: 1), in: html),
                      let appID = Int(html[range]),
                      !seen.contains(appID) else {
                    continue
                }

                seen.insert(appID)
                games.append(SteamGame(id: appID, name: "Steam 游戏 \(appID)"))
            }
        }

        // 进一步检查是否确实存在限时免费促销包。
        var verified: [SteamGame] = []

        for game in games {
            do {
                if try await isPermanentFreePromotion(appID: game.id) {
                    verified.append(game)
                }
            } catch {
                // 单个游戏验证失败时不影响其他游戏。
                continue
            }
        }

        return verified
    }

    // 检查 Steam 是否提供限时免费促销包。
    private static func isPermanentFreePromotion(appID: Int) async throws -> Bool {
        var components = URLComponents(
            string: "https://store.steampowered.com/api/appdetails/"
        )!

        components.queryItems = [
            URLQueryItem(name: "appids", value: String(appID)),
            URLQueryItem(name: "cc", value: "sg"),
            URLQueryItem(name: "l", value: "schinese")
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let json = try await requestJSON(from: url)

        guard let root = json as? [String: Any],
              let app = root[String(appID)] as? [String: Any],
              let success = app["success"] as? Bool,
              success,
              let data = app["data"] as? [String: Any],
              let groups = data["package_groups"] as? [[String: Any]] else {
            return false
        }

        for group in groups {
            guard let subs = group["subs"] as? [[String: Any]] else {
                continue
            }

            for sub in subs {
                let optionText = (
                    sub["option_text"] as? String ?? ""
                ).lowercased()

                let discountedPrice = integer(
                    sub["price_in_cents_with_discount"]
                )

                if optionText.contains("limited free promotional package"),
                   discountedPrice == 0 {
                    return true
                }
            }
        }

        return false
    }

    // 游戏详情和原价。
    static func fetchDetails(appID: Int) async throws -> SteamGameDetails {
        var components = URLComponents(
            string: "https://store.steampowered.com/api/appdetails/"
        )!

        components.queryItems = [
            URLQueryItem(name: "appids", value: String(appID)),
            URLQueryItem(name: "cc", value: "sg"),
            URLQueryItem(name: "l", value: "schinese")
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let json = try await requestJSON(from: url)

        guard let root = json as? [String: Any],
              let app = root[String(appID)] as? [String: Any],
              let success = app["success"] as? Bool,
              success,
              let data = app["data"] as? [String: Any] else {
            throw NSError(
                domain: "SteamAPI",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "无法读取游戏详情，请稍后重试。"]
            )
        }

        let name = data["name"] as? String ?? "Steam 游戏 \(appID)"
        let description = htmlText(
            data["short_description"] as? String ?? "暂无游戏简介。"
        )

        let headerURL = URL(
            string: data["header_image"] as? String ?? ""
        )

        var screenshots: [URL] = []
        if let items = data["screenshots"] as? [[String: Any]] {
            screenshots = items.compactMap {
                guard let path = $0["path_full"] as? String else {
                    return nil
                }
                return URL(string: path)
            }
        }

        let developers = data["developers"] as? [String] ?? []

        var genres: [String] = []
        if let items = data["genres"] as? [[String: Any]] {
            genres = items.compactMap { $0["description"] as? String }
        }

        let priceOverview = data["price_overview"] as? [String: Any]
        let currency = priceOverview?["currency"] as? String ?? "SGD"

        var originalPrice: String?
        var currentPrice: String?

        if let overview = priceOverview {
            if let initial = overview["initial_formatted"] as? String,
               !initial.isEmpty {
                originalPrice = initial
            } else if let initial = integer(overview["initial"]), initial > 0 {
                originalPrice = formatPrice(cents: initial, currency: currency)
            }

            if let final = overview["final_formatted"] as? String,
               !final.isEmpty {
                currentPrice = final
            } else if let final = integer(overview["final"]) {
                currentPrice = formatPrice(cents: final, currency: currency)
            }
        }

        // 限时免费包的原价可能在 package_groups 中，
        // 而不是 price_overview 中。
        if originalPrice == nil,
           let groups = data["package_groups"] as? [[String: Any]] {
            var originalCents: Int?

            for group in groups {
                guard let subs = group["subs"] as? [[String: Any]] else {
                    continue
                }

                for sub in subs {
                    let optionText = (
                        sub["option_text"] as? String ?? ""
                    ).lowercased()

                    let discounted = integer(
                        sub["price_in_cents_with_discount"]
                    )

                    let undiscounted = integer(
                        sub["price_in_cents_without_discount"]
                    )

                    if optionText.contains("limited free promotional package"),
                       discounted == 0,
                       let undiscounted,
                       undiscounted > 0 {
                        originalCents = max(
                            originalCents ?? 0,
                            undiscounted
                        )
                    }
                }
            }

            if let originalCents {
                originalPrice = formatPrice(
                    cents: originalCents,
                    currency: currency
                )
            }
        }

        return SteamGameDetails(
            appID: appID,
            name: name,
            shortDescription: description,
            headerImage: headerURL,
            screenshots: screenshots,
            developers: developers,
            genres: genres,
            originalPrice: originalPrice,
            currentPrice: currentPrice,
            currency: currency
        )
    }

    // Steam 用户评价。
    static func fetchReviews(appID: Int) async throws -> SteamReviewSummary {
        var components = URLComponents(
            string: "https://store.steampowered.com/appreviews/\(appID)"
        )!

        components.queryItems = [
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "language", value: "all"),
            URLQueryItem(name: "purchase_type", value: "all"),
            URLQueryItem(name: "num_per_page", value: "10")
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let json = try await requestJSON(from: url)

        guard let root = json as? [String: Any],
              let summary = root["query_summary"] as? [String: Any] else {
            throw NSError(
                domain: "SteamAPI",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "暂时无法获取 Steam 评价。"]
            )
        }

        let totalReviews = integer(summary["total_reviews"]) ?? 0
        let totalPositive = integer(summary["total_positive"]) ?? 0
        let description = summary["review_score_desc"] as? String ?? "暂无评价"

        return SteamReviewSummary(
            totalReviews: totalReviews,
            totalPositive: totalPositive,
            description: description
        )
    }
}

// MARK: - 首页

struct ContentView: View {
    @State private var games: [SteamGame] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastUpdated: Date?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                SteamStyle.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        header
                        summaryCard
                        gameSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 32)
                }
                .refreshable {
                    await refreshGames()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                if games.isEmpty {
                    await refreshGames()
                }
            }
            .navigationDestination(for: SteamGame.self) { game in
                SteamGameDetailView(game: game)
            }
        }
        .tint(SteamStyle.steamBlue)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(SteamStyle.steamBlue.opacity(0.15))
                    .frame(width: 72, height: 72)

                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(SteamStyle.steamBlue)
            }

            Text("STEAM")
                .font(.system(size: 13, weight: .black, design: .rounded))
                .tracking(5)
                .foregroundStyle(SteamStyle.steamBlue)

            Text("永久限免助手")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("发现正在限时免费领取的游戏")
                .font(.subheadline)
                .foregroundStyle(SteamStyle.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var summaryCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(SteamStyle.steamBlue.opacity(0.15))
                    .frame(width: 48, height: 48)

                Image(systemName: "gift.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(SteamStyle.steamBlue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("当前限免游戏")
                    .font(.subheadline)
                    .foregroundStyle(SteamStyle.secondaryText)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(games.count)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("款")
                        .font(.subheadline)
                        .foregroundStyle(SteamStyle.secondaryText)
                }
            }

            Spacer()

            Button {
                Task { await refreshGames() }
            } label: {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 42, height: 42)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                }
            }
            .buttonStyle(.plain)
            .background(SteamStyle.surfaceLight, in: RoundedRectangle(cornerRadius: 12))
            .disabled(isLoading)
            .accessibilityLabel("刷新游戏列表")
        }
        .padding(16)
        .background(SteamStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(SteamStyle.divider, lineWidth: 1)
        }
    }

    private var gameSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("免费领取")
                        .font(.title3.bold())
                        .foregroundStyle(.white)

                    Text("点开游戏查看详情")
                        .font(.caption)
                        .foregroundStyle(SteamStyle.secondaryText)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .tint(SteamStyle.steamBlue)
                }
            }

            if let errorMessage, games.isEmpty {
                emptyState(
                    icon: "wifi.exclamationmark",
                    title: "暂时无法加载",
                    message: errorMessage,
                    buttonTitle: "重新加载"
                ) {
                    Task { await refreshGames() }
                }
            } else if games.isEmpty && !isLoading {
                emptyState(
                    icon: "gamecontroller",
                    title: "暂时没有找到限免游戏",
                    message: "可以下拉刷新，或稍后再次检查。",
                    buttonTitle: "重新检查"
                ) {
                    Task { await refreshGames() }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(games) { game in
                        NavigationLink(value: game) {
                            GameCard(game: game)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let lastUpdated {
                Text("最后检查：\(lastUpdated.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(SteamStyle.secondaryText.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }

            Text("价格与促销信息以 Steam 商店页面为准。")
                .font(.caption2)
                .foregroundStyle(SteamStyle.secondaryText.opacity(0.75))
                .frame(maxWidth: .infinity)
        }
    }

    private func emptyState(
        icon: String,
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(SteamStyle.steamBlue)

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(SteamStyle.secondaryText)
                .multilineTextAlignment(.center)

            Button(buttonTitle, action: action)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(SteamStyle.steamBlue, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .background(SteamStyle.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    @MainActor
    private func refreshGames() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil

        do {
            games = try await SteamAPI.fetchFreeGames()
            lastUpdated = Date()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - 首页游戏卡片

struct GameCard: View {
    let game: SteamGame

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: game.iconURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholderIcon
                    case .empty:
                        placeholderIcon
                            .overlay {
                                ProgressView()
                                    .tint(SteamStyle.steamBlue)
                            }
                    @unknown default:
                        placeholderIcon
                    }
                }
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .clipped()

                Text("限时免费")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(red: 0.06, green: 0.16, blue: 0.08))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(SteamStyle.green, in: Capsule())
                    .padding(8)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(game.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)

                HStack(alignment: .center, spacing: 5) {
                    Text("¥0.00")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(SteamStyle.green)

                    Spacer(minLength: 2)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SteamStyle.steamBlue)
                }

                Text("查看详情  ›")
                    .font(.caption)
                    .foregroundStyle(SteamStyle.steamBlue)
            }
            .padding(11)
        }
        .background(SteamStyle.surface, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(SteamStyle.divider, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private var placeholderIcon: some View {
        ZStack {
            SteamStyle.surfaceLight
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 28))
                .foregroundStyle(SteamStyle.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 112)
    }
}

// MARK: - 游戏详情页

struct SteamGameDetailView: View {
    let game: SteamGame

    @State private var details: SteamGameDetails?
    @State private var review: SteamReviewSummary?
    @State private var detailsError: String?
    @State private var reviewError: String?
    @State private var loadingDetails = true
    @State private var loadingReviews = true

    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            SteamStyle.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroImage
                    titleSection
                    priceSection
                    reviewSection
                    descriptionSection
                    infoSection
                    screenshotsSection
                    claimButton
                }
                .padding(.bottom, 32)
            }
            .ignoresSafeArea(edges: .top)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: game.id) {
            await loadDetails()
            await loadReviews()
        }
        .preferredColorScheme(.dark)
    }

    private var heroImage: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = details?.headerImage {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        heroPlaceholder
                    }
                }
            } else {
                heroPlaceholder
            }

            LinearGradient(
                colors: [.clear, SteamStyle.background.opacity(0.95)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 7) {
                Text("STEAM STORE")
                    .font(.system(size: 11, weight: .black))
                    .tracking(3)
                    .foregroundStyle(SteamStyle.steamBlue)

                Text(details?.name ?? game.name)
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
            }
            .padding(18)
        }
        .frame(height: 270)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var heroPlaceholder: some View {
        ZStack {
            SteamStyle.surface
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 54))
                .foregroundStyle(SteamStyle.steamBlue.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 270)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "gift.fill")
                    .foregroundStyle(SteamStyle.green)

                Text("限时免费领取")
                    .font(.subheadline.bold())
                    .foregroundStyle(SteamStyle.green)

                Spacer()

                Text("APP ID \(game.id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(SteamStyle.secondaryText)
            }

            if loadingDetails {
                HStack(spacing: 8) {
                    ProgressView().tint(SteamStyle.steamBlue)
                    Text("正在加载游戏信息…")
                        .font(.caption)
                        .foregroundStyle(SteamStyle.secondaryText)
                }
            } else if let detailsError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(detailsError)
                        .font(.caption)
                        .foregroundStyle(.orange)

                    Button("重新加载详情") {
                        Task { await loadDetails() }
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(SteamStyle.steamBlue)
                }
            } else if let details {
                Text(details.shortDescription)
                    .font(.subheadline)
                    .foregroundStyle(SteamStyle.secondaryText)
                    .lineSpacing(4)
            }
        }
        .padding(.horizontal, 16)
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("当前促销价格", systemImage: "tag.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)

                Spacer()

                Text("限时优惠")
                    .font(.caption.bold())
                    .foregroundStyle(SteamStyle.green)
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前价格")
                        .font(.caption)
                        .foregroundStyle(SteamStyle.secondaryText)

                    Text("¥0.00")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(SteamStyle.green)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("Steam 原价")
                        .font(.caption)
                        .foregroundStyle(SteamStyle.secondaryText)

                    if let originalPrice = details?.originalPrice {
                        Text(originalPrice)
                            .font(.system(size: 17, weight: .semibold))
                            .strikethrough(color: .white.opacity(0.8))
                            .foregroundStyle(SteamStyle.secondaryText)
                    } else if loadingDetails {
                        ProgressView()
                            .tint(SteamStyle.secondaryText)
                    } else {
                        Text("暂不可用")
                            .font(.subheadline)
                            .foregroundStyle(SteamStyle.secondaryText)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                Text("价格以 Steam 商店实际显示为准，免费活动可能随时结束。")
            }
            .font(.caption2)
            .foregroundStyle(SteamStyle.secondaryText)
        }
        .padding(16)
        .background(SteamStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(SteamStyle.green.opacity(0.25), lineWidth: 1)
        }
        .padding(.horizontal, 16)
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Steam 玩家评价", systemImage: "text.bubble.fill")
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                if loadingReviews {
                    ProgressView().tint(SteamStyle.steamBlue)
                }
            }

            if let review {
                HStack(spacing: 15) {
                    VStack(spacing: 4) {
                        Text("\(review.positivePercentage)%")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(review.positivePercentage >= 70
                                             ? SteamStyle.green : .orange)

                        Text("好评率")
                            .font(.caption)
                            .foregroundStyle(SteamStyle.secondaryText)
                    }
                    .frame(width: 82)

                    Rectangle()
                        .fill(SteamStyle.divider)
                        .frame(width: 1, height: 54)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(review.description)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(SteamStyle.green)

                        Text("\(review.totalReviews.formatted()) 条用户评价")
                            .font(.caption)
                            .foregroundStyle(SteamStyle.secondaryText)
                    }

                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SteamStyle.surfaceLight, in: RoundedRectangle(cornerRadius: 14))
            } else if let reviewError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(reviewError)
                        .font(.caption)
                        .foregroundStyle(SteamStyle.secondaryText)

                    Button("重新加载评价") {
                        Task { await loadReviews() }
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(SteamStyle.steamBlue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(SteamStyle.surface, in: RoundedRectangle(cornerRadius: 14))
            } else if !loadingReviews {
                Text("暂无可显示的评价信息")
                    .font(.subheadline)
                    .foregroundStyle(SteamStyle.secondaryText)
            }
        }
        .padding(.horizontal, 16)
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("游戏简介", icon: "text.alignleft")

            if loadingDetails {
                ProgressView()
                    .tint(SteamStyle.steamBlue)
            } else if let details {
                Text(details.shortDescription)
                    .font(.subheadline)
                    .foregroundStyle(SteamStyle.secondaryText)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("暂时无法加载游戏简介。")
                    .font(.subheadline)
                    .foregroundStyle(SteamStyle.secondaryText)
            }
        }
        .padding(16)
        .background(SteamStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("游戏信息", icon: "info.circle.fill")

            if let details {
                if !details.developers.isEmpty {
                    infoRow(
                        label: "开发商",
                        value: details.developers.joined(separator: "、")
                    )
                }

                if !details.genres.isEmpty {
                    infoRow(
                        label: "游戏类型",
                        value: details.genres.joined(separator: "、")
                    )
                }

                if details.developers.isEmpty && details.genres.isEmpty {
                    Text("暂无更多信息")
                        .font(.subheadline)
                        .foregroundStyle(SteamStyle.secondaryText)
                }
            } else if loadingDetails {
                ProgressView().tint(SteamStyle.steamBlue)
            } else {
                Text("游戏信息暂不可用")
                    .font(.subheadline)
                    .foregroundStyle(SteamStyle.secondaryText)
            }
        }
        .padding(16)
        .background(SteamStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private var screenshotsSection: some View {
        Group {
            if let details, !details.screenshots.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("游戏截图", icon: "photo.on.rectangle.angled")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(
                                Array(details.screenshots.prefix(8).enumerated()),
                                id: \.offset
                            ) { _, url in
                                AsyncImage(url: url) { phase in
                                    if let image = phase.image {
                                        image
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        ZStack {
                                            SteamStyle.surfaceLight
                                            ProgressView().tint(SteamStyle.steamBlue)
                                        }
                                    }
                                }
                                .frame(width: 270, height: 152)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var claimButton: some View {
        Button {
            openURL(game.storeURL)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 18, weight: .bold))

                Text("确认领取")
                    .font(.system(size: 17, weight: .bold))

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.16, green: 0.48, blue: 0.76),
                        Color(red: 0.20, green: 0.36, blue: 0.65)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 15)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(SteamStyle.steamBlue)

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(SteamStyle.secondaryText)
                .frame(width: 68, alignment: .leading)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private func loadDetails() async {
        loadingDetails = true
        detailsError = nil

        do {
            details = try await SteamAPI.fetchDetails(appID: game.id)
        } catch {
            detailsError = error.localizedDescription
        }

        loadingDetails = false
    }

    @MainActor
    private func loadReviews() async {
        loadingReviews = true
        reviewError = nil

        do {
            review = try await SteamAPI.fetchReviews(appID: game.id)
        } catch {
            reviewError = error.localizedDescription
        }

        loadingReviews = false
    }
}

#Preview {
    ContentView()
}
