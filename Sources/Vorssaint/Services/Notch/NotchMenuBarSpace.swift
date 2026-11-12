// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

/// Geometry only: never reads menu titles, opens menus or requests permission.
/// Run off-main. Missing geometry fails closed rather than covering a menu.
enum NotchMenuBarSpace {
    /// MenuBarAgent exposes its centre window at the occupied points even
    /// though the accessibility window's frame spans the entire display.
    static func systemCapsule(geometry: NotchGeometry, primaryTop: CGFloat) -> NotchSystemCapsule? {
        guard AXIsProcessTrusted(), let agent = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.MenuBarAgent").first else { return nil }
        let app = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.025)
        let x = geometry.screen.midX
        let screenTop = primaryTop - geometry.screen.maxY
        let centreY = NotchLayout.hardwareCapsuleTopInset + NotchLayout.hardwareSystemPill.height / 2
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        var capsuleWindow: AXUIElement?
        func contains(_ offset: CGFloat, _ y: CGFloat) -> Bool? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var hit: AXUIElement?
            switch AXUIElementCopyElementAtPosition(app, Float(x + offset), Float(screenTop + y), &hit) {
            case .noValue, .notImplemented: return false
            case .success: break
            default: return nil
            }
            for _ in 0..<4 {
                guard let element = hit else { return false }
                if let capsuleWindow, CFEqual(element, capsuleWindow) { return true }
                if value(element, kAXIdentifierAttribute) as? String == "ax-center-hud-window" {
                    capsuleWindow = element
                    return true
                }
                guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID()
                else { return false }
                hit = unsafeBitCast(parent, to: AXUIElement.self)
            }
            return false
        }
        guard contains(0, centreY) == true,
              let width = NotchLayout.expandedSystemCapsuleWidth(radius: min(320, geometry.screen.width / 2 - 12),
                                                                contains: { contains($0, centreY) }),
              let vertical = NotchLayout.systemCapsuleVerticalOffsets(contains: { contains(0, $0) }) else { return nil }
        return NotchSystemCapsule(width: width, topOffset: vertical.top, bottomOffset: vertical.bottom)
    }

    static func measure(pid: pid_t, geometry: NotchGeometry, primaryTop: CGFloat,
                        ownWindow: Int) -> CGFloat? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let rawMenu = value(app, kAXMenuBarAttribute),
              CFGetTypeID(rawMenu) == AXUIElementGetTypeID() else { return nil }
        let menu = unsafeBitCast(rawMenu, to: AXUIElement.self)
        guard let rawItems = value(menu, kAXChildrenAttribute),
              CFGetTypeID(rawItems) == CFArrayGetTypeID(),
              let items = rawItems as? [AXUIElement], !items.isEmpty, items.count <= 64 else { return nil }
        let deadline = Date().addingTimeInterval(0.25)
        var menuItems: [CGRect] = []
        for item in items {
            guard Date() < deadline, let rect = frame(item, primaryTop: primaryTop) else { return nil }
            menuItems.append(rect)
        }
        var statusItems: [CGRect] = []
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard let number = window[kCGWindowNumber as String] as? Int, number != ownWindow,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer >= Int(CGWindowLevelForKey(.statusWindow)),
                  layer <= Int(CGWindowLevelForKey(.statusWindow)) + 1,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 0, width < geometry.screen.width - 2,
                  height > 0, height <= geometry.menuBarHeight + 2 else { continue }
            statusItems.append(CGRect(x: x, y: primaryTop - y - height, width: width, height: height))
        }
        // AX may describe only another display's menu bar. Require an item on
        // the selected display before status items can further constrain it.
        return NotchMenuBarLayout.measuredSideRoom(screen: geometry.screen, cameraWidth: geometry.cameraWidth,
                                                   barHeight: geometry.menuBarHeight,
                                                   menuItems: menuItems, statusItems: statusItems)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func frame(_ element: AXUIElement, primaryTop: CGFloat) -> CGRect? {
        guard let rawPosition = value(element, kAXPositionAttribute), CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              let rawSize = value(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        let position = unsafeBitCast(rawPosition, to: AXValue.self)
        let size = unsafeBitCast(rawSize, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(x: point.x, y: primaryTop - point.y - dimensions.height,
                      width: dimensions.width, height: dimensions.height)
    }
}
