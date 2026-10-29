import SwiftUI
import Foundation
import Combine
import UIKit

// MARK: - App Theme

enum AppStyle {
    static let background = Color(red: 0.035, green: 0.055, blue: 0.105)
    static let card = Color(red: 0.075, green: 0.105, blue: 0.175)
    static let cardLight = Color(red: 0.105, green: 0.145, blue: 0.225)
    static let blue = Color(red: 0.20, green: 0.55, blue: 1.00)
    static let green = Color(red: 0.20, green: 0.78, blue: 0.49)
    static let secondary = Color.white.opacity(0.68)
    static let border = Color.white.opacity(0.09)
}

// MARK: - Models

enum SteamItemKind: String, Hashable {
    case game
    case dlc

    var title: String {
        self == .dlc ? "DLC" : "游戏本体"
    }
}

struct SteamGame: Identifiable, Hashable {
    let appID: Int
    let name: String
    let kind: SteamItemKind

    var id: Int { appID }

    var storeURL: URL {
        URL(string: "https://store.steampowered.com/app/\(appID)/")!
    }
}

struct EpicGame: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let imageURL: URL?
    let productURL: URL
    let endDate: Date?
}

struct SteamAccount: Identifiable, Codable, Hashable {
    var steamID64: String
    var nickname: String
    var avatarURL: String

    var id: String { steamID64 }
}

// MARK: - Helpers

enum AppHelpers {
    static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }

        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value)
    }

    static func safePath(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Network

enum APIError: LocalizedError {
    case invalidURL
    case httpError
    case noResults(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请求网址无效。"
        case .httpError:
            return "网络请求失败，请检查网络后重试。"
        case .noResults(let message):
            return message
        }
    }
}

enum Network {
    static func getData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let response = response as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw APIError.httpError
        }

        return data
    }
}

// MARK: - Steam API

enum SteamAPI {
    static func fetchFreeGames() async throws -> [SteamGame] {
        var components = URLComponents(
            string: "https://store.steampowered.com/search/results/"
        )!

        components.queryItems = [
            URLQueryItem(name: "query", value: ""),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "count", value: "100"),
            URLQueryItem(name: "specials", value: "1"),
            URLQueryItem(name: "maxprice", value: "free"),
            URLQueryItem(name: "supportedlang", value: "schinese"),
            URLQueryItem(name: "infinite", value: "1")
        ]

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        let data = try await Network.getData(url)

        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw APIError.noResults("无法解析 Steam 返回的数据。")
        }

        let items = root["items"] as? [[String: Any]] ?? []

        let ids = items.compactMap { item -> Int? in
            if let id = item["id"] as? Int {
                return id
            }
            if let id = item["id"] as? String {
                return Int(id)
            }
            return nil
        }

        if ids.isEmpty {
            throw APIError.noResults(
                "Steam 暂时没有返回商品。请稍后刷新。"
            )
        }

        return await withTaskGroup(
            of: SteamGame?.self,
            returning: [SteamGame].self
        ) { group in
            for appID in ids.prefix(35) {
                group.addTask {
                    do {
                        return try await fetchPromotionalItem(appID: appID)
                    } catch {
                        return nil
                    }
                }
            }

            var result: [SteamGame] = []

            for await game in group {
                if let game {
                    result.append(game)
                }
            }

            return result.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        }
    }

    private static func fetchPromotionalItem(
        appID: Int
    ) async throws -> SteamGame? {
        var components = URLComponents(
            string: "https://store.steampowered.com/api/appdetails"
        )!

        components.queryItems = [
            URLQueryItem(name: "appids", value: String(appID)),
            URLQueryItem(name: "cc", value: "sg"),
            URLQueryItem(name: "l", value: "schinese")
        ]

        guard let url = components.url else {
            throw APIError.invalidURL
        }

        let data = try await Network.getData(url)

        guard
            let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let appRoot = root[String(appID)] as? [String: Any],
            appRoot["success"] as? Bool == true,
            let details = appRoot["data"] as? [String: Any],
            let name = details["name"] as? String
        else {
            return nil
        }

        let groups = details["package_groups"] as? [[String: Any]] ?? []

        let isLimitedFree = groups.contains { group in
            let text = (group["option_text"] as? String ?? "")
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .lowercased()

            let mentionsPromotion =
                text.contains("limited") ||
                text.contains("限时") ||
                text.contains("限時") ||
                text.contains("free to keep") ||
                text.contains("免费领取") ||
                text.contains("免費領取")

            let price = group["price_in_cents_with_discount"] as? Int

            return mentionsPromotion && (price == nil || price == 0)
        }

        guard isLimitedFree else { return nil }

        let type = (details["type"] as? String ?? "game").lowercased()
        let kind: SteamItemKind = type == "dlc" ? .dlc : .game

        return SteamGame(
            appID: appID,
            name: name,
            kind: kind
        )
    }
}

