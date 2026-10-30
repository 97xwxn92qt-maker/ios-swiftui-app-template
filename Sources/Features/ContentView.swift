import SwiftUI
import Combine
import Foundation
import UIKit
import Security
import PhotosUI

// MARK: - 样式

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

private enum EpicStyle {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.065)
    static let panel = Color(red: 0.105, green: 0.105, blue: 0.12)
    static let panelLight = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.62)
    static let border = Color.white.opacity(0.10)
}

// MARK: - Steam 模型

enum SteamAppKind: String {
    case game = "游戏本体"
    case dlc = "DLC 内容"
    case other = "其他内容"
}

struct SteamGame: Identifiable, Hashable {
    let id: Int
    var name: String
    var imageURL: String
    var originalPrice: String
    var kind: SteamAppKind

    var storeURL: URL {
        URL(string: "https://store.steampowered.com/app/\(id)/")!
    }

    var isDLC: Bool { kind == .dlc }

    static func == (lhs: SteamGame, rhs: SteamGame) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// 新增：Steam 免费游戏

struct SteamFreeGame: Identifiable, Hashable {
    let id: Int
    let name: String
    let imageURL: String
    let releaseDate: Date?

    var storeURL: URL {
        URL(string: "https://store.steampowered.com/app/\(id)/")!
    }

    static func == (lhs: SteamFreeGame, rhs: SteamFreeGame) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// Steam 即将推出游戏（计划发行日期来自 Steam 商店）
struct SteamUpcomingGame: Identifiable, Hashable {
    let id: Int
    let name: String
    let imageURL: String
    let releaseText: String
    let releaseDate: Date?

    var storeURL: URL { URL(string: "https://store.steampowered.com/app/\(id)/")! }
}

// 新增：Steam 搜索结果

struct SteamSearchGame: Identifiable, Hashable {
    let id: Int
    let name: String
    let imageURL: String

    var storeURL: URL {
        URL(string: "https://store.steampowered.com/app/\(id)/")!
    }

    static func == (lhs: SteamSearchGame, rhs: SteamSearchGame) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Epic 模型

struct EpicGame: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let imageURL: String
    let originalPrice: String
    let endDate: Date?
    let storeURL: URL

    static func == (lhs: EpicGame, rhs: EpicGame) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - 网络请求

private enum StoreHTTP {
    static func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "StoreHTTP",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "无法获取服务器响应"]
            )
        }

        guard (200...299).contains(http.statusCode) else {
            throw NSError(
                domain: "StoreHTTP",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "服务器返回 HTTP \(http.statusCode)"]
            )
        }

        return data
    }

    static func json(from url: URL) async throws -> Any {
        let data = try await data(from: url)

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw NSError(
                domain: "StoreHTTP",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "服务器返回的数据无法解析"]
            )
        }
    }
}

// MARK: - Steam API

enum SteamAPI {
    private static let countryCode = "sg"
    private static let language = "schinese"

    private static func requestJSON(_ url: URL) async throws -> Any {
        try await StoreHTTP.json(from: url)
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func makeURL(
        _ address: String,
        queryItems: [URLQueryItem]
    ) -> URL? {
        guard var components = URLComponents(string: address) else {
            return nil
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }

    private static func imageFromItem(_ item: [String: Any]) -> String {
        let direct = string(item["tiny_image"])
        if direct.hasPrefix("https://") { return direct }

        let logo = string(item["logo"])
        if logo.hasPrefix("https://") { return logo }

        return ""
    }

    // 原有功能：限时免费游戏和 DLC

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

        let root = dictionary(try await requestJSON(url))
        var candidates: [(id: Int, name: String)] = []
        var seen = Set<Int>()

        func addCandidate(_ id: Int, _ name: String) {
            guard id > 0, !seen.contains(id) else { return }
            seen.insert(id)
            candidates.append((id, name))
        }

        if let items = root["items"] as? [[String: Any]] {
            for item in items {
                let id = intValue(item["id"]) != 0
                    ? intValue(item["id"])
                    : intValue(item["appid"])
                addCandidate(id, string(item["name"]))
            }
        }

        let html = string(root["results_html"])

        if !html.isEmpty {
            let patterns = [
                #"/app/(\d+)(?:/|")"#,
                #"data-ds-appid="(\d+)""#
            ]

            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    continue
                }

                let nsHTML = html as NSString
                let matches = regex.matches(
                    in: html,
                    range: NSRange(location: 0, length: nsHTML.length)
                )

                for match in matches where match.numberOfRanges > 1 {
                    let idString = nsHTML.substring(with: match.range(at: 1))
                    if let id = Int(idString) {
                        addCandidate(id, extractName(
                            around: match.range.location,
                            html: html
                        ))
                    }
                }
            }
        }

        if let items = root["items"] as? [[String: Any]] {
            for item in items {
                let logo = string(item["logo"])

                for pattern in [#"/steam/apps/(\d+)/"#, #"/apps/(\d+)/"#] {
                    guard let regex = try? NSRegularExpression(pattern: pattern) else {
                        continue
                    }

                    let nsLogo = logo as NSString
                    let range = NSRange(location: 0, length: nsLogo.length)

                    if let match = regex.firstMatch(in: logo, range: range),
                       match.numberOfRanges > 1,
                       let id = Int(nsLogo.substring(with: match.range(at: 1))) {
                        addCandidate(id, string(item["name"]))
                    }
                }
            }
        }

