
import SwiftUI
import Foundation

// MARK: - 游戏模型

struct SteamGame: Identifiable, Hashable {
    let appID: String
    let name: String
    let storeURL: URL

    var id: String { appID }
}

struct SteamCandidate {
    let appID: String
    let name: String
}

// MARK: - Steam 数据服务

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var message = "点击刷新，查询 Steam 永久限免活动。"
    @Published var lastUpdated: Date?

    private let country = "sg"

    // MARK: 刷新列表

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        message = "正在查询 Steam 活动……"
        defer { isLoading = false }

        do {
            let candidates = try await fetchCandidates()

            guard !candidates.isEmpty else {
                games = []
                lastUpdated = Date()
                message = "没有解析到候选游戏，请稍后重试。"
                return
            }

            message = "找到 \(candidates.count) 个候选游戏，正在核实资格……"

            var verified: [SteamGame] = []
            var failedCount = 0

            for candidate in candidates.prefix(50) {
                do {
                    if let game = try await verifyPromotion(
                        appID: candidate.appID,
                        fallbackName: candidate.name
                    ) {
                        verified.append(game)
                    }
                } catch {
                    failedCount += 1
                }
            }

            games = verified.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }

            lastUpdated = Date()

            if !verified.isEmpty {
                message = "核实到 \(verified.count) 款永久限免候选游戏，请打开商店确认领取条件。"
            } else if failedCount == candidates.count {
                message = "候选游戏已找到，但核实接口全部失败，请检查网络后重试。"
            } else {
                message = "已检查 \(candidates.count) 个候选游戏，暂未核实到符合条件的永久限免。"
            }
        } catch {
            games = []
            message = "获取失败：\(error.localizedDescription)"
        }
    }

    // MARK: 获取候选游戏

    private func fetchCandidates() async throws -> [SteamCandidate] {
        guard let url = URL(
            string: "https://store.steampowered.com/search/results/?specials=1&maxprice=free&json=1&count=50&cc=\(country)&l=schinese"
        ) else {
            throw SteamError.diagnostic("搜索网址无效。")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "application/json, text/plain, */*",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "https://store.steampowered.com/",
            forHTTPHeaderField: "Referer"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SteamError.diagnostic("无法读取 Steam 服务器响应。")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SteamError.diagnostic(
                "Steam 搜索接口 HTTP 状态码：\(http.statusCode)"
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw SteamError.diagnostic("Steam 返回内容不是有效 JSON。")
        }

        var candidates: [SteamCandidate] = []
        var seen = Set<String>()

        // 新格式：items 中包含 name 和 logo
        if let items = json["items"] as? [[String: Any]] {
            for item in items {
                let name = decodeHTMLEntities(
                    item["name"] as? String ?? ""
                )

                let logo = item["logo"] as? String ?? ""

                // 从类似 /apps/5340370/ 的路径提取 App ID
                guard let appID = extractAppID(from: logo) else {
                    continue
                }

                guard seen.insert(appID).inserted else {
                    continue
                }

                candidates.append(
                    SteamCandidate(
                        appID: appID,
                        name: name.isEmpty ? "Steam 游戏 \(appID)" : name
                    )
                )
            }
        }

        // 旧格式：results_html
        if let html = json["results_html"] as? String {
            for candidate in parseHTMLCandidates(html) {
                guard seen.insert(candidate.appID).inserted else {
                    continue
                }
                candidates.append(candidate)
            }
        }

        if candidates.isEmpty {
            let keys = json.keys.sorted().joined(separator: ", ")

            let itemKeys: String
            if let first = (json["items"] as? [[String: Any]])?.first {
                itemKeys = first.keys.sorted().joined(separator: ", ")
            } else {
                itemKeys = "无 items 示例"
            }

            throw SteamError.diagnostic(
                "没有解析到游戏 ID。顶层字段：\(keys)；items 首项字段：\(itemKeys)"
            )
        }

        return candidates
    }

    // MARK: 从图片地址提取 App ID

    private func extractAppID(from text: String) -> String? {
        let pattern = #"/apps/([0-9]+)/"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)

        guard let match = regex.firstMatch(
            in: text,
            range: range
        ), let idRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[idRange])
    }

    // MARK: 兼容旧 HTML 格式

    private func parseHTMLCandidates(_ html: String) -> [SteamCandidate] {
        let pattern = #"data-ds-appid="([^"]+)""#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHTML.length)
        )

        var results: [SteamCandidate] = []
        var seen = Set<String>()

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }

            let value = nsHTML.substring(with: match.range(at: 1))

            for appID in value.split(separator: ",").map(String.init) {
                guard appID.allSatisfy(\.isNumber),
                      seen.insert(appID).inserted else {
                    continue
                }

                results.append(
                    SteamCandidate(
                        appID: appID,
                        name: "Steam 游戏 \(appID)"
                    )
                )
            }
        }

        return results
    }

    // MARK: 核实永久限免

    private func verifyPromotion(
        appID: String,
        fallbackName: String
    ) async throws -> SteamGame? {
        guard let url = URL(
            string: "https://store.steampowered.com/api/appdetails/?appids=\(appID)&cc=\(country)&l=schinese"
        ) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SteamError.diagnostic("游戏 \(appID) 的核实请求失败。")
        }

        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let entry = root[appID] as? [String: Any],
              let success = entry["success"] as? Bool,
              success,
              let details = entry["data"] as? [String: Any] else {
            return nil
        }

        guard let groups = details["package_groups"] as? [[String: Any]] else {
            return nil
        }

        var isPermanentPromotion = false

        for group in groups {
            guard let subs = group["subs"] as? [[String: Any]] else {
                continue
            }

            for sub in subs {
                let optionText = (
                    sub["option_text"] as? String ?? ""
                ).lowercased()

                let price = sub["price_in_cents_with_discount"] as? Int

                if optionText.contains("limited free promotional package"),
                   price == 0 {
                    isPermanentPromotion = true
                    break
                }
            }

            if isPermanentPromotion {
                break
            }
        }

        guard isPermanentPromotion,
              let storeURL = URL(
                string: "https://store.steampowered.com/app/\(appID)/"
              ) else {
            return nil
        }

        return SteamGame(
            appID: appID,
            name: details["name"] as? String ?? fallbackName,
            storeURL: storeURL
        )
    }

    // MARK: 解码 HTML 实体

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text

        let replacements: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " ")
        ]

        for (encoded, decoded) in replacements {
            result = result.replacingOccurrences(
                of: encoded,
                with: decoded
            )
        }

        return result
    }
}