// MARK: - Epic API

enum EpicAPI {
    static func fetchFreeGames() async throws -> [EpicGame] {
        let address =
            "https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions?locale=zh-CN&country=SG&allowCountries=SG"

        guard let url = URL(string: address) else {
            throw APIError.invalidURL
        }

        let data = try await Network.getData(url)

        guard
            let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let dataObject = root["data"] as? [String: Any],
            let catalog = dataObject["Catalog"] as? [String: Any],
            let searchStore = catalog["searchStore"] as? [String: Any]
        else {
            throw APIError.noResults("Epic 返回的数据格式暂时无法识别。")
        }

        let products = searchStore["elements"] as? [[String: Any]] ?? []
        let now = Date()
        var results: [EpicGame] = []
        var seen = Set<String>()

        for product in products {
            guard
                let id = product["id"] as? String,
                let title = product["title"] as? String,
                let price = product["price"] as? [String: Any],
                let totalPrice = price["totalPrice"] as? [String: Any],
                let discountPrice = totalPrice["discountPrice"] as? Int,
                discountPrice == 0
            else {
                continue
            }

            let promotions = product["promotions"] as? [String: Any]
            let offerGroups =
                promotions?["promotionalOffers"] as? [[String: Any]] ?? []

            let offers = offerGroups.flatMap {
                $0["promotionalOffers"] as? [[String: Any]] ?? []
            }

            let activeOffer = offers.first { offer in
                let start = AppHelpers.parseDate(
                    offer["startDate"] as? String
                )
                let end = AppHelpers.parseDate(
                    offer["endDate"] as? String
                )

                let hasStarted = start == nil || start! <= now
                let hasNotEnded = end == nil || end! > now

                return hasStarted && hasNotEnded
            }

            guard let activeOffer else { continue }
            guard !seen.contains(id) else { continue }
            seen.insert(id)

            let slug = findSlug(product)
            let isBundle = (product["offerType"] as? Int) == 2
                || (product["offerType"] as? String) == "BUNDLE"

            let productURL: URL

            if !slug.isEmpty {
                let safeSlug = AppHelpers.safePath(slug)
                let path = isBundle ? "bundles" : "p"

                productURL = URL(
                    string: "https://store.epicgames.com/zh-CN/\(path)/\(safeSlug)"
                )!
            } else {
                var components = URLComponents(
                    string: "https://store.epicgames.com/zh-CN/browse"
                )!
                components.queryItems = [
                    URLQueryItem(name: "query", value: title)
                ]
                productURL = components.url!
            }

            let description = product["description"] as? String ?? ""
            let images = product["keyImages"] as? [[String: Any]] ?? []

            let imageString = images.first {
                let type = ($0["type"] as? String ?? "").lowercased()
                return type.contains("offer")
                    || type.contains("thumbnail")
                    || type.contains("diesel")
            }?["url"] as? String

            let imageURL = imageString.flatMap { URL(string: $0) }
            let endDate = AppHelpers.parseDate(
                activeOffer["endDate"] as? String
            )

            results.append(
                EpicGame(
                    id: id,
                    title: title,
                    description: description,
                    imageURL: imageURL,
                    productURL: productURL,
                    endDate: endDate
                )
            )
        }

        return results.sorted {
            if let first = $0.endDate, let second = $1.endDate {
                return first < second
            }
            if $0.endDate != nil { return true }
            if $1.endDate != nil { return false }

            return $0.title.localizedCaseInsensitiveCompare($1.title)
                == .orderedAscending
        }
    }