        guard !candidates.isEmpty else {
            throw NSError(
                domain: "SteamAPI",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "没有解析到 Steam 商品，请稍后重试"]
            )
        }

        var games: [SteamGame] = []

        for candidate in candidates {
            do {
                guard let detailURL = makeURL(
                    "https://store.steampowered.com/api/appdetails",
                    queryItems: [
                        URLQueryItem(name: "appids", value: "\(candidate.id)"),
                        URLQueryItem(name: "cc", value: countryCode),
                        URLQueryItem(name: "l", value: language)
                    ]
                ) else { continue }

                let detailJSON = try await requestJSON(detailURL)
                let appRoot = dictionary(dictionary(detailJSON)["\(candidate.id)"])

                guard appRoot["success"] as? Bool == true else { continue }

                let data = dictionary(appRoot["data"])
                let name = string(data["name"])
                let appType = string(data["type"]).lowercased()
                let isDLC = appType == "dlc"

                guard appType == "game" || isDLC else { continue }

                let packageGroups = data["package_groups"] as? [[String: Any]] ?? []
                var isLimitedFree = false
                var originalPriceCents: Int?

                for group in packageGroups {
                    let subs = group["subs"] as? [[String: Any]] ?? []

                    for sub in subs {
                        let optionText = string(sub["option_text"]).lowercased()
                        let discountPrice = intValue(sub["price_in_cents_with_discount"])
                        let originalCents = intValue(sub["price_in_cents_without_discount"])

                        let matches =
                            optionText.contains("limited free promotional package")
                            || optionText.contains("limited-time free")
                            || optionText.contains("limited time free")
                            || optionText.contains("限时免费")
                            || optionText.contains("限时免费促销")

                        if matches && discountPrice == 0 {
                            isLimitedFree = true
                            originalPriceCents = originalCents
                            break
                        }
                    }

                    if isLimitedFree { break }
                }

                guard isLimitedFree else { continue }

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
                        imageURL: string(data["header_image"]),
                        originalPrice: priceText,
                        kind: isDLC ? .dlc : .game
                    )
                )
            } catch {
                continue
            }
        }

        return games.sorted {
            if $0.isDLC != $1.isDLC { return !$0.isDLC }
            return $0.name.localizedCompare($1.name) == .orderedAscending
        }
    }

    // 新增功能：获取当前免费游戏目录

    static func fetchFreeToPlayGames() async throws -> [SteamFreeGame] {
        // 优先读取 Steam 官方首页的“热门免费游玩”分类，避免逐个 appdetails 请求导致整页空白。
        guard let url = makeURL(
            "https://store.steampowered.com/api/featuredcategories/",
            queryItems: [
                URLQueryItem(name: "cc", value: countryCode),
                URLQueryItem(name: "l", value: language)
            ]
        ) else { throw URLError(.badURL) }

        let root = dictionary(try await requestJSON(url))
        let topFree = dictionary(root["top free"])
        let items = topFree["items"] as? [[String: Any]] ?? []
        var results: [SteamFreeGame] = []
        var seen = Set<Int>()
        for item in items {
            let id = intValue(item["id"])
            let name = string(item["name"])
            guard id > 0, !name.isEmpty, seen.insert(id).inserted else { continue }
            let image = string(item["header_image"]).isEmpty
                ? (string(item["large_capsule_image"]).isEmpty
                    ? string(item["small_capsule_image"]) : string(item["large_capsule_image"]))
                : string(item["header_image"])
            results.append(SteamFreeGame(id: id, name: name, imageURL: image, releaseDate: nil))
        }
        if !results.isEmpty { return results }

        // 备用：免费游戏目录。解析 items 与 results_html 中的 appid。
        guard let fallbackURL = makeURL(
            "https://store.steampowered.com/search/results/",
            queryItems: [
                URLQueryItem(name: "category1", value: "998"),
                URLQueryItem(name: "maxprice", value: "free"),
                URLQueryItem(name: "json", value: "1"),
                URLQueryItem(name: "count", value: "50"),
                URLQueryItem(name: "cc", value: countryCode),
                URLQueryItem(name: "l", value: language)
            ]
        ) else { throw URLError(.badURL) }
        let fallbackRoot = dictionary(try await requestJSON(fallbackURL))
        let fallbackItems = fallbackRoot["items"] as? [[String: Any]] ?? []
        for item in fallbackItems {
            let id = intValue(item["id"]) != 0 ? intValue(item["id"]) : intValue(item["appid"])
            let name = string(item["name"])
            guard id > 0, !name.isEmpty, seen.insert(id).inserted else { continue }
            results.append(SteamFreeGame(id: id, name: name, imageURL: imageFromItem(item), releaseDate: nil))
        }
        if results.isEmpty {
            throw NSError(domain: "SteamAPI", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Steam 暂时没有返回免费游戏数据，请稍后刷新。"])
        }
        return results
    }

    // 新增功能：Steam 商店搜索

    static func searchGames(_ keyword: String) async throws -> [SteamSearchGame] {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        // Steam 官方商店搜索 JSON API；不再依赖 search/results 的 HTML 包装结构。
        guard let url = makeURL(
            "https://store.steampowered.com/api/storesearch/",
            queryItems: [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "l", value: language),
                URLQueryItem(name: "cc", value: countryCode)
            ]
        ) else { throw URLError(.badURL) }

        let root = dictionary(try await requestJSON(url))
        let items = root["items"] as? [[String: Any]] ?? []
        var results: [SteamSearchGame] = []
        var seen = Set<Int>()
        for item in items {
            let id = intValue(item["id"])
            let name = string(item["name"])
            guard id > 0, !name.isEmpty, seen.insert(id).inserted else { continue }
            let image = string(item["tiny_image"]).isEmpty
                ? "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)/header.jpg"
                : string(item["tiny_image"])
            results.append(SteamSearchGame(id: id, name: name, imageURL: image))
        }
        return results
    }

    // Steam 官方 Upcoming 搜索目录：仅展示未来约 60 天内有明确日期的商品。
    static func fetchUpcomingGames() async throws -> [SteamUpcomingGame] {
        guard let url = makeURL(
            "https://store.steampowered.com/search/results/",
            queryItems: [
                URLQueryItem(name: "filter", value: "comingsoon"),
                URLQueryItem(name: "json", value: "1"),
                URLQueryItem(name: "count", value: "100"),
                URLQueryItem(name: "cc", value: countryCode),
                URLQueryItem(name: "l", value: language)
            ]
        ) else { throw URLError(.badURL) }

        let root = dictionary(try await requestJSON(url))
        let items = root["items"] as? [[String: Any]] ?? []
        var games: [SteamUpcomingGame] = []
        var seen = Set<Int>()
        let now = Date()
        let upperBound = Calendar.current.date(byAdding: .day, value: 60, to: now) ?? now

        for item in items {
            let id = intValue(item["id"])
            let name = string(item["name"])
            guard id > 0, !name.isEmpty, seen.insert(id).inserted else { continue }
            let releaseText = string(item["release_date"])
            guard let date = parseSteamReleaseDate(releaseText), date >= Calendar.current.startOfDay(for: now), date <= upperBound else { continue }
            let image = imageFromItem(item).isEmpty
                ? "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(id)/header.jpg"
                : imageFromItem(item)
            games.append(SteamUpcomingGame(id: id, name: name, imageURL: image, releaseText: releaseText, releaseDate: date))
        }
        return games.sorted { ($0.releaseDate ?? .distantFuture) < ($1.releaseDate ?? .distantFuture) }
    }

    private static func parseSteamReleaseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }

        let formats = [
            "d MMM, yyyy",
            "MMM d, yyyy",
            "yyyy年M月d日",
            "yyyy-MM-dd",
            "M月d日, yyyy"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format

            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private static func extractName(around location: Int, html: String) -> String {
        let start = max(0, location - 500)
        let end = min(html.count, location + 1000)

        let lowerIndex = html.index(html.startIndex, offsetBy: start)
        let upperIndex = html.index(html.startIndex, offsetBy: end)
        let fragment = String(html[lowerIndex..<upperIndex])

        guard let regex = try? NSRegularExpression(
            pattern: #"class="title">([^<]+)</span>"#
        ) else { return "" }

        let nsFragment = fragment as NSString
        let range = NSRange(location: 0, length: nsFragment.length)

        guard let match = regex.firstMatch(in: fragment, range: range),
              match.numberOfRanges > 1 else { return "" }

        return nsFragment.substring(with: match.range(at: 1))
    }

    private static func formatSGD(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(
            .currency(code: "SGD").locale(Locale(identifier: "en_SG"))
        )
    }
}

