import SwiftUI
import Combine
import Foundation
import UIKit

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
        guard let url = makeURL(
            "https://store.steampowered.com/search/results/",
            queryItems: [
                URLQueryItem(name: "category1", value: "998"),
                URLQueryItem(name: "maxprice", value: "free"),
                URLQueryItem(name: "sort_by", value: "Released_DESC"),
                URLQueryItem(name: "json", value: "1"),
                URLQueryItem(name: "count", value: "50"),
                URLQueryItem(name: "cc", value: countryCode),
                URLQueryItem(name: "l", value: language)
            ]
        ) else {
            throw URLError(.badURL)
        }

        let root = dictionary(try await requestJSON(url))
        let items = root["items"] as? [[String: Any]] ?? []

        guard !items.isEmpty else {
            throw NSError(
                domain: "SteamAPI",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Steam 没有返回免费游戏"]
            )
        }

        var results: [SteamFreeGame] = []
        var seen = Set<Int>()

        for item in items {
            let id = intValue(item["id"]) != 0
                ? intValue(item["id"])
                : intValue(item["appid"])

            let name = string(item["name"])
            guard id > 0, !name.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)

            do {
                guard let detailURL = makeURL(
                    "https://store.steampowered.com/api/appdetails",
                    queryItems: [
                        URLQueryItem(name: "appids", value: "\(id)"),
                        URLQueryItem(name: "cc", value: countryCode),
                        URLQueryItem(name: "l", value: language)
                    ]
                ) else { continue }

                let detailJSON = try await requestJSON(detailURL)
                let appRoot = dictionary(dictionary(detailJSON)["\(id)"])

                guard appRoot["success"] as? Bool == true else { continue }

                let data = dictionary(appRoot["data"])
                guard string(data["type"]).lowercased() == "game" else { continue }
                guard data["is_free"] as? Bool == true else { continue }

                let releaseText = string(dictionary(data["release_date"])["date"])

                results.append(
                    SteamFreeGame(
                        id: id,
                        name: string(data["name"]).isEmpty ? name : string(data["name"]),
                        imageURL: string(data["header_image"]).isEmpty
                            ? imageFromItem(item)
                            : string(data["header_image"]),
                        releaseDate: parseSteamReleaseDate(releaseText)
                    )
                )
            } catch {
                continue
            }
        }

        return results.sorted {
            ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast)
        }
    }

    // 新增功能：Steam 商店搜索

    static func searchGames(_ keyword: String) async throws -> [SteamSearchGame] {
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }

        guard let url = makeURL(
            "https://store.steampowered.com/search/results/",
            queryItems: [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "json", value: "1"),
                URLQueryItem(name: "count", value: "30"),
                URLQueryItem(name: "cc", value: countryCode),
                URLQueryItem(name: "l", value: language)
            ]
        ) else {
            throw URLError(.badURL)
        }

        let root = dictionary(try await requestJSON(url))
        let items = root["items"] as? [[String: Any]] ?? []

        var results: [SteamSearchGame] = []
        var seen = Set<Int>()

        for item in items {
            let id = intValue(item["id"]) != 0
                ? intValue(item["id"])
                : intValue(item["appid"])
            let name = string(item["name"])

            guard id > 0, !name.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)

            results.append(
                SteamSearchGame(
                    id: id,
                    name: name,
                    imageURL: imageFromItem(item)
                )
            )
        }

        return results
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
        }
        .tint(selectedPlatform == 0 ? SteamStyle.cyan : .white)
        .preferredColorScheme(.dark)
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
                SteamFreeHomeView()
            } label: {
                featureRow(
                    icon: "gamecontroller.fill",
                    title: "Steam 免费开玩",
                    subtitle: "发现 Steam 当前免费游戏",
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

                VStack(spacing: 4) {
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

// MARK: - Steam 免费开玩页面

private struct SteamFreeHomeView: View {
    @StateObject private var store = SteamFreeStore()
    @State private var selectedCategory = 0

    private var displayedGames: [SteamFreeGame] {
        selectedCategory == 0 ? store.recentGames : store.historicalGames
    }

    var body: some View {
        ZStack {
            SteamStyle.background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    header

                    Picker("分类", selection: $selectedCategory) {
                        Text("最近免费").tag(0)
                        Text("历史免费").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .tint(SteamStyle.cyan)

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selectedCategory == 0 ? "最近发行" : "较早发行")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)

                            Text("Steam 当前免费游戏目录")
                                .font(.system(size: 11))
                                .foregroundStyle(SteamStyle.secondary)
                        }

                        Spacer()

                        Text("\(displayedGames.count) 款")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(SteamStyle.cyan)
                    }

                    if store.isLoading && store.games.isEmpty {
                        loadingView
                    } else if let error = store.errorMessage,
                              store.games.isEmpty {
                        errorView(error)
                    } else if displayedGames.isEmpty {
                        emptyView
                    } else {
                        LazyVStack(spacing: 13) {
                            ForEach(displayedGames) { game in
                                SteamFreeGameCard(game: game)
                            }
                        }
                    }

                    Text("分类依据游戏发布日期；免费状态以 Steam 商店页面为准。")
                        .font(.system(size: 10))
                        .foregroundStyle(SteamStyle.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
            .refreshable {
                await store.loadGames()
            }
        }
        .navigationTitle("Steam 免费开玩")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if store.games.isEmpty {
                await store.loadGames()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("FREE TO PLAY")
                    .font(.system(size: 11, weight: .black))
                    .tracking(2)
                    .foregroundStyle(SteamStyle.cyan)

                Text("Steam 免费开玩")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.white)

                Text("发现可以直接免费游玩的游戏")
                    .font(.system(size: 12))
                    .foregroundStyle(SteamStyle.secondary)
            }

            Spacer()

            Button {
                Task { await store.loadGames() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SteamStyle.cyan)
                    .frame(width: 42, height: 42)
                    .background(SteamStyle.cardLight, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(SteamStyle.cyan)
            Text("正在获取 Steam 免费游戏…")
                .font(.system(size: 13))
                .foregroundStyle(SteamStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(SteamStyle.cyan)

            Text("获取失败")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)
                .multilineTextAlignment(.center)

            Button("重新加载") {
                Task { await store.loadGames() }
            }
            .foregroundStyle(SteamStyle.cyan)
        }
        .frame(maxWidth: .infinity)
        .padding(25)
        .background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 32))
                .foregroundStyle(SteamStyle.cyan)

            Text("这个分类暂时没有游戏")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            Text("可以切换分类或下拉刷新")
                .font(.system(size: 12))
                .foregroundStyle(SteamStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 55)
    }
}

// MARK: - 免费游戏卡片

private struct SteamFreeGameCard: View {
    let game: SteamFreeGame

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
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
                .frame(width: 118, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 7) {
                    Text(game.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text("免费游玩")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SteamStyle.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(SteamStyle.green.opacity(0.13), in: Capsule())

                    Text(releaseText)
                        .font(.system(size: 10))
                        .foregroundStyle(SteamStyle.secondary)
                }

                Spacer(minLength: 0)
            }

            Button {
                UIApplication.shared.open(game.storeURL)
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text("打开 Steam 游戏页面")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(height: 40)
                .background(SteamStyle.blue, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(SteamStyle.card, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(SteamStyle.border, lineWidth: 1)
        }
    }

    private var releaseText: String {
        guard let date = game.releaseDate else {
            return "发行日期未知"
        }

        return "发行日期：" + date.formatted(
            .dateTime.year().month().day()
        )
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