    private static func findSlug(_ product: [String: Any]) -> String {
        let catalogNS = product["catalogNs"] as? [String: Any] ?? [:]
        let mappings = catalogNS["mappings"] as? [[String: Any]] ?? []

        for preferredType in ["producthome", "product"] {
            if let mapping = mappings.first(where: {
                let pageType = ($0["pageType"] as? String ?? "").lowercased()
                let pageSlug = $0["pageSlug"] as? String ?? ""

                return pageType == preferredType && !pageSlug.isEmpty
            }) {
                return mapping["pageSlug"] as? String ?? ""
            }
        }

        for key in ["productSlug", "urlSlug"] {
            if let value = product[key] as? String, !value.isEmpty {
                return value
            }
        }

        return ""
    }
}

// MARK: - Observable stores

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            games = try await SteamAPI.fetchFreeGames()

            if games.isEmpty {
                errorMessage =
                    "暂时没有检测到限时免费商品。Steam 的促销数据可能有延迟。"
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

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            games = try await EpicAPI.fetchFreeGames()

            if games.isEmpty {
                errorMessage =
                    "暂时没有检测到当前限免，或者 Epic 的数据格式发生了变化。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Main Tabs

struct ContentView: View {
    var body: some View {
        TabView {
            SteamHomeView()
                .tabItem {
                    Image(systemName: "gamecontroller.fill")
                    Text("Steam")
                }

            EpicHomeView()
                .tabItem {
                    Image(systemName: "gift.fill")
                    Text("Epic 限免")
                }

            MyAccountsView()
                .tabItem {
                    Image(systemName: "person.crop.circle.fill")
                    Text("我的")
                }
        }
        .tint(AppStyle.blue)
        .preferredColorScheme(.dark)
    }
}
// MARK: - Steam Home

struct SteamHomeView: View {
    @StateObject private var store = SteamStore()

    var body: some View {
        NavigationStack {
            ZStack {
                AppStyle.background.ignoresSafeArea()

                if store.isLoading && store.games.isEmpty {
                    ProgressView("正在获取 Steam 限免…")
                        .tint(.white)
                } else if store.games.isEmpty,
                          let error = store.errorMessage {
                    ErrorPanel(
                        title: "暂时无法显示限免",
                        message: error
                    ) {
                        Task { await store.refresh() }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(AppStyle.blue)
                                    .frame(width: 56, height: 56)
                                    .background(
                                        AppStyle.blue.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 15)
                                    )

                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Steam 限时免费")
                                        .font(.title3.bold())
                                        .foregroundStyle(.white)

                                    Text("发现正在进行的免费活动")
                                        .font(.caption)
                                        .foregroundStyle(AppStyle.secondary)
                                }

                                Spacer()
                            }
                            .padding(16)
                            .background(
                                AppStyle.card,
                                in: RoundedRectangle(cornerRadius: 18)
                            )

                            if let error = store.errorMessage {
                                InlineNotice(message: error)
                            }

                            ForEach(store.games) { game in
                                SteamGameCard(game: game)
                            }

                            Text("活动可能随时结束，请以 Steam 官方商店页面为准。")
                                .font(.caption)
                                .foregroundStyle(AppStyle.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 12)
                        }
                        .padding(16)
                    }
                    .refreshable {
                        await store.refresh()
                    }
                }
            }
            .navigationTitle("Steam 限免")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
            .task {
                if store.games.isEmpty && !store.isLoading {
                    await store.refresh()
                }
            }
        }
    }
}

// MARK: - Steam Game Card