// MARK: - Epic API

enum EpicAPI {
    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    static func fetchFreeGames() async throws -> [EpicGame] {
        guard let url = URL(
            string: "https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions?locale=zh-CN&country=SG&allowCountries=SG"
        ) else {
            throw URLError(.badURL)
        }

        let root = dictionary(try await StoreHTTP.json(from: url))
        let data = dictionary(root["data"])
        let catalog = dictionary(data["Catalog"])
        let elements = catalog["searchStore"] as? [String: Any]
        let products = elements?["elements"] as? [[String: Any]] ?? []

        var result: [EpicGame] = []
        var seen = Set<String>()

        for product in products {
            let id = string(product["id"])
            let title = string(product["title"])

            guard !id.isEmpty, !title.isEmpty, !seen.contains(id) else {
                continue
            }

            let price = dictionary(product["price"])
            let totalPrice = dictionary(price["totalPrice"])
            let discountPrice = totalPrice["discountPrice"] as? Int ?? -1

            guard discountPrice == 0 else { continue }

            let promotions = dictionary(product["promotions"])
            let activePromotions =
                promotions["promotionalOffers"] as? [[String: Any]] ?? []

            var endDate: Date?

            for promotionGroup in activePromotions {
                let offers =
                    promotionGroup["promotionalOffers"] as? [[String: Any]] ?? []

                for offer in offers {
                    let start = parseDate(string(offer["startDate"]))
                    let end = parseDate(string(offer["endDate"]))

                    if let end, end > Date(),
                       start == nil || (start ?? .distantPast) <= Date() {
                        endDate = end
                        break
                    }
                }

                if endDate != nil { break }
            }

            guard let validEndDate = endDate else { continue }

            let keyImages = product["keyImages"] as? [[String: Any]] ?? []
            let preferredTypes = [
                "OfferImageWide",
                "DieselStoreFrontWide",
                "OfferImageTall",
                "Thumbnail",
                "ProductLogo"
            ]

            let imageURL = preferredTypes.lazy.compactMap { wanted in
                keyImages.first(where: {
                    string($0["type"]) == wanted
                }).map {
                    string($0["url"])
                }
            }.first(where: {
                $0.hasPrefix("https://")
            }) ?? ""

            let storeURL = makeStoreURL(product)

            let originalPrice: String
            if let original = totalPrice["originalPrice"] as? Int,
               original > 0 {
                let currencyCode = string(totalPrice["currencyCode"])
                originalPrice = formatPrice(
                    original,
                    currencyCode: currencyCode.isEmpty ? "SGD" : currencyCode
                )
            } else {
                originalPrice = "免费"
            }

            result.append(
                EpicGame(
                    id: id,
                    name: title,
                    description: string(product["description"]),
                    imageURL: imageURL,
                    originalPrice: originalPrice,
                    endDate: validEndDate,
                    storeURL: storeURL
                )
            )

            seen.insert(id)
        }

        return result.sorted {
            ($0.endDate ?? .distantFuture) < ($1.endDate ?? .distantFuture)
        }
    }

    // Epic 商品链接修复

    private static func makeStoreURL(_ product: [String: Any]) -> URL {
        let fallbackURL = URL(
            string: "https://store.epicgames.com/zh-CN/free-games"
        )!

        let catalogNs = dictionary(product["catalogNs"])
        let mappings = catalogNs["mappings"] as? [[String: Any]] ?? []
        let offerMappings = product["offerMappings"] as? [[String: Any]] ?? []

        let mappingCandidates = offerMappings + mappings
        var rawSlug = ""

        for mapping in mappingCandidates {
            let pageSlug = string(mapping["pageSlug"])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !pageSlug.isEmpty else { continue }

            let pageType = string(mapping["pageType"]).lowercased()

            if pageType.isEmpty || pageType == "product" || pageType == "producthome" {
                rawSlug = pageSlug
                break
            }
        }

        if rawSlug.isEmpty { rawSlug = string(product["productSlug"]) }
        if rawSlug.isEmpty { rawSlug = string(product["urlSlug"]) }

        guard !rawSlug.isEmpty else { return fallbackURL }

        if let suppliedURL = URL(string: rawSlug),
           let scheme = suppliedURL.scheme?.lowercased(),
           scheme == "https" || scheme == "http" {
            let host = suppliedURL.host?.lowercased() ?? ""

            if host == "store.epicgames.com" || host.hasSuffix(".epicgames.com") {
                return suppliedURL
            }
            return fallbackURL
        }

        let cleanedSlug = rawSlug
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !cleanedSlug.isEmpty else { return fallbackURL }

        let segments = cleanedSlug.split(separator: "/")

        if segments.count >= 2 {
            let first = String(segments[0]).lowercased()

            if first == "p" || first == "bundles" {
                let path = segments.map(String.init).joined(separator: "/")
                if let url = URL(
                    string: "https://store.epicgames.com/zh-CN/\(path)"
                ) {
                    return url
                }
            }
        }

        let offerType = string(product["offerType"]).uppercased()
        let path = offerType == "BUNDLE" ? "bundles" : "p"

        guard let encodedSlug = cleanedSlug.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ),
        let url = URL(
            string: "https://store.epicgames.com/zh-CN/\(path)/\(encodedSlug)"
        ) else {
            return fallbackURL
        }

        return url
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = formatter.date(from: value) { return date }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func formatPrice(_ cents: Int, currencyCode: String) -> String {
        let locale = Locale(
            identifier: currencyCode == "SGD" ? "en_SG" : "en_US"
        )

        return (Double(cents) / 100).formatted(
            .currency(code: currencyCode).locale(locale)
        )
    }
}

