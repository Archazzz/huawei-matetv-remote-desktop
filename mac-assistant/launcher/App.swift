import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var status: NSTextField!
    var start: NSButton!
    var stop: NSButton!
    var worker: Process?
    var output: Pipe?
    var pending = Data()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "屏间 · 微信通知助手"
        window.center()
        let title = NSTextField(labelWithString: "微信通知同步")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.frame = NSRect(x: 28, y: 202, width: 460, height: 30)
        let detail = NSTextField(wrappingLabelWithString: "只同步开始监听后新增的微信系统通知。请仅为这个助手开启完全磁盘访问权限；无需授权 Codex 或终端。")
        detail.frame = NSRect(x: 28, y: 144, width: 460, height: 48)
        status = NSTextField(wrappingLabelWithString: "尚未开始监听")
        status.frame = NSRect(x: 28, y: 92, width: 460, height: 44)
        start = NSButton(title: "开始监听", target: self, action: #selector(startListening))
        start.frame = NSRect(x: 24, y: 32, width: 110, height: 34)
        stop = NSButton(title: "停止", target: self, action: #selector(stopListening))
        stop.frame = NSRect(x: 142, y: 32, width: 80, height: 34)
        stop.isEnabled = false
        let settings = NSButton(title: "完全磁盘访问设置", target: self, action: #selector(openSettings))
        settings.frame = NSRect(x: 290, y: 32, width: 200, height: 34)
        for view in [title, detail, status, start, stop, settings].compactMap({ $0 }) { window.contentView?.addSubview(view) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func startListening() {
        guard worker == nil, let resources = Bundle.main.resourceURL else { return }
        do {
            let bytes = try Data(contentsOf: resources.appendingPathComponent("runtime.json"))
            guard let runtime = try JSONSerialization.jsonObject(with: bytes) as? [String: String],
                  let python = runtime["python"], let config = runtime["config"] else { throw NSError(domain: "runtime", code: 1) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [resources.appendingPathComponent("wechat_listener.py").path, "listen", "--config", config]
            let pipe = Pipe()
            output = pipe
            pending.removeAll()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                DispatchQueue.main.async { self?.receive(data) }
            }
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.output?.fileHandleForReading.readabilityHandler = nil
                    self?.worker = nil
                    self?.start.isEnabled = true
                    self?.stop.isEnabled = false
                }
            }
            try process.run()
            worker = process
            start.isEnabled = false
            stop.isEnabled = true
            status.stringValue = "正在检查系统通知访问权限…"
        } catch {
            status.stringValue = "无法启动，请检查助手配置及 Python 安装。"
        }
    }

    func receive(_ data: Data) {
        pending.append(data)
        if pending.count > 16384 { pending.removeAll(); return }
        while let end = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: end)
            pending.removeSubrange(...end)
            guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let state = event["state"] as? String else { continue }
            switch state {
            case "listening": status.stringValue = "正在监听新的微信通知。关闭助手即可停止。"
            case "batch":
                let count = event["accepted"] as? Int ?? 0
                let failures = event["deliveryFailures"] as? Int ?? 0
                status.stringValue = "中转已接收 \(count) 条；投递失败 \(failures) 条。"
            case "access_denied": status.stringValue = "请在完全磁盘访问中添加并开启此助手，然后退出、重新打开。"
            case "source_unsupported_or_unavailable": status.stringValue = "系统通知格式尚不支持或暂不可用，已停止。"
            case "source_or_config_missing": status.stringValue = "尚未找到系统通知存储或本地配置，已停止。"
            case "configuration_or_delivery_error": status.stringValue = "配置或证书检查失败，已停止。"
            case "source_rebaselined": status.stringValue = "系统通知存储已变化，仅继续监听之后的新通知。"
            case "stopped": status.stringValue = "已停止监听"
            default: break
            }
        }
    }

    @objc func stopListening() {
        if let worker, worker.isRunning { worker.terminate() }
        stop.isEnabled = false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        output?.fileHandleForReading.readabilityHandler = nil
        if let worker, worker.isRunning { worker.terminate() }
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