struct SteamGameCard: View {
    let game: SteamGame

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(
                    systemName: game.kind == .dlc
                        ? "puzzlepiece.extension.fill"
                        : "gamecontroller.fill"
                )
                .font(.system(size: 24))
                .foregroundStyle(AppStyle.blue)
                .frame(width: 50, height: 50)
                .background(
                    AppStyle.cardLight,
                    in: RoundedRectangle(cornerRadius: 13)
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text(game.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Text(game.kind.title)
                            .font(.caption2.bold())
                            .foregroundStyle(AppStyle.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                AppStyle.blue.opacity(0.15),
                                in: Capsule()
                            )

                        Text("限时免费")
                            .font(.caption2.bold())
                            .foregroundStyle(AppStyle.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                AppStyle.green.opacity(0.13),
                                in: Capsule()
                            )
                    }
                }

                Spacer(minLength: 0)
            }

            Button {
                UIApplication.shared.open(game.storeURL)
            } label: {
                Label("前往 Steam 手动领取", systemImage: "arrow.up.right.square")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        AppStyle.blue,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(15)
        .background(
            AppStyle.card,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppStyle.border)
        }
    }
}

// MARK: - Epic Home

struct EpicHomeView: View {
    @StateObject private var store = EpicStore()

    var body: some View {
        NavigationStack {
            ZStack {
                AppStyle.background.ignoresSafeArea()

                if store.isLoading && store.games.isEmpty {
                    ProgressView("正在获取 Epic 限免…")
                        .tint(.white)
                } else if store.games.isEmpty,
                          let error = store.errorMessage {
                    ErrorPanel(
                        title: "暂时无法显示限免",
                        message: error
                    ) {
                        Task { await store.refresh() }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: "gift.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.purple)
                                    .frame(width: 56, height: 56)
                                    .background(
                                        Color.purple.opacity(0.16),
                                        in: RoundedRectangle(cornerRadius: 15)
                                    )

                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Epic Games 限免")
                                        .font(.title3.bold())
                                        .foregroundStyle(.white)

                                    Text("查看当前促销中的免费商品")
                                        .font(.caption)
                                        .foregroundStyle(AppStyle.secondary)
                                }

                                Spacer()
                            }
                            .padding(16)
                            .background(
                                AppStyle.card,
                                in: RoundedRectangle(cornerRadius: 18)
                            )

                            if let error = store.errorMessage {
                                InlineNotice(message: error)
                            }

                            ForEach(store.games) { game in
                                EpicGameCard(game: game)
                            }

                            Text("请在 Epic 官方页面确认价格和活动结束时间。")
                                .font(.caption)
                                .foregroundStyle(AppStyle.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 12)
                        }
                        .padding(16)
                    }
                    .refreshable {
                        await store.refresh()
                    }
                }
            }
            .navigationTitle("Epic 限免")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
            .task {
                if store.games.isEmpty && !store.isLoading {
                    await store.refresh()
                }
            }
        }
    }
}

// MARK: - Epic Game Card

