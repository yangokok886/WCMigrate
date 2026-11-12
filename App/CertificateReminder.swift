import SwiftUI
import UserNotifications
import Security

@MainActor final class CertificateReminder: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var enabled = UserDefaults.standard.bool(forKey: "certificateReminderEnabled")
    @Published var days = UserDefaults.standard.object(forKey: "certificateReminderDays") as? Int ?? 7
    @Published var profile: ProvisioningProfile?
    @Published var status = "正在读取签名描述文件…"
    @Published var permission = "未开启"
    @Published var error: String?
    private let center = UNUserNotificationCenter.current()
    private let prefix = "wcmigrate.certificate."
    private var revision = 0
    override init() { super.init(); center.delegate = self }
    var certificateNames: String {
        guard let profile else { return "未检测到" }
        let names = profile.activeCertificates.map { item -> String in
            guard let certificate = SecCertificateCreateWithData(nil, item.data as CFData) else { return "证书无法解析" }
            return SecCertificateCopySubjectSummary(certificate) as String? ?? "未命名证书"
        }
        return names.isEmpty ? "描述文件未包含证书" : names.joined(separator: "\n")
    }
    var certificateExpiryText: String {
        guard let profile else { return "无法检测" }
        guard let expires = profile.activeCertificates.compactMap(\.expires).min() else { return "无法解析证书到期时间" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy 年 M 月 d 日 H 时 m 分"
        return formatter.string(from: expires)
    }
    func refresh() async {
        do {
            if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") {
                var parsed = try ProvisioningProfile.decode(Data(contentsOf: url))
                if let executable = Bundle.main.executableURL { parsed.identifySigner(in: try Data(contentsOf: executable, options: .mappedIfSafe)) }
                profile = parsed
                status = profile!.deadline <= Date() ? "已到期" : "已读取本机签名信息"
            } else { profile = nil; status = "未包含描述文件，无法检测到期时间（可能为临时签名或模拟器）" }
        } catch { profile = nil; status = "描述文件解析失败：\(error.localizedDescription)" }
        await schedule(requestPermission: false)
    }
    func setEnabled(_ value: Bool) async {
        enabled = value; UserDefaults.standard.set(value, forKey: "certificateReminderEnabled")
        await schedule(requestPermission: value)
    }
    func setDays(_ value: Int) async {
        guard [3, 7, 15, 30].contains(value) else { return }
        days = value; UserDefaults.standard.set(value, forKey: "certificateReminderDays")
        await schedule(requestPermission: false)
    }
    private func schedule(requestPermission: Bool) async {
        revision += 1; let token = revision
        if requestPermission {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            catch { self.error = "通知授权失败：\(error.localizedDescription)" }
        }
        let settings = await center.notificationSettings()
        guard token == revision else { return }
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral
        permission = authorized ? "通知已允许" : (settings.authorizationStatus == .notDetermined ? "尚未授权通知" : "通知未允许，请在系统设置中开启")
        var scheduled = UserDefaults.standard.dictionary(forKey: "certificateReminderScheduledDates") as? [String: Double] ?? [:]
        // Record elapsed requests before rebuilding; foreground refresh must not issue a second
        // alert on the same date even if the user already dismissed it from Notification Center.
        for (key, timestamp) in scheduled where timestamp <= Date().timeIntervalSince1970 {
            UserDefaults.standard.set(true, forKey: "certificateScheduled." + key)
        }
        var requests: [UNNotificationRequest] = []
        if enabled, authorized, let profile {
            let now = Date(); let dates = CertificateReminderPlan.dates(deadline: profile.deadline, days: days, now: now)
            let calendar = Calendar.current
            for date in dates {
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                let key = "\(profile.uuid).\(c.year!).\(c.month!).\(c.day!)"
                let id = prefix + key
                // This persists even when the user dismisses a delivered notification.
                if calendar.isDate(date, inSameDayAs: now), UserDefaults.standard.bool(forKey: "certificateScheduled." + key) { continue }
                let content = UNMutableNotificationContent(); content.title = "WCMigrate 签名即将到期"
                content.body = "\(certificateNames)\n有效截止：\(profile.deadline.formatted(date: .abbreviated, time: .shortened))。请及时重新签名。"
                content.sound = .default
                content.userInfo = ["certificateDay": key]
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                requests.append(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
            }
        }
        let pending = await center.pendingNotificationRequests()
        guard token == revision else { return }
        let wanted = Set(requests.map(\.identifier))
        // Keep today's already scheduled alert even when refresh has marked it as scheduled.
        let todayKey: String? = profile.map { profile in
            let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            return prefix + "\(profile.uuid).\(c.year!).\(c.month!).\(c.day!)"
        }
        let removed = pending.filter { $0.identifier.hasPrefix(prefix) && (!enabled || !authorized || (!wanted.contains($0.identifier) && ($0.identifier != todayKey || profile?.deadline ?? .distantPast <= Date()))) }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: removed)
        for id in removed {
            let key = String(id.dropFirst(prefix.count))
            if let timestamp = scheduled[key], timestamp > Date().timeIntervalSince1970 { scheduled.removeValue(forKey: key) }
        }
        UserDefaults.standard.set(scheduled, forKey: "certificateReminderScheduledDates")
        if !enabled {
            let delivered = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: delivered.filter { $0.request.identifier.hasPrefix(prefix) }.map { $0.request.identifier })
        }
        for request in requests {
            guard token == revision else { return }
            if pending.contains(where: { $0.identifier == request.identifier }) { continue }
            do {
                try await center.add(request)
                guard token == revision else { center.removePendingNotificationRequests(withIdentifiers: [request.identifier]); return }
                if let key = request.content.userInfo["certificateDay"] as? String,
                   let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() {
                    scheduled[key] = date.timeIntervalSince1970
                    UserDefaults.standard.set(scheduled, forKey: "certificateReminderScheduledDates")
                }
            } catch { self.error = "提醒安排失败：\(error.localizedDescription)" }
        }
        if enabled, authorized, profile != nil { permission = "每天 09:00 提醒一次；进入提醒期后开启会立即提醒" }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