// MARK: - 数据管理

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadGames() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            games = try await SteamAPI.fetchFreeGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class SteamFreeStore: ObservableObject {
    @Published var games: [SteamFreeGame] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    var recentGames: [SteamFreeGame] {
        let limit = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        return games.filter {
            guard let date = $0.releaseDate else { return false }
            return date >= limit
        }
    }

    var historicalGames: [SteamFreeGame] {
        let limit = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        return games.filter {
            guard let date = $0.releaseDate else { return true }
            return date < limit
        }
    }

    func loadGames() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            games = try await SteamAPI.fetchFreeToPlayGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class SteamUpcomingStore: ObservableObject {
    @Published var games: [SteamUpcomingGame] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadGames() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            games = try await SteamAPI.fetchUpcomingGames()
            if games.isEmpty { errorMessage = "未来 60 天内暂时没有解析到明确发行日期的游戏，请稍后刷新。" }
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
final class SteamSearchStore: ObservableObject {
    @Published var games: [SteamSearchGame] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func search(_ keyword: String) async {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            games = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        games = []
        defer { isLoading = false }

        do {
            games = try await SteamAPI.searchGames(term)
            if games.isEmpty {
                errorMessage = "没有找到相关游戏，试试其他关键词"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class EpicStore: ObservableObject {
    @Published var games: [EpicGame] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadGames() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            games = try await EpicAPI.fetchFreeGames()
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
                color: .black.opacity(configuration.isPressed ? 0.08 : 0.24),
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

// MARK: - 平台入口

struct ContentView: View {
    @State private var selectedPlatform = 0
    @StateObject private var accountStore = AppAccountStore()
    @AppStorage("app.appearance") private var appearance = "dark"

    var body: some View {
        TabView(selection: $selectedPlatform) {
            SteamHomeView()
                .tabItem {
                    Image(systemName: "gamecontroller.fill")
                    Text("Steam")
                }
                .tag(0)

            EpicHomeView()
                .tabItem {
                    Image(systemName: "e.square.fill")
                    Text("Epic 限免")
                }
                .tag(1)

            AccountHomeView(account: accountStore)
                .tabItem {
                    Image(systemName: "person.crop.circle.fill")
                    Text("我的")
                }
                .tag(2)
        }
        .environmentObject(accountStore)
        .tint(selectedPlatform == 0 ? SteamStyle.cyan : .white)
        .preferredColorScheme(appearance == "system" ? nil : (appearance == "light" ? .light : .dark))
        .onOpenURL { url in
            Task { await accountStore.handleAuthCallback(url) }
        }
    }
}

// MARK: - Steam 首页

private struct SteamHomeView: View {
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
                SteamStyle.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        header

                        // 新增入口
                        featureEntry

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
        }
        .task {
            if store.games.isEmpty {
                await store.loadGames()
            }
        }
    }

    private var featureEntry: some View {
        VStack(spacing: 11) {
            NavigationLink {
                SteamUpcomingHomeView()
            } label: {
                featureRow(
                    icon: "gamecontroller.fill",
                    title: "Steam 即将推出",
                    subtitle: "查看未来两个月计划发行的游戏",
                    color: SteamStyle.green
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                SteamSearchView()
            } label: {
                featureRow(
                    icon: "magnifyingglass",
                    title: "搜索 Steam 游戏",
                    subtitle: "输入游戏名称，查找商店商品",
                    color: SteamStyle.cyan
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func featureRow(
        icon: String,
        title: String,
        subtitle: String,
        color: Color
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 43, height: 43)
                .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(SteamStyle.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(SteamStyle.secondary)
        }
        .padding(13)
        .background(
            SteamStyle.card,
            in: RoundedRectangle(cornerRadius: 15)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(SteamStyle.border, lineWidth: 1)
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
                                Color(red: 0.16, green: 0.37, blue: 0.75)
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
                Text("Steam Games")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.white)

                Text("发现 Steam 限时免费好游戏")
                    .font(.system(size: 12))
                    .foregroundStyle(SteamStyle.secondary)
            }

            Spacer(minLength: 0)

            Button {
                Task { await store.loadGames() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SteamStyle.cyan)
                    .frame(width: 42, height: 42)
                    .background(SteamStyle.cardLight, in: Circle())
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
                colors: [SteamStyle.cardLight, SteamStyle.card],
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
                    .background(SteamStyle.blue.opacity(0.15), in: Capsule())
            }

            LazyVStack(spacing: 15) {
                ForEach(items) { game in
                    GameCard(game: game)
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
                Task { await store.loadGames() }
            } label: {
                Label("重新加载", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(SteamStyle.blue, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 20))
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
// MARK: - Steam 限时免费游戏卡片

private struct GameCard: View {
    let game: SteamGame
    @EnvironmentObject private var account: AppAccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                AsyncImage(url: URL(string: game.imageURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        imagePlaceholder
                    @unknown default:
                        imagePlaceholder
                    }
                }
                .frame(width: 118, height: 74)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 7) {
                    Text(game.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 5) {
                        Image(systemName: game.isDLC
                              ? "square.stack.3d.up.fill"
                              : "gamecontroller.fill")
                        Text(game.kind.rawValue)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(game.isDLC ? SteamStyle.cyan : SteamStyle.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        (game.isDLC ? SteamStyle.cyan : SteamStyle.blue).opacity(0.12),
                        in: Capsule()
                    )

                    Text("原价参考：\(game.originalPrice)")
                        .font(.system(size: 10))
                        .foregroundStyle(SteamStyle.secondary)
                        .lineLimit(1)
                }

                VStack(spacing: 10) {
                    Button {
                        Task { await account.toggleFavorite(store: "steam", appID: String(game.id), name: game.name, imageURL: game.imageURL, storeURL: game.storeURL.absoluteString) }
                    } label: {
                        Image(systemName: account.isFavorite(store: "steam", appID: String(game.id)) ? "heart.fill" : "heart")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(account.isFavorite(store: "steam", appID: String(game.id)) ? .pink : .white)
                            .frame(width: 32, height: 32)
                            .background(Color.white.opacity(0.09), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Image(systemName: "gift.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(SteamStyle.green)

                    Text("免费")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SteamStyle.green)
                }
                .frame(width: 34)
            }

            Divider()
                .overlay(SteamStyle.border)
                .padding(.vertical, 11)

            Button {
                UIApplication.shared.open(game.storeURL)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 12, weight: .bold))

                    Text("确认领取")
                        .font(.system(size: 13, weight: .bold))

                    Spacer()

                    Text("前往 Steam")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.12, green: 0.48, blue: 0.82),
                            Color(red: 0.12, green: 0.35, blue: 0.66)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            .buttonStyle(SteamCardButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [SteamStyle.cardLight, SteamStyle.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(SteamStyle.border, lineWidth: 1)
        }
    }

    private var imagePlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [SteamStyle.cardLight, SteamStyle.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 25))
                .foregroundStyle(SteamStyle.blue.opacity(0.8))
        }
        .frame(width: 118, height: 74)
    }
}

// MARK: - Steam 即将推出页面

private struct SteamUpcomingHomeView: View {
    @StateObject private var store = SteamUpcomingStore()
    @State private var selectedRange = 0

    private var displayedGames: [SteamUpcomingGame] {
        guard selectedRange == 1 else { return store.games }
        return store.games.filter {
            guard let date = $0.releaseDate else { return false }
            return Calendar.current.isDate(date, equalTo: Date(), toGranularity: .month)
        }
    }

    var body: some View {
        ZStack {
            SteamStyle.background.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header
                    Picker("发行范围", selection: $selectedRange) {
                        Text("未来 60 天").tag(0)
                        Text("本月发行").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .tint(SteamStyle.cyan)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("即将登陆 Steam")
                                .font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                            Text("按预计发行日期排序 · 最多展示未来 60 天")
                                .font(.system(size: 11)).foregroundStyle(SteamStyle.secondary)
                        }
                        Spacer()
                        Text("\(displayedGames.count) 款")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(SteamStyle.cyan)
                    }

                    if store.isLoading && store.games.isEmpty {
                        VStack(spacing: 12) { ProgressView().tint(SteamStyle.cyan); Text("正在获取 Steam 即将推出的游戏…").foregroundStyle(SteamStyle.secondary) }.padding(.vertical, 40)
                    } else if let error = store.errorMessage, store.games.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 32)).foregroundStyle(SteamStyle.cyan)
                            Text(error).font(.system(size: 13)).foregroundStyle(SteamStyle.secondary).multilineTextAlignment(.center)
                            Button("重新加载") { Task { await store.loadGames() } }.foregroundStyle(SteamStyle.cyan)
                        }.frame(maxWidth: .infinity).padding(24).background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 16))
                    } else if displayedGames.isEmpty {
                        Text("这个时间范围内暂无已确认发行日期的游戏").font(.system(size: 13)).foregroundStyle(SteamStyle.secondary).padding(.vertical, 35)
                    } else {
                        LazyVStack(spacing: 13) {
                            ForEach(displayedGames) { game in
                                SteamUpcomingGameCard(game: game)
                            }
                        }
                    }
                    Text("发行日期以 Steam 商店页面为准；Steam 可能随时调整游戏发行计划。未确定日期的商品暂不显示。")
                        .font(.system(size: 10)).foregroundStyle(SteamStyle.secondary).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 30)
            }
            .refreshable { await store.loadGames() }
        }
        .navigationTitle("Steam 即将推出").navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { if store.games.isEmpty { await store.loadGames() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock").font(.system(size: 28, weight: .bold)).foregroundStyle(SteamStyle.cyan)
                .frame(width: 56, height: 56).background(SteamStyle.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text("COMING SOON").font(.system(size: 10, weight: .black)).tracking(2).foregroundStyle(SteamStyle.cyan)
                Text("近期即将上架").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                Text("提前发现值得关注的新游戏").font(.system(size: 11)).foregroundStyle(SteamStyle.secondary)
            }
            Spacer()
            Button { Task { await store.loadGames() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .bold)).foregroundStyle(SteamStyle.cyan)
                    .frame(width: 42, height: 42).background(SteamStyle.cardLight, in: Circle())
            }.buttonStyle(.plain)
        }
    }
}

