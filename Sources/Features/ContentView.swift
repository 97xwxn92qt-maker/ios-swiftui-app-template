
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

// MARK: - 未来活动模型

struct SteamPromotion: Identifiable {
    let id: String
    let name: String
    let type: String
    let dateText: String
    let startDate: Date?
    let endDate: Date?
    let storeURL: URL?
    let isPrediction: Bool
}

// MARK: - Steam 数据服务

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var message = "点击刷新，查询 Steam 永久限免活动。"

    @Published var promotions: [SteamPromotion] = []
    @Published var isLoadingPromotions = false
    @Published var promotionMessage = "点击刷新，获取 SteamDB 活动时间表。"

    private let country = "sg"

    // MARK: 正在限免

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        message = "正在查询 Steam 活动……"
        defer { isLoading = false }

        do {
            let candidates = try await fetchCandidates()

            guard !candidates.isEmpty else {
                games = []
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

            if !verified.isEmpty {
                message = "核实到 \(verified.count) 款永久限免候选游戏。"
            } else if failedCount == candidates.count {
                message = "候选游戏已找到，但核实请求全部失败，请检查网络后重试。"
            } else {
                message = "已检查 \(candidates.count) 个候选游戏，暂未核实到符合条件的永久限免。"
            }
        } catch {
            games = []
            message = "获取失败：\(error.localizedDescription)"
        }
    }

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

        if let items = json["items"] as? [[String: Any]] {
            for item in items {
                let name = decodeHTMLEntities(
                    item["name"] as? String ?? ""
                )
                let logo = item["logo"] as? String ?? ""

                guard let appID = extractAppID(from: logo),
                      seen.insert(appID).inserted else {
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
            throw SteamError.diagnostic(
                "没有解析到游戏 ID。Steam 返回字段：\(keys)"
            )
        }

        return candidates
    }

    private func extractAppID(from text: String) -> String? {
        let pattern = #"/apps/([0-9]+)/"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)

        guard let match = regex.firstMatch(in: text, range: range),
              let idRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        return String(text[idRange])
    }

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
              let details = entry["data"] as? [String: Any],
              let groups = details["package_groups"] as? [[String: Any]] else {
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

    // MARK: 未来限免时间表

    func refreshPromotions() async {
        guard !isLoadingPromotions else { return }

        isLoadingPromotions = true
        promotionMessage = "正在读取 SteamDB 活动……"
        defer { isLoadingPromotions = false }

        do {
            let result = try await fetchSteamDBPromotions()
            promotions = result

            if result.isEmpty {
                promotionMessage = "已连接页面，但暂时没有解析到活动。"
            } else {
                promotionMessage = "读取到 \(result.count) 项活动。未来预测不代表活动一定发生。"
            }
        } catch {
            promotionMessage = "获取失败：\(error.localizedDescription)"
        }
    }

    private func fetchSteamDBPromotions() async throws -> [SteamPromotion] {
        guard let url = URL(string: "https://steamdb.info/upcoming/free/") else {
            throw SteamError.diagnostic("SteamDB 网址无效。")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "text/html,application/xhtml+xml",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "https://steamdb.info/",
            forHTTPHeaderField: "Referer"
        )
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SteamError.diagnostic("无法读取 SteamDB 服务器响应。")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw SteamError.diagnostic(
                "SteamDB HTTP 状态码：\(http.statusCode)。网站可能限制了自动访问。"
            )
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw SteamError.diagnostic("SteamDB 页面编码无法识别。")
        }

        let cleanedHTML = html.replacingOccurrences(
            of: #"<!--.*?-->"#,
            with: "",
            options: .regularExpression
        )

        var results: [SteamPromotion] = []
        var seen = Set<String>()

        // 解析页面中的活动表格行。
        let rowPattern = #"<tr\b[^>]*>(.*?)</tr>"#

        if let rowRegex = try? NSRegularExpression(
            pattern: rowPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) {
            let nsHTML = cleanedHTML as NSString
            let rows = rowRegex.matches(
                in: cleanedHTML,
                range: NSRange(location: 0, length: nsHTML.length)
            )

            for row in rows {
                guard row.numberOfRanges > 1 else { continue }

                let rowHTML = nsHTML.substring(with: row.range(at: 1))
                let rowText = stripHTML(rowHTML)

                guard !rowText.isEmpty else { continue }

                let title = extractLinkedTitle(from: rowHTML)
                guard !title.isEmpty else { continue }

                let lower = rowText.lowercased()
                let type: String

                if lower.contains("play for free") ||
                    lower.contains("free weekend") {
                    type = "免费周末"
                } else if lower.contains("dlc") ||
                            lower.contains("downloadable content") {
                    type = "DLC 限免"
                } else if lower.contains("free to keep") {
                    type = "永久限免"
                } else {
                    continue
                }

                let appID = extractAppID(from: rowHTML)
                let storeURL = appID.flatMap {
                    URL(string: "https://store.steampowered.com/app/\($0)/")
                }

                let dates = extractDates(from: rowText)
                let identity = "\(title)|\(dates.start?.timeIntervalSince1970 ?? 0)|\(type)"

                guard seen.insert(identity).inserted else { continue }

                results.append(
                    SteamPromotion(
                        id: identity,
                        name: title,
                        type: type,
                        dateText: dates.text,
                        startDate: dates.start,
                        endDate: dates.end,
                        storeURL: storeURL,
                        isPrediction: false
                    )
                )
            }
        }

        // 解析 SteamDB 的 Potentially Upcoming Free Promotions 列表。
        if let sectionRange = cleanedHTML.range(
            of: "Potentially Upcoming Free Promotions",
            options: .caseInsensitive
        ) {
            let tail = String(cleanedHTML[sectionRange.upperBound...])
            let limitedSection = String(tail.prefix(30000))

            let itemPattern = #"<li\b[^>]*>(.*?)</li>"#

            if let itemRegex = try? NSRegularExpression(
                pattern: itemPattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) {
                let nsTail = limitedSection as NSString
                let items = itemRegex.matches(
                    in: limitedSection,
                    range: NSRange(location: 0, length: nsTail.length)
                )

                for item in items {
                    guard item.numberOfRanges > 1 else { continue }

                    let itemHTML = nsTail.substring(with: item.range(at: 1))
                    let text = stripHTML(itemHTML)

                    guard !text.isEmpty else { continue }

                    let parsed = parseUpcomingLine(text)
                    guard !parsed.name.isEmpty else { continue }

                    let identity = "upcoming|\(text)"
                    guard seen.insert(identity).inserted else { continue }

                    let type: String
                    let lowerName = parsed.name.lowercased()

                    if lowerName.contains("dlc") ||
                        lowerName.contains("soundtrack") ||
                        lowerName.contains("pack") {
                        type = "DLC 限免（预测）"
                    } else {
                        type = "未来活动（预测）"
                    }

                    results.append(
                        SteamPromotion(
                            id: identity,
                            name: parsed.name,
                            type: type,
                            dateText: parsed.dateText,
                            startDate: nil,
                            endDate: nil,
                            storeURL: nil,
                            isPrediction: true
                        )
                    )
                }
            }
        }

        return results.sorted {
            switch ($0.startDate, $1.startDate) {
            case let (a?, b?):
                return a < b
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        }
    }

    private func extractLinkedTitle(from html: String) -> String {
        let pattern = #"<a\b[^>]*>(.*?)</a>"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return ""
        }

        let nsHTML = html as NSString
        let matches = regex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHTML.length)
        )

        for match in matches {
            guard match.numberOfRanges > 1 else { continue }

            let anchor = nsHTML.substring(with: match.range(at: 0))

            guard anchor.contains("/app/") ||
                    anchor.contains("/sub/") else {
                continue
            }

            let inner = nsHTML.substring(with: match.range(at: 1))
            let title = stripHTML(inner)

            if !title.isEmpty {
                return title
            }
        }

        return ""
    }

    private func extractDates(
        from text: String
    ) -> (start: Date?, end: Date?, text: String) {
        let pattern = #"\d{1,2}\s+[A-Za-z]+\s+\d{4}(?:\s*[-–,]\s*\d{1,2}:\d{2}(?::\d{2})?)?"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return (nil, nil, "具体时间请查看 SteamDB")
        }

        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )

        let found = matches.map {
            nsText.substring(with: $0.range)
        }

        let parsedDates = found.compactMap { parseDate($0) }

        if parsedDates.count >= 2 {
            return (
                parsedDates[0],
                parsedDates[1],
                "\(formatDate(parsedDates[0])) — \(formatDate(parsedDates[1]))"
            )
        }

        if let date = parsedDates.first {
            return (date, nil, formatDate(date))
        }

        return (nil, nil, "具体时间请查看 SteamDB")
    }

    private func parseUpcomingLine(
        _ text: String
    ) -> (name: String, dateText: String) {
        // SteamDB 常见形式：Oct 2026: Game Name
        let pattern = #"^([A-Za-z]{3,9}\s+\d{4})\s*:\s*(.+)$"#

        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return (text, "预计时间未确定")
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 2 else {
            return (text, "预计时间未确定")
        }

        return (
            nsText.substring(with: match.range(at: 2)),
            "预计：\(nsText.substring(with: match.range(at: 1)))"
        )
    }

    private func parseDate(_ text: String) -> Date? {
        let formats = [
            "d MMMM yyyy - HH:mm:ss",
            "d MMMM yyyy - HH:mm",
            "d MMMM yyyy, HH:mm:ss",
            "d MMMM yyyy, HH:mm",
            "d MMMM yyyy",
            "d MMM yyyy - HH:mm:ss",
            "d MMM yyyy - HH:mm",
            "d MMM yyyy, HH:mm:ss",
            "d MMM yyyy, HH:mm",
            "d MMM yyyy"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format

            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) {
                return date
            }
        }

        return nil
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func stripHTML(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: #"<script\b[^>]*>.*?</script>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.replacingOccurrences(
            of: #"<style\b[^>]*>.*?</style>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        text = text.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )

        text = decodeHTMLEntities(text)

        return text
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var result = text

        let replacements: [(String, String)] = [
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&#039;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&#8211;", "–"),
            ("&#8212;", "—")
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

// MARK: - 主界面与底部导航

struct ContentView: View {
    @StateObject private var store = SteamStore()

    var body: some View {
        TabView {
            currentPromotionsPage
                .tabItem {
                    Label("正在限免", systemImage: "gift.fill")
                }

            upcomingPromotionsPage
                .tabItem {
                    Label("未来时间表", systemImage: "calendar")
                }
        }
    }

    // MARK: 正在限免页面

    private var currentPromotionsPage: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    Image(systemName: "gift.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(.blue)

                    Text("Steam 永久限免")
                        .font(.title2.bold())

                    Text("筛选领取后永久保留的游戏活动")
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

                Text("活动资格以 Steam 商店页面为准。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            .navigationTitle("永久限免助手")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 未来时间表页面

    private var upcomingPromotionsPage: some View {
        NavigationStack {
            Group {
                if store.promotions.isEmpty && !store.isLoadingPromotions {
                    VStack(spacing: 14) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 46))
                            .foregroundStyle(.secondary)

                        Text("未来限免时间表")
                            .font(.title3.bold())

                        Text(store.promotionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Button {
                            Task {
                                await store.refreshPromotions()
                            }
                        } label: {
                            Label("刷新时间表", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)

                        Link(
                            "在 SteamDB 查看完整活动",
                            destination: URL(
                                string: "https://steamdb.info/upcoming/free/"
                            )!
                        )
                        .font(.footnote)

                        Spacer()
                    }
                    .padding()
                } else if store.isLoadingPromotions && store.promotions.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在读取 SteamDB 活动……")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    List {
                        Section {
                            Text(store.promotionMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(store.promotions) { promotion in
                            PromotionRow(promotion: promotion)
                        }

                        Section {
                            Text("预测活动可能取消、变更或未能如期上线。免费周末通常只提供限时游玩，不代表游戏永久入库。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Link(
                                "打开 SteamDB 原始时间表",
                                destination: URL(
                                    string: "https://steamdb.info/upcoming/free/"
                                )!
                            )
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await store.refreshPromotions()
                    }
                }
            }
            .navigationTitle("未来限免时间表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await store.refreshPromotions()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoadingPromotions)
                }
            }
        }
    }
}

// MARK: - 活动卡片

struct PromotionRow: View {
    let promotion: SteamPromotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text(promotion.name)
                        .font(.headline)

                    Text(promotion.type)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(iconColor)

                    Text(promotion.dateText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if promotion.isPrediction {
                    Text("预计")
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }

            if let url = promotion.storeURL {
                Link(destination: url) {
                    Label("查看 Steam 商店", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .padding(.leading, 36)
            }
        }
        .padding(.vertical, 5)
    }

    private var iconName: String {
        if promotion.type.contains("免费周末") {
            return "clock"
        }

        if promotion.type.contains("DLC") {
            return "puzzlepiece.extension"
        }

        return "gift.fill"
    }

    private var iconColor: Color {
        if promotion.type.contains("免费周末") {
            return .orange
        }

        if promotion.type.contains("DLC") {
            return .purple
        }

        return .blue
    }
}

#Preview {
    ContentView()
}