struct EpicGameCard: View {
    let game: EpicGame

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let imageURL = game.imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else if phase.error != nil {
                        imagePlaceholder
                    } else {
                        ZStack {
                            AppStyle.cardLight
                            ProgressView().tint(.white)
                        }
                    }
                }
                .frame(height: 170)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 13))
            } else {
                imagePlaceholder
                    .frame(height: 120)
            }

            Text(game.title)
                .font(.headline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if !game.description.isEmpty {
                Text(game.description)
                    .font(.caption)
                    .foregroundStyle(AppStyle.secondary)
                    .lineLimit(3)
            }

            if let endDate = game.endDate {
                Label(
                    "结束时间：\(endDate.formatted(date: .abbreviated, time: .shortened))",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                Label(
                    "具体结束时间以商店页面为准",
                    systemImage: "clock"
                )
                .font(.caption)
                .foregroundStyle(AppStyle.secondary)
            }

            Button {
                UIApplication.shared.open(game.productURL)
            } label: {
                Label("打开 Epic 商城领取", systemImage: "arrow.up.right.square")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        AppStyle.blue,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(
            AppStyle.card,
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppStyle.border)
        }
    }

    private var imagePlaceholder: some View {
        ZStack {
            AppStyle.cardLight
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 34))
                .foregroundStyle(AppStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

// MARK: - My Accounts

struct MyAccountsView: View {
    @AppStorage("steam_accounts_json") private var accountsJSON = "[]"
    @AppStorage("selected_steam_id") private var selectedSteamID = ""

    @State private var showingAddAccount = false
    @State private var accountToDelete: SteamAccount?
    @State private var showingDeleteAlert = false

    private var accounts: [SteamAccount] {
        guard
            let data = accountsJSON.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(
                [SteamAccount].self,
                from: data
            )
        else {
            return []
        }

        return decoded
    }

    private var selectedAccount: SteamAccount? {
        accounts.first { $0.steamID64 == selectedSteamID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppStyle.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        profileHeader

                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Steam 账号列表")
                                    .font(.headline)
                                    .foregroundStyle(.white)

                                Spacer()

                                Text("\(accounts.count) 个")
                                    .font(.caption)
                                    .foregroundStyle(AppStyle.secondary)
                            }

                            if accounts.isEmpty {
                                VStack(spacing: 10) {
                                    Image(systemName: "person.badge.plus")
                                        .font(.system(size: 32))
                                        .foregroundStyle(AppStyle.secondary)

                                    Text("还没有添加账号")
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.white)

                                    Text("添加资料后，可在这里切换账号。")
                                        .font(.caption)
                                        .foregroundStyle(AppStyle.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                            }

                            ForEach(accounts) { account in
                                accountRow(account)
                            }

                            Button {
                                showingAddAccount = true
                            } label: {
                                Label("添加 Steam 账号", systemImage: "plus.circle.fill")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(
                                        AppStyle.blue,
                                        in: RoundedRectangle(cornerRadius: 12)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(16)
                        .background(
                            AppStyle.card,
                            in: RoundedRectangle(cornerRadius: 20)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(AppStyle.border)
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            Label("使用说明", systemImage: "info.circle.fill")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)

                            Text("此页面保存的是你手动填写的账号资料。切换账号不会自动改变 Safari 或 Steam 客户端的登录状态。")
                                .font(.caption)
                                .foregroundStyle(AppStyle.secondary)

                            Text("不要填写 Steam 密码、Steam Guard 验证码或 Cookie。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(
                            AppStyle.card,
                            in: RoundedRectangle(cornerRadius: 18)
                        )
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddAccount = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddAccount) {
                AddSteamAccountView { account in
                    var updated = accounts

                    if let index = updated.firstIndex(
                        where: { $0.steamID64 == account.steamID64 }
                    ) {
                        updated[index] = account
                    } else {
                        updated.append(account)
                    }

                    saveAccounts(updated)
                    selectedSteamID = account.steamID64
                }
                .preferredColorScheme(.dark)
            }
            .alert(
                "删除账号？",
                isPresented: $showingDeleteAlert,
                presenting: accountToDelete
            ) { account in
                Button("取消", role: .cancel) {}

                Button("删除", role: .destructive) {
                    let updated = accounts.filter {
                        $0.steamID64 != account.steamID64
                    }

                    saveAccounts(updated)

                    if selectedSteamID == account.steamID64 {
                        selectedSteamID = updated.first?.steamID64 ?? ""
                    }
                }
            } message: { account in
                Text("只会删除本 App 中的“\(account.nickname)”资料。")
            }
            .onAppear {
                if selectedSteamID.isEmpty,
                   let first = accounts.first {
                    selectedSteamID = first.steamID64
                }
            }
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 12) {
            accountAvatar(selectedAccount, size: 88)

            Text(selectedAccount?.nickname ?? "尚未添加账号")
                .font(.title2.bold())
                .foregroundStyle(.white)

            if let account = selectedAccount {
                Text("SteamID64：\(account.steamID64)")
                    .font(.caption)
                    .foregroundStyle(AppStyle.secondary)
                    .textSelection(.enabled)

                Text("当前选中账号")
                    .font(.caption.bold())
                    .foregroundStyle(AppStyle.green)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        AppStyle.green.opacity(0.13),
                        in: Capsule()
                    )
            } else {
                Text("添加账号资料，管理你的多个账号")
                    .font(.caption)
                    .foregroundStyle(AppStyle.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            AppStyle.card,
            in: RoundedRectangle(cornerRadius: 22)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(AppStyle.border)
        }
    }

    private func accountRow(_ account: SteamAccount) -> some View {
        let isSelected = account.steamID64 == selectedSteamID

        return HStack(spacing: 12) {
            accountAvatar(account, size: 46)

            VStack(alignment: .leading, spacing: 5) {
                Text(account.nickname)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(account.steamID64)
                    .font(.caption2)
                    .foregroundStyle(AppStyle.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppStyle.green)
            } else {
                Button("切换") {
                    selectedSteamID = account.steamID64
                }
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppStyle.blue, in: Capsule())
            }

            Menu {
                Button(role: .destructive) {
                    accountToDelete = account
                    showingDeleteAlert = true
                } label: {
                    Label("删除账号", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(AppStyle.secondary)
                    .frame(width: 28, height: 36)
            }
        }
        .padding(12)
        .background(
            isSelected ? AppStyle.blue.opacity(0.14) : AppStyle.cardLight,
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isSelected ? AppStyle.blue.opacity(0.5) : AppStyle.border
                )
        }
    }

    @ViewBuilder
    private func accountAvatar(
        _ account: SteamAccount?,
        size: CGFloat
    ) -> some View {
        if let account,
           let url = URL(string: account.avatarURL),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    defaultAvatar(size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            defaultAvatar(size: size)
        }
    }

    private func defaultAvatar(size: CGFloat) -> some View {
        ZStack {
            AppStyle.cardLight

            Image(systemName: "person.fill")
                .font(.system(size: size * 0.42))
                .foregroundStyle(AppStyle.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func saveAccounts(_ list: [SteamAccount]) {
        guard
            let data = try? JSONEncoder().encode(list),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }

        accountsJSON = json
    }
}

// MARK: - Add Steam Account

struct AddSteamAccountView: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (SteamAccount) -> Void

    @State private var steamID = ""
    @State private var nickname = ""
    @State private var avatarURL = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("账号资料") {
                    TextField("17 位 SteamID64", text: $steamID)
                        .keyboardType(.numberPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("显示昵称", text: $nickname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("头像图片 URL（可选）", text: $avatarURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("可以填写 SteamID64，或粘贴 steamcommunity.com/profiles/数字 格式的个人资料链接。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("当前版本不会自动获取 Steam 账号资料，也不会验证账号所有权。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("保存账号") {
                        save()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppStyle.background)
            .navigationTitle("添加账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() {
        let raw = steamID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let normalizedID: String

        if let range = raw.range(
            of: "steamcommunity.com/profiles/",
            options: .caseInsensitive
        ) {
            let tail = String(raw[range.upperBound...])
            normalizedID = String(tail.prefix { $0.isNumber })
        } else {
            normalizedID = raw
        }

        guard normalizedID.count == 17,
              normalizedID.allSatisfy({ $0.isNumber }) else {
            errorMessage = "请输入正确的 17 位 SteamID64。"
            return
        }

        let cleanNickname = nickname.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !cleanNickname.isEmpty else {
            errorMessage = "请填写显示昵称。"
            return
        }

        let cleanAvatar = avatarURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        if !cleanAvatar.isEmpty {
            guard let url = URL(string: cleanAvatar),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                errorMessage = "头像地址必须是有效的 HTTP 或 HTTPS 链接。"
                return
            }
        }

        onSave(
            SteamAccount(
                steamID64: normalizedID,
                nickname: cleanNickname,
                avatarURL: cleanAvatar
            )
        )

        dismiss()
    }
}

// MARK: - Error and Notice Views

struct ErrorPanel: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 42))
                .foregroundStyle(AppStyle.blue)

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(AppStyle.secondary)
                .multilineTextAlignment(.center)

            Button(action: retry) {
                Label("重新加载", systemImage: "arrow.clockwise")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(AppStyle.blue, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InlineNotice: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(AppStyle.secondary)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppStyle.cardLight,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}