private struct SteamUpcomingGameCard: View {
    let game: SteamUpcomingGame
    private var dateLabel: String {
        guard let date = game.releaseDate else { return game.releaseText }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: game.imageURL)) { phase in
                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                    else { RoundedRectangle(cornerRadius: 10).fill(SteamStyle.cardLight).overlay(Image(systemName: "gamecontroller.fill").foregroundStyle(SteamStyle.secondary)) }
                }
                .frame(width: 116, height: 70).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.name).font(.system(size: 14, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                    Label(dateLabel, systemImage: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(SteamStyle.cyan)
                    Text("预计发行 · Steam 商店").font(.system(size: 10)).foregroundStyle(SteamStyle.secondary)
                }
                Spacer(minLength: 0)
            }
            Button { UIApplication.shared.open(game.storeURL) } label: {
                HStack { Image(systemName: "arrow.up.right.square"); Text("查看 Steam 页面"); Spacer(); Text("Steam").foregroundStyle(.white.opacity(0.75)) }
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 14).frame(height: 42)
                    .background(SteamStyle.blue, in: RoundedRectangle(cornerRadius: 11))
            }.buttonStyle(.plain)
        }.padding(13).background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 17)).overlay(RoundedRectangle(cornerRadius: 17).stroke(SteamStyle.border, lineWidth: 1))
    }
}

// MARK: - Steam 搜索页面

private struct SteamSearchView: View {
    @StateObject private var store = SteamSearchStore()
    @State private var keyword = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ZStack {
            SteamStyle.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    searchHeader
                    searchBar

                    if store.isLoading {
                        ProgressView()
                            .tint(SteamStyle.cyan)
                            .padding(.top, 40)
                    } else if let error = store.errorMessage {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 30))
                                .foregroundStyle(SteamStyle.cyan)

                            Text(error)
                                .font(.system(size: 13))
                                .foregroundStyle(SteamStyle.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 45)
                    } else if !store.games.isEmpty {
                        HStack {
                            Text("搜索结果")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)

                            Spacer()

                            Text("\(store.games.count) 款")
                                .font(.system(size: 11))
                                .foregroundStyle(SteamStyle.secondary)
                        }

                        LazyVStack(spacing: 12) {
                            ForEach(store.games) { game in
                                SteamSearchGameCard(game: game)
                            }
                        }
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "gamecontroller")
                                .font(.system(size: 38))
                                .foregroundStyle(SteamStyle.cyan)

                            Text("搜索你想玩的 Steam 游戏")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)

                            Text("输入游戏名称，点击搜索查看商品")
                                .font(.system(size: 12))
                                .foregroundStyle(SteamStyle.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 55)
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 30)
            }
        }
        .navigationTitle("搜索 Steam 游戏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STEAM SEARCH")
                .font(.system(size: 11, weight: .black))
                .tracking(2)
                .foregroundStyle(SteamStyle.cyan)

            Text("寻找下一款游戏")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(.white)

            Text("搜索 Steam 商店中的游戏本体")
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(SteamStyle.secondary)

            TextField("输入游戏名称", text: $keyword)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .focused($isInputFocused)
                .submitLabel(.search)
                .onSubmit {
                    performSearch()
                }

            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    store.games = []
                    store.errorMessage = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SteamStyle.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                performSearch()
            } label: {
                Text("搜索")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(SteamStyle.blue, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(SteamStyle.cardLight, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(SteamStyle.border, lineWidth: 1)
        }
    }

    private func performSearch() {
        isInputFocused = false
        Task {
            await store.search(keyword)
        }
    }
}

// MARK: - 搜索结果卡片

private struct SteamSearchGameCard: View {
    let game: SteamSearchGame

