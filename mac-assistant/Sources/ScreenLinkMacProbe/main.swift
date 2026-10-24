import AppKit
import ApplicationServices
import Foundation
import ScreenLinkMacCore

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

final class Probe {
    private let process: NSRunningApplication
    private let root: AXUIElement
    private let showAllowedText: Bool
    private var observer: AXObserver?
    private var baseline: [AXUIElement] = []
    private var emitted: [AXUIElement] = []
    private let maxNodes = 256
    private var finished = false

    init(process: NSRunningApplication, showAllowedText: Bool) {
        self.process = process
        self.root = AXUIElementCreateApplication(process.processIdentifier)
        self.showAllowedText = showAllowedText
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private func role(_ element: AXUIElement) -> String {
        // Roles are structural AX enums; don't print an unexpected custom string.
        let raw = value(element, kAXRoleAttribute) as? String ?? ""
        let known: Set<String> = ["AXApplication", "AXWindow", "AXGroup", "AXScrollArea", "AXStaticText",
                                  "AXButton", "AXImage", "AXList", "AXLayoutArea", "AXUnknown"]
        return known.contains(raw) ? raw : "other"
    }

    private func tree() -> [(AXUIElement, Int)] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var result: [(AXUIElement, Int)] = []
        var index = 0
        while index < queue.count && result.count < maxNodes {
            let (element, depth) = queue[index]; index += 1
            if result.contains(where: { CFEqual($0.0, element) }) { continue }
            result.append((element, depth))
            guard depth < 8,
                  let children = value(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children.prefix(maxNodes - result.count) { queue.append((child, depth + 1)) }
        }
        return result
    }

    func start(seconds: Double) -> Bool {
        // Only node identities are remembered. Existing title/value/description is never read.
        baseline = tree().map(\.0)
        var created: AXObserver?
        let status = AXObserverCreate(process.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            let probe = Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue()
            probe.scan(reason: notification as String)
        }, &created)
        if status == .success, let created {
            observer = created
            let context = Unmanaged.passUnretained(self).toOpaque()
            for event in [kAXWindowCreatedNotification, kAXLayoutChangedNotification] {
                let status = AXObserverAddNotification(created, root, event as CFString, context)
                emit(["kind": "observer", "event": event, "status": status.rawValue])
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
        } else {
            emit(["kind": "observer-unavailable", "status": status.rawValue])
        }
        emit(["kind": "baseline", "nodes": baseline.count, "textRead": false,
              "seconds": seconds, "forwarding": false])
        // Bounded polling handles platforms which don't expose AX notification events.
        // It inspects only NotificationCenter, never all windows or other processes.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.scan(reason: "bounded-poll")
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !process.isTerminated {
            RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.2)))
        }
        finished = true
        timer.invalidate()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        self.observer = nil
        emit(["kind": "finished", "newNodes": emitted.count, "forwarded": 0])
        return true
    }

    private func scan(reason: String) {
        guard !finished, emitted.count < 512 else { return }
        for (element, depth) in tree() {
            guard !baseline.contains(where: { CFEqual($0, element) }),
                  !emitted.contains(where: { CFEqual($0, element) }) else { continue }
            emitted.append(element)
            var pid: pid_t = 0
            let pidStatus = AXUIElementGetPid(element, &pid)
            let owner = pidStatus == .success ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil
            let source = SourceIdentity.allowedAXOwner(bundleIdentifier: owner)
            var names: CFArray?
            AXUIElementCopyAttributeNames(element, &names)
            let attributeNames = names as? [String] ?? []
            // Print only known attribute names, never identifiers/descriptions that may embed content.
            let structural = [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute, kAXTitleAttribute,
                              kAXValueAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
            var report: [String: Any] = ["kind": "new-node", "trigger": reason,
                "depth": depth, "role": role(element), "source": source?.rawValue ?? "unknown",
                "attributes": structural.filter { attributeNames.contains($0) }, "contentState": "unknown"]
            if showAllowedText, let source {
                // Most NotificationCenter nodes belong to NotificationCenter itself, so
                // this deliberately remains closed until real attribution is possible.
                var exposed: [String: String] = [:]
                for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                    if let text = value(element, attribute) as? String, !text.isEmpty {
                        if text.count <= 4096 { exposed[attribute] = text }
                        else { report["contentState"] = "truncated" }
                    }
                }
                report["appName"] = source.appName
                report["exposedText"] = exposed
            }
            emit(report)
            if emitted.count >= 512 { break }
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["permission-status"] {
    emit(["trusted": AXIsProcessTrusted(), "requested": false])
} else if arguments == ["request-permission"] {
    // This command alone may prompt. Ordinary probe/check commands never request permission.
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    emit(["trusted": AXIsProcessTrustedWithOptions(options), "requested": true])
} else if arguments.first == "probe" {
    let showText = arguments.contains("--show-allowed-text")
    let numeric = arguments.dropFirst().filter { $0 != "--show-allowed-text" }
    let seconds = numeric.first.flatMap(Double.init) ?? 60
    guard numeric.count <= 1, seconds >= 5, seconds <= 120 else {
        emit(["error": "duration-must-be-5-to-120-seconds"]); exit(2)
    }
    guard AXIsProcessTrusted() else { emit(["error": "accessibility-permission-required"]); exit(3) }
    guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
        emit(["error": "notification-center-process-not-running"]); exit(4)
    }
    _ = Probe(process: process, showAllowedText: showText).start(seconds: seconds)
} else {
    print("Usage: screenlink-mac-probe permission-status | request-permission | probe [5..120 seconds] [--show-allowed-text]")
}
