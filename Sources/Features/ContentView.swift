
import SwiftUI
import UIKit

struct SteamGame: Identifiable, Hashable {
    let appID: String
    let name: String

    var id: String { appID }

    var storeURL: URL {
        URL(string: "https://store.steampowered.com/app/\(appID)/")!
    }
}

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var message = "点击刷新，查询 Steam 永久限免"
    @Published var lastUpdated: Date?

    private let country = "sg"

    var filteredGames: [SteamGame] {
        guard !searchText.isEmpty else { return games }
        return games.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        message = "正在查询 Steam 活动……"
        defer { isLoading = false }

        do {
            let searchURL = URL(
                string: "https://store.steampowered.com/search/results/?specials=1&maxprice=free&json=1&count=50&cc=\(country)&l=schinese"
            )!

            var request = URLRequest(url: searchURL)
            request.timeoutInterval = 20
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Accept"
            )

            let (data, response) = try await URLSession.shared.data(
                for: request
            )

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw SteamError.badResponse
            }

            guard let json = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
                  let html = json["results_html"] as? String else {
                throw SteamError.invalidData
            }

            let candidates = parseCandidates(html)

            if candidates.isEmpty {
                games = []
                lastUpdated = Date()
                message = "暂未找到候选游戏，或 Steam 返回格式发生变化。"
                return
            }

            var verified: [SteamGame] = []

            // 逐个核实候选游戏，避免把普通免费游戏当作永久限免。
            for candidate in candidates.prefix(20) {
                if Task.isCancelled { break }

                do {
                    if let game = try await verifyPromotion(
                        appID: candidate.appID,
                        name: candidate.name
                    ) {
                        verified.append(game)
                    }
                } catch {
                    // 单个游戏查询失败，不影响其他候选游戏。
                    continue
                }
            }

            games = verified
            lastUpdated = Date()

            if verified.isEmpty {
                message = "本次没有核实到永久限免。也可能是 Steam 接口限制或活动数据尚未更新。"
            } else {
                message = "已核实 \(verified.count) 个候选活动。领取前请确认活动仍有效。"
            }
        } catch {
            message = "获取失败：\(error.localizedDescription)"
        }
    }

    private func parseCandidates(
        _ html: String
    ) -> [SteamGame] {
        // Steam 搜索结果的 data-ds-appid 可能包含多个 App ID。
        let pattern = #"data-ds-appid="([^"]+)""#

        guard let regex = try? NSRegularExpression(
            pattern: pattern
        ) else {
            return []
        }

        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHTML.length)
        )

        var results: [SteamGame] = []
        var seen = Set<String>()

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }

            let value = nsHTML.substring(
                with: match.range(at: 1)
            )

            // 多 App ID 结果只取第一个，避免重复。
            let firstID = value
                .split(separator: ",")
                .first
                .map(String.init) ?? ""

            guard !firstID.isEmpty,
                  firstID.allSatisfy(\.isNumber),
                  seen.insert(firstID).inserted else {
                continue
            }

            results.append(
                SteamGame(appID: firstID, name: "Steam 游戏 \(firstID)")
            )
        }

        return results
    }

    private func verifyPromotion(
        appID: String,
        name: String
    ) async throws -> SteamGame? {
        let url = URL(
            string: "https://store.steampowered.com/api/appdetails/?appids=\(appID)&cc=\(country)&l=schinese"
        )!

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SteamError.badResponse
        }

        guard let root = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any],
              let app = root[appID] as? [String: Any],
              app["success"] as? Bool == true,
              let details = app["data"] as? [String: Any] else {
            return nil
        }

        // Steam 商店名称优先使用接口返回值。
        let realName = details["name"] as? String ?? name

        guard let groups = details["package_groups"] as? [String: Any],
              let subs = groups["subs"] as? [[String: Any]] else {
            return nil
        }

        let hasPromotion = subs.contains { sub in
            let optionText = (
                sub["option_text"] as? String ?? ""
            ).lowercased()

            let discountedPrice = sub[
                "price_in_cents_with_discount"
            ]

            let priceIsZero: Bool

            if let number = discountedPrice as? NSNumber {
                priceIsZero = number.intValue == 0
            } else if let string = discountedPrice as? String {
                priceIsZero = Int(string) == 0
            } else {
                priceIsZero = false
            }

            return optionText.contains(
                "limited free promotional package"
            ) && priceIsZero
        }

        guard hasPromotion else { return nil }

        return SteamGame(
            appID: appID,
            name: realName
        )
    }

    enum SteamError: LocalizedError {
        case badResponse
        case invalidData

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return "Steam 服务器暂时无法访问。"
            case .invalidData:
                return "Steam 返回的数据格式不符合预期。"
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var store = SteamStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header

                if store.isLoading && store.games.isEmpty {
                    Spacer()
                    ProgressView("正在查询永久限免……")
                    Spacer()
                } else if store.filteredGames.isEmpty {
                    Spacer()

                    Image(systemName: "gift")
                        .font(.system(size: 52))
                        .foregroundStyle(.orange)

                    Text("暂无已核实的限免")
                        .font(.headline)
                        .padding(.top, 12)

                    Text(store.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 4)

                    Button("重新查询") {
                        Task { await store.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .padding(.top, 16)

                    Spacer()
                } else {
                    List(store.filteredGames) { game in
                        gameRow(game)
                    }
                    .listStyle(.insetGrouped)
                }

                footer
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("永久限免助手")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $store.searchText,
                prompt: "搜索游戏名称"
            )
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
        }
        .tint(.orange)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "gift.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Steam 永久限免")
                        .font(.headline)

                    Text("只筛选疑似永久领取活动")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                Text(store.message)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let date = store.lastUpdated {
                Text("上次查询：\(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func gameRow(_ game: SteamGame) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "gamecontroller.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Text(game.name)
                        .font(.headline)

                    Text("App ID：\(game.appID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("已匹配永久限免标记，领取前请再次确认")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Button {
                UIApplication.shared.open(game.storeURL)
            } label: {
                Label(
                    "前往 Steam 商店",
                    systemImage: "arrow.up.right.square"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.vertical, 6)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                Task { await store.refresh() }
            } label: {
                HStack {
                    if store.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }

                    Text(store.isLoading ? "正在查询" : "刷新限免列表")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(store.isLoading)

            Text("本应用不会自动领取，也不会保存 Steam 密码。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
    }
}

#Preview {
    ContentView()
}