// MARK: - 错误信息

enum SteamError: LocalizedError {
    case diagnostic(String)

    var errorDescription: String? {
        switch self {
        case .diagnostic(let message):
            return message
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var store = SteamStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.blue)

                    Text("Steam 永久限免")
                        .font(.title2.bold())

                    Text("筛选限时免费领取、领取后永久保留的游戏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

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

                            Text(store.isLoading ? "正在查询……" : "刷新限免列表")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isLoading)
                }
                .padding()

                if let updated = store.lastUpdated {
                    Text("上次检查：\(updated.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }

                Text(store.message)
                    .font(.footnote)
                    .foregroundStyle(
                        store.message.hasPrefix("获取失败") ? .red : .secondary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)

                if store.games.isEmpty && !store.isLoading {
                    Spacer()

                    Image(systemName: "gamecontroller")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)

                    Text("暂时没有核实到游戏")
                        .font(.headline)
                        .padding(.top, 8)

                    Text("点击上方按钮重新查询。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()
                } else {
                    List(store.games) { game in
                        Link(destination: game.storeURL) {
                            HStack(spacing: 12) {
                                Image(systemName: "gamecontroller.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)

                                VStack(alignment: .leading, spacing: 5) {
                                    Text(game.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)

                                    Text("App ID：\(game.appID)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text("打开 Steam 商店确认领取")
                                        .font(.caption)
                                        .foregroundStyle(.blue)
                                }

                                Spacer()

                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                }

                Divider()

                Text("本应用目前只查询和筛选，不会自动领取。最终资格以 Steam 商店页面为准。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .navigationTitle("永久限免助手")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    ContentView()
}