    var body: some View {
        Button {
            UIApplication.shared.open(game.storeURL)
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: URL(string: game.imageURL)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            SteamStyle.cardLight
                            Image(systemName: "gamecontroller.fill")
                                .foregroundStyle(SteamStyle.cyan)
                        }
                    }
                }
                .frame(width: 105, height: 65)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 6) {
                    Text(game.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text("Steam 商品 · App ID: \(game.id)")
                        .font(.system(size: 10))
                        .foregroundStyle(SteamStyle.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SteamStyle.cyan)
            }
            .padding(11)
            .background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 13))
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(SteamStyle.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Epic 限免页面

private struct EpicHomeView: View {
    @StateObject private var store = EpicStore()

    var body: some View {
        NavigationStack {
            ZStack {
                EpicStyle.background.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        heroPanel

                        if store.isLoading && store.games.isEmpty {
                            loadingView
                        } else if let error = store.errorMessage,
                                  store.games.isEmpty {
                            errorView(error)
                        } else if store.games.isEmpty {
                            emptyView
                        } else {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("本周免费游戏")
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundStyle(.white)

                                    Spacer()

                                    Text("\(store.games.count) 款")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(EpicStyle.secondary)
                                }

                                ForEach(store.games) { game in
                                    EpicGameCard(game: game)
                                }
                            }
                        }

                        Text("数据来自 Epic Games Store · 实际价格、地区资格及截止时间以商店页面为准")
                            .font(.system(size: 10))
                            .foregroundStyle(EpicStyle.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 32)
                }
                .refreshable {
                    await store.loadGames()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            if store.games.isEmpty {
                await store.loadGames()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                    .frame(width: 44, height: 44)

                Image(systemName: "e.square.fill")
                    .font(.system(size: 28, weight: .black))
                    .foregroundStyle(Color.black)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("EPIC GAMES")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.white)

                Text("STORE · FREE GAMES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.6)
                    .foregroundStyle(EpicStyle.secondary)
            }

            Spacer()

            Button {
                Task { await store.loadGames() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(EpicStyle.panelLight, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新 Epic 限免")
        }
    }

    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FREE GAMES")
                .font(.system(size: 11, weight: .black))
                .tracking(2.2)
                .foregroundStyle(Color.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 5))

            Text("免费游戏\n每周上新")
                .font(.system(size: 32, weight: .black))
                .foregroundStyle(.white)
                .lineSpacing(1)

            Text("领取后永久保留在你的 Epic 游戏库中（以商品具体领取规则为准）。")
                .font(.system(size: 12))
                .foregroundStyle(EpicStyle.secondary)
                .lineSpacing(4)

            HStack(spacing: 7) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 6, height: 6)

                Text("限时领取 · 截止时间实时计算")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.22, blue: 0.25),
                    Color(red: 0.09, green: 0.09, blue: 0.105)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(EpicStyle.border, lineWidth: 1)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 13) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.15)

            Text("正在获取 Epic 限免信息…")
                .font(.system(size: 13))
                .foregroundStyle(EpicStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("暂时无法获取 Epic 限免")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(EpicStyle.secondary)

            Button {
                Task { await store.loadGames() }
            } label: {
                Text("重新加载")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EpicStyle.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前没有检测到限时免费游戏")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)

            Text("也可能是 Epic 接口暂时没有返回可领取的促销信息。下拉刷新后再试。")
                .font(.system(size: 12))
                .foregroundStyle(EpicStyle.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EpicStyle.panel, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Epic 游戏卡片

private struct EpicGameCard: View {
    let game: EpicGame
    @EnvironmentObject private var account: AppAccountStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: game.imageURL)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        imagePlaceholder
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .clipped()

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            Task { await account.toggleFavorite(store: "epic", appID: game.id, name: game.name, imageURL: game.imageURL, storeURL: game.storeURL.absoluteString) }
                        } label: {
                            Image(systemName: account.isFavorite(store: "epic", appID: game.id) ? "heart.fill" : "heart")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(account.isFavorite(store: "epic", appID: game.id) ? .pink : .white)
                                .frame(width: 38, height: 38)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(12)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text("EPIC GAMES STORE")
                        .font(.system(size: 9, weight: .black))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.82))

                    Text(game.name)
                        .font(.system(size: 21, weight: .black))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                }
                .padding(16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("限时免费")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)

                        Text("原价：\(game.originalPrice)")
                            .font(.system(size: 11))
                            .foregroundStyle(EpicStyle.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("领取剩余时间")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(EpicStyle.secondary)

                        if let endDate = game.endDate {
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text(countdown(until: endDate, now: context.date))
                                    .font(.system(size: 15, weight: .black, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        endDate.timeIntervalSince(context.date) <= 3600
                                        ? Color.orange : Color.white
                                    )
                            }
                        } else {
                            Text("截止时间暂不可用")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(EpicStyle.secondary)
                        }
                    }
                }

                Button {
                    UIApplication.shared.open(game.storeURL)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gift.fill")
                        Text("立即领取")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .padding(10)
        .background(EpicStyle.panel, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(EpicStyle.border, lineWidth: 1)
        }
    }

    private var imagePlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [EpicStyle.panelLight, EpicStyle.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
    }

    private func countdown(until endDate: Date, now: Date) -> String {
        let seconds = max(0, Int(endDate.timeIntervalSince(now)))

        if seconds <= 0 { return "已截止" }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let days = hours / 24
        let remainingHours = hours % 24

        if days > 0 {
            return "\(days)天 \(remainingHours)小时 \(minutes)分"
        }

        return "\(hours)小时 \(minutes)分"
    }
}


// MARK: - App 自有账户（Supabase Auth REST）
// 在 Supabase 项目 Settings -> API 中填写 Project URL 与 anon/public key。
// anon key 可以放在客户端；绝对不要把 service_role key 放进 App。
private enum SupabaseConfig {
    static let projectURL = "https://eguihbrqafitmdhfimmn.supabase.co"
    static let anonKey = "sb_publishable_dbIbt7TjTyblrq9JghqI3w_WviPv32M"
    static let redirectURL = "xianmianlingqu://login-callback"
    static var isConfigured: Bool {
        !projectURL.contains("YOUR_PROJECT_ID") && !anonKey.contains("YOUR_SUPABASE")
    }
}

private struct SupabaseAuthResponse: Decodable {
    let access_token: String?
    let refresh_token: String?
    let user: SupabaseUser?
}

private struct SupabaseUser: Decodable {
    let id: String
    let email: String?
}

private struct CloudFavorite: Decodable, Identifiable {
    var store: String
    var app_id: String
    var game_name: String
    var image_url: String
    var store_url: String
    var id: String { "\\(store):\\(app_id)" }

    init(store: String, app_id: String, game_name: String, image_url: String, store_url: String) {
        self.store = store; self.app_id = app_id; self.game_name = game_name
        self.image_url = image_url; self.store_url = store_url
    }
}

@MainActor
private final class AppAccountStore: ObservableObject {
    @Published var email = ""
    @Published var isBusy = false
    @Published var message: String?
    @Published var isLoggedIn = false
    private let tokenKey = "app.supabase.access-token"
    @Published var favoriteKeys: Set<String> = []
    @Published var favoriteRecords: [CloudFavorite] = []
    @Published var needsLoginPrompt = false

    func isFavorite(store: String, appID: String) -> Bool {
        favoriteKeys.contains("\\(store):\\(appID)")
    }

