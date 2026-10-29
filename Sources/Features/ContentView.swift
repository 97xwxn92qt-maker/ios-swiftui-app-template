
import SwiftUI

struct SteamGame: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var message = "点击下方按钮查询当前永久限免游戏"

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        message = "正在查询 Steam 限免信息……"

        defer {
            isLoading = false
        }

        do {
            let searchURL = URL(
                string: "https://store.steampowered.com/search/results/?specials=1&maxprice=free&json=1&count=50&cc=sg&l=schinese"
            )!

            var request = URLRequest(url: searchURL)
            request.timeoutInterval = 30
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Accept"
            )

            let (data, response) = try await URLSession.shared.data(
                for: request
            )

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw SteamError.requestFailed
            }

            guard let json = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                throw SteamError.invalidResponse
            }

            var candidates: [(id: String, name: String)] = []
            var seen = Set<String>()

            for item in items {
                guard let name = item["name"] as? String,
                      let logo = item["logo"] as? String,
                      let appID = extractAppID(from: logo),
                      seen.insert(appID).inserted else {
                    continue
                }

                candidates.append(
                    (id: appID, name: name)
                )
            }

            var results: [SteamGame] = []

            for candidate in candidates {
                guard !Task.isCancelled else { return }

                if await isPermanentFree(candidate.id) {
                    let cleanName = candidate.name
                        .replacingOccurrences(
                            of: "&amp;",
                            with: "&"
                        )

                    results.append(
                        SteamGame(
                            id: candidate.id,
                            name: cleanName,
                            url: URL(
                                string: "https://store.steampowered.com/app/\(candidate.id)/"
                            )!
                        )
                    )
                }
            }

            games = results

            if results.isEmpty {
                message = "暂时没有检测到符合条件的永久限免游戏"
            } else {
                message = "查询完成，共找到 \(results.count) 款永久限免游戏"
            }

        } catch {
            message = "查询失败：\(error.localizedDescription)"
        }
    }

    private func extractAppID(from logo: String) -> String? {
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

    private func isPermanentFree(_ appID: String) async -> Bool {
        guard let url = URL(
            string: "https://store.steampowered.com/api/appdetails/?appids=\(appID)&cc=sg&l=schinese"
        ) else {
            return false
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(
                for: request
            )

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return false
            }

            guard let root = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
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
                    let optionText = (
                        sub["option_text"] as? String ?? ""
                    ).lowercased()

                    let price = sub[
                        "price_in_cents_with_discount"
                    ] as? Int

                    if optionText.contains(
                        "limited free promotional package"
                    ), price == 0 {
                        return true
                    }
                }
            }

            return false

        } catch {
            return false
        }
    }
}

enum SteamError: LocalizedError {
    case requestFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            return "Steam 接口请求失败，请检查网络后重试。"
        case .invalidResponse:
            return "Steam 返回的数据格式不正确，请稍后重试。"
        }
    }
}

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
                                    Image(
                                        systemName: "arrow.clockwise"
                                    )
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
                            Link(destination: game.url) {
                                HStack(spacing: 12) {
                                    Image(
                                        systemName: "gamecontroller.fill"
                                    )
                                    .font(.title2)
                                    .foregroundStyle(.secondary)

                                    VStack(
                                        alignment: .leading,
                                        spacing: 5
                                    ) {
                                        Text(game.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)

                                        Text("永久入库优惠 · Steam")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(
                                        systemName: "arrow.up.right"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 5)
                            }
                        }
                    }
                }

                Section {
                    Text(
                        "数据来自 Steam 商店。查询结果以商店实际优惠信息为准；本应用不会自动领取游戏。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Steam 限免")
        }
    }
}