struct CertificateReminderSection: View {
    @ObservedObject var reminder: CertificateReminder
    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { reminder.enabled }, set: { value in Task { await reminder.setEnabled(value) } })) {
                SettingsRowLabel(title: "证书到期提醒", icon: "bell.badge")
            }.accessibilityIdentifier("certificateReminderToggle")
            SettingsValueRow(title: "证书昵称", icon: "person.text.rectangle", value: reminder.certificateNames, detail: true)
            SettingsValueRow(title: "证书到期时间", icon: "checkmark.seal", value: reminder.certificateExpiryText, detail: true)
                .accessibilityIdentifier("certificateExpiryRow")
            if let profile = reminder.profile {
                if profile.activeCertificates.count > 1 {
                    Text("未能唯一匹配实际签名证书，显示候选证书昵称及其中最早的证书到期时间。").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(reminder.status).font(.footnote).foregroundStyle(.secondary)
            }
            if reminder.enabled {
                Picker(selection: Binding(get: { reminder.days }, set: { value in Task { await reminder.setDays(value) } })) {
                    Text("前三天").tag(3); Text("前一周").tag(7); Text("前半个月（15天）").tag(15); Text("前一个月（30天）").tag(30)
                } label: { SettingsRowLabel(title: "开始提醒", icon: "clock") }
                Text(reminder.permission).font(.footnote).foregroundStyle(.secondary)
                if reminder.profile?.deadline ?? .distantFuture <= Date() { Text("签名有效期已结束，请重新签名。").font(.footnote).foregroundStyle(.orange) }
                if reminder.permission.contains("系统设置"), let url = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: url) { SettingsRowLabel(title: "打开通知设置", icon: "arrow.up.right.square") }.tint(.primary)
                }
            }
        } header: { Text("签名与通知") } footer: {
            Text("以描述文件与证书中较早的到期时间为准，进入提醒期后每天通知一次，持续到到期当日。通知由系统安排，关闭应用也可提醒；提前撤销的证书无法仅靠描述文件检测。")
        }
        .alert("通知安排失败", isPresented: Binding(get: { reminder.error != nil }, set: { if !$0 { reminder.error = nil } })) { Button("知道了") { reminder.error = nil } } message: { Text(reminder.error ?? "") }
    }
}