    func loadFavorites() async {
        guard let token = readToken(), isLoggedIn else { return }
        guard let url = URL(string: SupabaseConfig.projectURL + "/rest/v1/game_favorites?select=store,app_id,game_name,image_url,store_url&order=created_at.desc") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let rows = try JSONDecoder().decode([CloudFavorite].self, from: data)
            favoriteRecords = rows
            favoriteKeys = Set(rows.map { "\\($0.store):\\($0.app_id)" })
        } catch {
            message = "读取云端收藏失败：\\(error.localizedDescription)"
        }
    }

    func toggleFavorite(store: String, appID: String, name: String, imageURL: String, storeURL: String) async {
        guard isLoggedIn, let token = readToken() else {
            needsLoginPrompt = true
            message = "请先登录，再使用云端收藏。"
            return
        }
        let key = "\\(store):\\(appID)"
        guard let encodedID = appID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: SupabaseConfig.projectURL + "/rest/v1/game_favorites?store=eq.\\(store)&app_id=eq.\\(encodedID)") else { return }
        var request = URLRequest(url: url)
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")
        do {
            if favoriteKeys.contains(key) {
                request.httpMethod = "DELETE"
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
                    message = "取消收藏失败，请稍后重试。"; return
                }
                favoriteKeys.remove(key)
                favoriteRecords.removeAll { $0.store == store && $0.app_id == appID }
                message = "已取消收藏。"
            } else {
                guard let insertURL = URL(string: SupabaseConfig.projectURL + "/rest/v1/game_favorites") else { return }
                var insert = URLRequest(url: insertURL)
                insert.httpMethod = "POST"
                insert.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
                insert.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")
                insert.setValue("application/json", forHTTPHeaderField: "Content-Type")
                insert.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
                let body: [String: Any] = ["store": store, "app_id": appID, "game_name": name,
                                           "image_url": imageURL, "store_url": storeURL]
                insert.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, response) = try await URLSession.shared.data(for: insert)
                guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
                    message = "收藏失败，请检查数据库字段类型和网络。"; return
                }
                favoriteKeys.insert(key)
                favoriteRecords.insert(CloudFavorite(store: store, app_id: appID, game_name: name, image_url: imageURL, store_url: storeURL), at: 0)
                message = "已加入收藏。"
            }
        } catch {
            message = "收藏操作失败：\\(error.localizedDescription)"
        }
    }

    init() {
        if let token = readToken(), !token.isEmpty {
            isLoggedIn = true
        }
    }

    func signUp(email: String, password: String) async {
        await authenticate(path: "signup?redirect_to=\(SupabaseConfig.redirectURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? SupabaseConfig.redirectURL)", email: email, password: password, isSignUp: true)
    }

    func signIn(email: String, password: String) async {
        await authenticate(path: "token?grant_type=password", email: email, password: password, isSignUp: false)
    }

    private func authenticate(path: String, email: String, password: String, isSignUp: Bool) async {
        guard SupabaseConfig.isConfigured else {
            message = "请先在代码顶部 SupabaseConfig 中填写 Supabase Project URL 和 anon/public key。"
            return
        }
        guard let url = URL(string: SupabaseConfig.projectURL + "/auth/v1/" + path) else {
            message = "Supabase 项目地址无效。"; return
        }
        guard email.contains("@"), password.count >= 6 else {
            message = "请输入有效邮箱，密码至少 6 位。"; return
        }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200...299).contains(status) {
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                message = (body?["msg"] as? String) ?? (body?["message"] as? String) ?? "账户请求失败（HTTP \(status)）"
                return
            }
            let result = try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
            if let token = result.access_token {
                saveToken(token)
                self.email = result.user?.email ?? email
                isLoggedIn = true
                await loadFavorites()
                message = isSignUp ? "注册成功，账户已登录。" : "登录成功。"
            } else if isSignUp {
                message = "注册请求已提交。请检查邮箱完成验证，然后返回登录。"
            } else {
                message = "登录成功，但服务器没有返回访问令牌，请检查 Supabase Auth 配置。"
            }
        } catch {
            message = "网络请求失败：\(error.localizedDescription)"
        }
    }

    // Supabase 邮箱确认后会通过 URL Scheme 返回 access_token。
    func handleAuthCallback(_ url: URL) async {
        guard url.scheme == "xianmianlingqu", url.host == "login-callback" else { return }
        var values: [String: String] = [:]
        if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment {
            for item in fragment.split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let key = String(pair[0]).removingPercentEncoding ?? String(pair[0])
                let value = String(pair[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(pair[1])
                values[key] = value
            }
        }
        if let error = values["error_description"] ?? values["error"] {
            message = "邮箱验证未完成：\(error)"
            return
        }
        guard let token = values["access_token"], !token.isEmpty else {
            message = "已打开验证回调，但没有收到登录令牌。请检查 Supabase 邮件模板和回调设置。"
            return
        }
        saveToken(token)
        email = emailFromJWT(token) ?? email
        isLoggedIn = true
        await loadFavorites()
        message = "邮箱验证成功，已登录。"
    }

    private func emailFromJWT(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["email"] as? String
    }

    func signOut() async {
        guard let token = readToken() else { isLoggedIn = false; return }
        if SupabaseConfig.isConfigured,
           let url = URL(string: SupabaseConfig.projectURL + "/auth/v1/logout") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        deleteToken(); email = ""; isLoggedIn = false
        favoriteKeys = []; favoriteRecords = []
        message = "已退出登录。"
    }

    private func saveToken(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey]
        SecItemDelete(query as CFDictionary)
        var add = query; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
    private func readToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func deleteToken() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tokenKey] as CFDictionary)
    }
}

private struct AccountHomeView: View {
    @ObservedObject var account: AppAccountStore
    @AppStorage("app.profile.nickname") private var nickname = ""
    @AppStorage("app.profile.avatarBase64") private var avatarBase64 = ""
    @AppStorage("app.appearance") private var appearance = "dark"
    @AppStorage("app.checkin.dates") private var checkinDatesRaw = ""
    @State private var isRegisterMode = false
    @State private var email = ""
    @State private var password = ""
    @State private var showProfileEditor = false
    @State private var showSettings = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var profileDraft = ""

