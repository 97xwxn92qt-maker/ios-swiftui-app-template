
import SwiftUI
import Foundation

// MARK: - 游戏模型

struct SteamGame: Identifiable, Hashable {
    let appID: String
    let name: String
    let storeURL: URL

    var id: String { appID }
}

// MARK: - Steam 数据服务

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var message = "点击刷新，查询 Steam 永久限免游戏。"
    @Published var lastUpdated: Date?

    private let country = "sg"

    // MARK: 刷新游戏列表

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        message = "正在查询 Steam 活动……"

        defer {
            isLoading = false
        }

        do {
            let candidates = try await fetchCandidates()

            if candidates.isEmpty {
                games = []
                lastUpdated = Date()
                message = "Steam 接口已响应，但没有找到候选游戏。请稍后重试。"
                return
            }

            message = "找到 \(candidates.count) 个候选游戏，正在核实永久限免……"

            var verified: [SteamGame] = []
            var checkedCount = 0

            for candidate in candidates.prefix(50) {
                checkedCount += 1

                do {
                    if let game = try await verifyPromotion(
                        appID: candidate.appID,
                        name: candidate.name
                    ) {
                        verified.append(game)
                    }
                } catch {
                    // 单个游戏接口失败时继续检查其他游戏
                    continue
                }
            }

            games = verified.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            lastUpdated = Date()

            if verified.isEmpty {
                message = """
                已检查 \(checkedCount) 个候选游戏，暂未核实到符合条件的永久限免。
                这不代表 Steam 当前一定没有活动；搜索接口可能未返回相关活动。
                """
            } else {
                message = "核实到 \(verified.count) 款永久限免候选游戏。请打开商店页面确认领取条件。"
            }
        } catch {
            games = []
            message = "获取失败：\(error.localizedDescription)"
        }
    }

    // MARK: 获取搜索候选

    private func fetchCandidates() async throws -> [(appID: String, name: String)] {
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
        request.setValue(
            "Mozilla/5.0",
            forHTTPHeaderField: "User-Agent"
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

        guard let raw = String(data: data, encoding: .utf8) else {
            throw SteamError.diagnostic("Steam 返回的内容无法按 UTF-8 解码。")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            let preview = String(raw.prefix(180))
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")

            throw SteamError.diagnostic(
                "Steam 没有返回 JSON。响应开头：\(preview)"
            )
        }

        guard let html = json["results_html"] as? String else {
            let keys = json.keys.sorted().joined(separator: ", ")
            throw SteamError.diagnostic(
                "Steam 响应缺少 results_html 字段。现有字段：\(keys)"
            )
        }

        return parseCandidates(html)
    }

    // MARK: 从搜索 HTML 解析候选游戏

    private func parseCandidates(
        _ html: String
    ) -> [(appID: String, name: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"data-ds-appid="([^"]+)""#,
            options: []
        ) else {
            return []
        }

        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHTML.length)
        )

        var results: [(appID: String, name: String)] = []
        var seen = Set<String>()

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }

            let appIDString = nsHTML.substring(
                with: match.range(at: 1)
            )

            // 一个搜索结果可能同时包含多个 app ID
            let appIDs = appIDString
                .split(separator: ",")
                .map(String.init)

            for appID in appIDs {
                guard !seen.contains(appID) else { continue }
                guard appID.allSatisfy(\.isNumber) else { continue }

                seen.insert(appID)

                let name = extractName(
                    from: html,
                    around: match.range.location
                )

                results.append((
                    appID: appID,
                    name: name.isEmpty ? "Steam 游戏 \(appID)" : name
                ))
            }
        }

        return results
    }

    // MARK: 从 HTML 提取名称

    private func extractName(
        from html: String,
        around location: Int
    ) -> String {
        let nsHTML = html as NSString

        guard nsHTML.length > 0 else {
            return ""
        }

        let start = max(0, location - 500)
        let length = min(1800, nsHTML.length - start)

        guard length > 0 else {
            return ""
        }

        let fragment = nsHTML.substring(
            with: NSRange(location: start, length: length)
        )

        let patterns = [
            #"class="title"[^>]*>(.*?)</span>"#,
            #"class="[^"]*title[^"]*"[^>]*>(.*?)</span>"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else {
                continue
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
                continue
            }

            var name = nsFragment.substring(
                with: match.range(at: 1)
            )

            name = name.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )

            name = decodeHTMLEntities(name)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !name.isEmpty {
                return name
            }
        }

        return ""
    }

    // MARK: 处理 HTML 实体

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

    // MARK: 核实是否属于永久限免促销

    private func verifyPromotion(
        appID: String,
        name: String
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
        request.setValue(
            "https://store.steampowered.com/",
            forHTTPHeaderField: "Referer"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }

        guard let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let appEntry = root[appID] as? [String: Any],
              let success = appEntry["success"] as? Bool,
              success,
              let details = appEntry["data"] as? [String: Any] else {
            return nil
        }

        // 仅检查明确标记为 Limited Free Promotional Package 的订阅包
        guard let packageGroups = details["package_groups"] as? [[String: Any]] else {
            return nil
        }

        var isLimitedFreePromotion = false

        for group in packageGroups {
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
                    isLimitedFreePromotion = true
                    break
                }
            }

            if isLimitedFreePromotion {
                break
            }
        }

        guard isLimitedFreePromotion else {
            return nil
        }

        guard let storeURL = URL(
            string: "https://store.steampowered.com/app/\(appID)/"
        ) else {
            return nil
        }

        let officialName = details["name"] as? String ?? name

        return SteamGame(
            appID: appID,
            name: officialName,
            storeURL: storeURL
        )
    }
}

// MARK: - 错误信息

enum SteamError: LocalizedError {
    case badResponse
    case invalidData
    case diagnostic(String)

    var errorDescription: String? {
        switch self {
        case .badResponse:
            return "Steam 服务器暂时无法访问。"

        case .invalidData:
            return "Steam 返回的数据格式不符合预期。"

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

                    Text("筛选限时免费领取、领取后永久保留的游戏活动")
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

                if let lastUpdated = store.lastUpdated {
                    Text(
                        "上次检查：\(lastUpdated.formatted(date: .abbreviated, time: .shortened))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                }

                Text(store.message)
                    .font(.footnote)
                    .foregroundStyle(
                        store.message.hasPrefix("获取失败")
                            ? .red
                            : .secondary
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

                    Text("可以点击上方按钮重新查询。")
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

                Text("本应用只负责查询和筛选，不会自动领取。Steam 活动信息可能变化，请以商店页面为准。")
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
