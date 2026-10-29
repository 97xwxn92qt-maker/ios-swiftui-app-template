
import SwiftUI
import UIKit
import UserNotifications

struct SteamGame: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

@MainActor
final class SteamStore: ObservableObject {
    @Published var games: [SteamGame] = []
    @Published var isLoading = false
    @Published var message = "点击刷新查询当前限免游戏"

    func refresh() async {
        guard !isLoading else { return }

        isLoading = true
        message = "正在查询 Steam…"
        defer { isLoading = false }

        do {
            let searchURL = URL(
                string: "https://store.steampowered.com/search/results/?specials=1&maxprice=free&json=1&count=50&cc=sg&l=schinese"
            )!

            var request = URLRequest(url: searchURL)
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Accept"
            )

            let (data, response) = try await URLSession.shared.data(
                for: request
            )

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw NSError(
                    domain: "SteamStore",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Steam 搜索接口请求失败"
                    ]
                )
            }

            guard let json = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                throw NSError(
                    domain: "SteamStore",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Steam 返回的数据格式不正确"
                    ]
                )
            }

            var candidates: [(id: String, name: String)] = []
            var seen = Set<String>()

            for item in items {
                guard let name = item["name"] as? String,
                      let logo = item["logo"] as? String,
                      let range = logo.range(
                        of: #"/apps/(\d+)/"#
                    ) else {
                    continue
                }

                let id = String(logo[range])
                    .split(separator: "/")
                    .dropFirst()
                    .first
                    .map(String.init) ?? ""

                guard !id.isEmpty, seen.insert(id).inserted else {
                    continue
                }

                candidates.append((id, name))
            }

            var results: [SteamGame] = []

            for candidate in candidates {
                if Task.isCancelled { break }

                if await isPermanentFree(candidate.id) {
                    results.append(
                        SteamGame(
                            id: candidate.id,
                            name: candidate.name
                                .replacingOccurrences(
                                    of: "&amp;",
                                    with: "&"
                                ),
                            url: URL(
                                string: "https://store.steampowered.com/app/\(candidate.id)/"
                            )!
                        )
                    )
                }
            }

            games = results
            message = results.isEmpty
                ? "暂时没有检测到符合条件的永久限免游戏"
                : "找到 \(results.count) 款永久限免游戏"

        } catch {
            message = "获取失败：\(error.localizedDescription)"
        }
    }

    private func isPermanentFree(_ appID: String) async -> Bool {
        guard let url = URL(
            string: "https://store.steampowered.com/api/appdetails/?appids=\(appID)&cc=sg&l=schinese"
        ) else {
            return false
        }

        do {
            let (data, _) = try await URLSession.shared.data(
                from: url
            )

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
                    let option = (
                        sub["option_text"] as? String ?? ""
                    ).lowercased()

                    let price = sub["price_in_cents_with_discount"] as? Int

                    if option.contains(
                        "limited free promotional package"
                    ), price == 0 {
                        return true
                    }
                }
            }

        } catch {
            return false
        }

        return false
    }
}

struct ContentView: View {
    @StateObject private var store = SteamStore()
    @State private var deviceToken = SteamAppDelegate.currentToken
    @State private var notificationStatus = "正在检查通知权限"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("永久限免助手")
                            .font(.largeTitle.bold())

                        Text("查询 Steam 当前永久入库优惠")
                            .foregroundStyle(.secondary)

                        Button {
                            Task {
                                await store.refresh()
                            }
                        } label: {
                            HStack {
                                if store.isLoading {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }

                                Text(
                                    store.isLoading
                                    ? "正在刷新…"
                                    : "刷新限免列表"
                                )
                            }
                        }
                        .disabled(store.isLoading)
                        .buttonStyle(.borderedProminent)

                        Text(store.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section("当前限免游戏") {
                    if store.games.isEmpty {
                        Text("刷新后显示查询结果")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(store.games) { game in
                        Link(
                            destination: game.url
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.name)
                                    .font(.headline)

                                Text("永久入库优惠 · Steam")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("iPhone 推送状态") {
                    HStack {
                        Text("通知权限")
                        Spacer()
                        Text(notificationStatus)
                            .foregroundStyle(.secondary)
                    }

                    if deviceToken.isEmpty {
                        Text("尚未获取设备推送令牌")
                            .foregroundStyle(.secondary)

                        Button("重新注册远程推送") {
                            UIApplication.shared
                                .registerForRemoteNotifications()
                        }
                    } else {
                        Text("设备令牌")
                            .font(.headline)

                        Text(deviceToken)
                            .font(.caption2)
                            .textSelection(.enabled)

                        ShareLink(item: deviceToken) {
                            Label(
                                "分享或复制设备令牌",
                                systemImage: "square.and.arrow.up"
                            )
                        }
                    }

                    Text(
                        "云端推送还需要配置 APNs 密钥和 GitHub Actions。获取令牌不代表推送已经测试成功。"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Steam 限免")
            .task {
                await checkNotificationPermission()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .steamDeviceTokenUpdated
                )
            ) { _ in
                deviceToken = SteamAppDelegate.currentToken
            }
        }
    }

    private func checkNotificationPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationStatus = "已允许"
        case .denied:
            notificationStatus = "已拒绝，请在系统设置中开启"
        case .notDetermined:
            let granted = try? await center.requestAuthorization(
                options: [.alert, .sound, .badge]
            )

            notificationStatus = granted == true
                ? "已允许"
                : "未获授权"
        @unknown default:
            notificationStatus = "状态未知"
        }

        if settings.authorizationStatus == .authorized ||
            settings.authorizationStatus == .notDetermined {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
}

extension Notification.Name {
    static let steamDeviceTokenUpdated = Notification.Name(
        "steamDeviceTokenUpdated"
    )
}