    private var checkinDates: Set<String> { Set(checkinDatesRaw.split(separator: ",").map(String.init)) }
    private var todayKey: String { Self.dayFormatter.string(from: Date()) }
    private var hasCheckedIn: Bool { checkinDates.contains(todayKey) }
    private var streakCount: Int {
        var count = 0
        var day = Calendar.current.startOfDay(for: Date())
        while checkinDates.contains(Self.dayFormatter.string(from: day)) {
            count += 1
            guard let previous = Calendar.current.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                SteamStyle.background.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        if account.isLoggedIn {
                            profileCard
                            checkinCard
                            quickActions
                            settingsCard
                            accountActions
                        } else {
                            guestHeader
                            authCard
                        }
                        if let message = account.message {
                            Text(message).font(.system(size: 12)).foregroundStyle(SteamStyle.cyan)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(13)
                                .background(SteamStyle.cardLight, in: RoundedRectangle(cornerRadius: 12))
                        }
                        Text("限免领取 App 账户独立于 Steam 账号。我们不会要求你的 Steam 密码。")
                            .font(.system(size: 10)).foregroundStyle(SteamStyle.secondary).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }.padding(18).frame(maxWidth: 560).frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task { if account.isLoggedIn { await account.loadFavorites() } }
            .sheet(isPresented: $showProfileEditor) { profileEditor }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .onChange(of: selectedPhoto) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self),
                          let image = UIImage(data: data),
                          let resized = image.jpegData(compressionQuality: 0.78) else { return }
                    avatarBase64 = resized.base64EncodedString()
                }
            }
        }
    }

    private var guestHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 66)).foregroundStyle(SteamStyle.cyan)
            Text("欢迎来到限免领取").font(.system(size: 23, weight: .bold)).foregroundStyle(.white)
            Text("登录后管理个人资料、收藏和签到").font(.system(size: 12)).foregroundStyle(SteamStyle.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private var authCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                modeButton("登录", selected: !isRegisterMode) { isRegisterMode = false }
                modeButton("注册", selected: isRegisterMode) { isRegisterMode = true }
            }.padding(4).background(SteamStyle.background, in: RoundedRectangle(cornerRadius: 12))
            TextField("邮箱地址", text: $email).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                .padding(14).background(SteamStyle.background, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
            SecureField("密码（至少 6 位）", text: $password)
                .padding(14).background(SteamStyle.background, in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
            Button {
                Task { if isRegisterMode { await account.signUp(email: email, password: password) } else { await account.signIn(email: email, password: password) } }
            } label: {
                HStack { if account.isBusy { ProgressView().tint(.white) }; Text(isRegisterMode ? "创建账户" : "登录账户") }
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 48)
                    .background(SteamStyle.blue, in: RoundedRectangle(cornerRadius: 11))
            }.disabled(account.isBusy)
        }.padding(18).background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            avatarView(size: 66)
            VStack(alignment: .leading, spacing: 5) {
                Text(nickname.isEmpty ? "限免玩家" : nickname).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                Text(account.email).font(.system(size: 11)).foregroundStyle(SteamStyle.secondary).lineLimit(1)
                Text("App 玩家账户").font(.system(size: 10, weight: .semibold)).foregroundStyle(SteamStyle.cyan)
            }
            Spacer()
            Button { profileDraft = nickname; showProfileEditor = true } label: {
                Image(systemName: "pencil").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(SteamStyle.cardLight, in: Circle())
            }.buttonStyle(.plain)
        }.padding(16).background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var checkinCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每日签到").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    Text("养成每天发现好游戏的习惯").font(.system(size: 10)).foregroundStyle(SteamStyle.secondary)
                }
                Spacer()
                Image(systemName: "calendar.badge.checkmark").font(.system(size: 25)).foregroundStyle(SteamStyle.green)
            }
            HStack(spacing: 0) {
                statCell("连续签到", value: "\(streakCount) 天", icon: "flame.fill")
                statCell("累计签到", value: "\(checkinDates.count) 天", icon: "checkmark.seal.fill")
            }
            Button {
                guard !hasCheckedIn else { return }
                var dates = checkinDates; dates.insert(todayKey); checkinDatesRaw = dates.sorted().joined(separator: ",")
                account.message = "签到成功！明天记得再来。"
            } label: {
                HStack { Image(systemName: hasCheckedIn ? "checkmark.circle.fill" : "gift.fill"); Text(hasCheckedIn ? "今日已签到" : "立即签到") }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 45)
                    .background(hasCheckedIn ? SteamStyle.cardLight : SteamStyle.blue, in: RoundedRectangle(cornerRadius: 11))
            }.disabled(hasCheckedIn).buttonStyle(.plain)
            Text("当前签到记录保存在本机；云端同步将在下一步接入 Supabase 数据表。")
                .font(.system(size: 9)).foregroundStyle(SteamStyle.secondary)
        }.padding(16).background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("我的游戏").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            actionRow("我的收藏", subtitle: "Steam + Epic · \\(account.favoriteRecords.count) 款", icon: "heart.fill")
            actionRow("最近浏览", subtitle: "回到刚刚看过的游戏", icon: "clock.fill")
            actionRow("发行日历", subtitle: "关注近期即将发行的游戏", icon: "calendar")
        }.padding(16).background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("偏好与设置").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            Button { showSettings = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3").foregroundStyle(SteamStyle.cyan).frame(width: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("外观与设置").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        Text(appearanceLabel).font(.system(size: 10)).foregroundStyle(SteamStyle.secondary)
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(SteamStyle.secondary)
                }.padding(.vertical, 7)
            }.buttonStyle(.plain)
            actionRow("账户安全", subtitle: "邮箱账户由 Supabase 安全管理", icon: "lock.shield")
            actionRow("意见反馈", subtitle: "帮助我们改进限免领取", icon: "bubble.left")
            actionRow("关于我们", subtitle: "版本信息与服务说明", icon: "info.circle")
        }.padding(16).background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var accountActions: some View {
        Button { Task { await account.signOut() } } label: {
            Text("退出登录").font(.system(size: 13, weight: .bold)).foregroundStyle(.red)
                .frame(maxWidth: .infinity).frame(height: 46).background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }

    private var profileEditor: some View {
        NavigationStack {
            Form {
                Section("头像") {
                    HStack { Spacer(); avatarView(size: 86); Spacer() }
                    PhotosPicker(selection: $selectedPhoto, matching: .images) { Label("从相册选择头像", systemImage: "photo") }
                    Button("恢复默认头像", role: .destructive) { avatarBase64 = "" }
                }
                Section("昵称") {
                    TextField("输入你的昵称", text: $profileDraft).onChange(of: profileDraft) { _, value in if value.count > 20 { profileDraft = String(value.prefix(20)) } }
                }
            }
            .navigationTitle("编辑个人资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showProfileEditor = false } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { nickname = profileDraft.trimmingCharacters(in: .whitespacesAndNewlines); showProfileEditor = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("主题模式", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色模式").tag("light")
                        Text("深色模式").tag("dark")
                    }.pickerStyle(.inline)
                }
                Section("更多设置") {
                    LabeledContent("签到提醒", value: "后续版本开放")
                    LabeledContent("游戏发行提醒", value: "后续版本开放")
                    LabeledContent("社区功能", value: "规划中")
                }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var appearanceLabel: String {
        switch appearance { case "light": return "浅色模式"; case "system": return "跟随系统"; default: return "深色模式" }
    }

    private func avatarView(size: CGFloat) -> some View {
        Group {
            if let data = Data(base64Encoded: avatarBase64), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().foregroundStyle(SteamStyle.cyan).padding(5)
            }
        }.frame(width: size, height: size).background(SteamStyle.cardLight, in: Circle()).clipShape(Circle())
    }

    private func statCell(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(SteamStyle.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Text(title).font(.system(size: 9)).foregroundStyle(SteamStyle.secondary)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity)
    }

    private func actionRow(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(SteamStyle.cyan).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(subtitle).font(.system(size: 10)).foregroundStyle(SteamStyle.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(SteamStyle.secondary)
        }.padding(.vertical, 6)
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(selected ? .white : SteamStyle.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .background(selected ? SteamStyle.cardLight : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}
