import SwiftUI
import ApplicationServices
import ServiceManagement
import Combine
import AppKit

// MARK: - App Entry Point

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Use Settings scene to run silently in the background without opening a window on launch
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AXError Diagnostics Extension

extension AXError {
    var descriptionString: String {
        switch self.rawValue {
        case 0: return "success (0)"
        case -25200: return "failure (-25200)"
        case -25201: return "illegalArgument (-25201)"
        case -25202: return "invalidUIElement (-25202)"
        case -25203: return "invalidUIElementObserver (-25203)"
        case -25204: return "cannotComplete (-25204) [Check Accessibility Permissions / TCC out of sync]"
        case -25205: return "attributeUnsupported (-25205)"
        case -25206: return "actionUnsupported (-25206)"
        case -25207: return "actionFailed (-25207)"
        case -25208: return "noValue (-25208)"
        case -25209: return "parameterizedAttributeUnsupported (-25209)"
        case -25210: return "notEnoughPrecision (-25210)"
        default: return "unknown (\(self.rawValue))"
        }
    }
}

// MARK: - App Icon Loader Helper

func getAppIcon() -> NSImage {
    // 1. Try to load from compiled Asset Catalog
    if let image = NSImage(named: "AppIcon") {
        return image
    }
    
    // 2. Try bundle resource (icns)
    if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"),
       let image = NSImage(contentsOfFile: path) {
        return image
    }
    
    // 3. Try bundle resource (png)
    if let path = Bundle.main.path(forResource: "AppIcon", ofType: "png"),
       let image = NSImage(contentsOfFile: path) {
        return image
    }
    
    // 4. Try absolute path in development workspace (png)
    let devPath = "/Users/finnegankaiser/Antigravity/MinimizeApps/DockMinimize/AppIcon.png"
    if let image = NSImage(contentsOfFile: devPath) {
        return image
    }
    
    // 5. Fallback to system default application icon image
    return NSApplication.shared.applicationIconImage
}

// MARK: - App Delegate & Status Bar Manager

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var windowDelegate: SettingsWindowDelegate?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy to accessory so the app doesn't show in the Dock
        NSApp.setActivationPolicy(.accessory)
        
        // Start monitoring window activations & dock clicks
        _ = AppManager.shared
        
        // Set up the menu bar status item
        setupStatusItem()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Rescale application icon to standard 18x18 status bar size
            let appIcon = getAppIcon().copy() as! NSImage
            appIcon.size = NSSize(width: 18, height: 18)
            appIcon.isTemplate = true // Allows adapting to dark/light menu bars
            
            button.image = appIcon
        }
        
        // Create standard menu for Left-Click
        let menu = NSMenu()
        
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let infoItem = NSMenuItem(title: "About DockMinimize...", action: #selector(openAbout), keyEquivalent: "")
        infoItem.target = self
        menu.addItem(infoItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        // Directly assigning to statusItem.menu makes Left-click show the menu natively,
        // and Right-click does nothing.
        statusItem.menu = menu
    }
    
    @objc func openSettings() {
        // If settings window already exists, bring it to front
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DockMinimize Settings"
        window.contentViewController = hostingController
        window.center()
        window.isReleasedWhenClosed = false
        
        // Monitor window close to release reference
        windowDelegate = SettingsWindowDelegate { [weak self] in
            self?.settingsWindow = nil
            self?.windowDelegate = nil
        }
        window.delegate = windowDelegate
        
        self.settingsWindow = window
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func openAbout() {
        let alert = NSAlert()
        alert.messageText = "About DockMinimize"
        alert.informativeText = "DockMinimize v1.0.0\n\nA background utility that unminimizes windows when clicking their Dock icon, and minimizes them when clicking their Dock icon while active."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    @objc func quit() {
        NSApp.terminate(nil)
    }
}

class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: () -> Void
    
    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }
    
    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

// MARK: - App Manager & Window Toggle Engine

class AppManager: ObservableObject {
    static let shared = AppManager()
    
    @Published var isListening = false
    
    private var clickMonitor: Any?
    private var lastActivationTime: Date = Date.distantPast
    private var lastActivatedPID: pid_t = 0
    private var lastKnownActivePID: pid_t = 0
    
    init() {
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            lastKnownActivePID = frontmost.processIdentifier
        }
        startListening()
    }
    
    func startListening() {
        guard !isListening else { return }
        
        // 1. Listen for application activations (Dock click on inactive app)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppActivation(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        // 2. Listen for global mouse down events (Dock click on already active app)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleGlobalClick(event)
        }
        
        isListening = true
        print("[DockMinimize Log] Listening successfully started.")
    }
    
    func stopListening() {
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        
        isListening = false
        print("[DockMinimize Log] Listening stopped.")
    }
    
    @objc private func handleAppActivation(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        
        lastActivationTime = Date()
        lastActivatedPID = app.processIdentifier
        lastKnownActivePID = app.processIdentifier
        
        // Ignore our own app
        if app.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        
        // Only run for regular applications (skip background/helper apps)
        guard app.activationPolicy == .regular else {
            return
        }
        
        print("[DockMinimize Log] App activated: \(app.localizedName ?? "Unknown") (PID: \(app.processIdentifier))")
        
        // Delay slightly to allow AX elements to stabilize after app transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.restoreMinimizedWindows(for: app)
        }
    }
    
    private func handleGlobalClick(_ event: NSEvent) {
        let cocoaPoint = NSEvent.mouseLocation
        let point = carbonPoint(from: cocoaPoint)
        
        print("[DockMinimize Log] Left click captured. cocoaPoint: \(cocoaPoint), carbonPoint: \(point)")
        
        var clickedElement: AXUIElement?
        let systemWide = AXUIElementCreateSystemWide()
        let error = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &clickedElement)
        
        guard error == .success, let element = clickedElement else {
            print("[DockMinimize Log] Failed to get UI element at position: \(error.descriptionString)")
            if error == .cannotComplete {
                print("[DockMinimize Log] DIAGNOSTIC TIP: macOS is blocking Accessibility queries. Please go to System Settings > Privacy & Security > Accessibility, select DockMinimize (or the compiler runner app), click '-' to delete it, and toggle/add it back to refresh macOS security database.")
            }
            return
        }
        
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        
        // Make sure the click was on the Dock process
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            print("[DockMinimize Log] Could not find running Dock process!")
            return
        }
        
        guard dockApp.processIdentifier == pid else {
            // Click is outside the Dock process
            return
        }
        
        print("[DockMinimize Log] Click detected INSIDE the Dock process (PID: \(pid))")
        
        // Retrieve the application name from the clicked Dock icon
        guard let appName = getAppName(from: element) else {
            print("[DockMinimize Log] Could not retrieve application name/title from the clicked Dock element hierarchy.")
            return
        }
        
        print("[DockMinimize Log] Clicked Dock Icon Title: '\(appName)'")
        
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            let currentPID = frontmostApp.processIdentifier
            if currentPID != lastKnownActivePID {
                print("[DockMinimize Log] Click changed active app from PID \(lastKnownActivePID) to \(currentPID). Updating active states and ignoring minimize.")
                lastKnownActivePID = currentPID
                lastActivationTime = Date()
                lastActivatedPID = currentPID
                return
            }
            
            let activeName = frontmostApp.localizedName ?? "Unknown"
            print("[DockMinimize Log] Current frontmost application: '\(activeName)' (PID: \(frontmostApp.processIdentifier))")
            
            let isMatch = isAppNameMatch(dockTitle: appName, app: frontmostApp)
            print("[DockMinimize Log] Matching clicked icon '\(appName)' with active '\(activeName)'? Match = \(isMatch)")
            
            if isMatch {
                // To prevent double-minimize/restore loops, check if the app actually has open visible windows.
                // If it has NO visible windows (i.e. only minimized), the user clicked it to unminimize it!
                // So we should NOT minimize it, but let the restore trigger.
                if hasVisibleWindows(for: frontmostApp) {
                    let timeSinceActivation = Date().timeIntervalSince(lastActivationTime)
                    print("[DockMinimize Log] Time since last activation of frontmost app: \(timeSinceActivation)s")
                    
                    if frontmostApp.processIdentifier == lastActivatedPID && timeSinceActivation < 0.4 {
                        print("[DockMinimize Log] Click ignored because the application was recently activated (less than 0.4s ago).")
                        return
                    }
                    
                    // Minimize the active window of this application with a slight delay.
                    print("[DockMinimize Log] Match confirmed! App has visible windows. Minimizing active window of '\(activeName)' in 0.2s...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.minimizeActiveWindow(for: frontmostApp)
                    }
                } else {
                    print("[DockMinimize Log] Match confirmed! App has NO visible windows (only minimized). Attempting restoration...")
                    self.restoreMinimizedWindows(for: frontmostApp)
                }
            }
        } else {
            print("[DockMinimize Log] No active frontmost application found.")
        }
    }
    
    private func getAppName(from element: AXUIElement) -> String? {
        var currentElement = element
        
        // Traverse up to 4 levels to find a title or description attribute (e.g. "Safari")
        for depth in 0..<4 {
            var titleRef: CFTypeRef?
            var descRef: CFTypeRef?
            
            if AXUIElementCopyAttributeValue(currentElement, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[DockMinimize Log] Found title at depth \(depth): '\(trimmed)'")
                return trimmed
            }
            
            if AXUIElementCopyAttributeValue(currentElement, kAXDescriptionAttribute as CFString, &descRef) == .success,
               let desc = descRef as? String, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[DockMinimize Log] Found description at depth \(depth): '\(trimmed)'")
                return trimmed
            }
            
            // Query parent element
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(currentElement, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = parentRef {
                currentElement = parent as! AXUIElement
            } else {
                break
            }
        }
        
        return nil
    }
    
    private func isAppNameMatch(dockTitle: String, app: NSRunningApplication) -> Bool {
        let titleLower = dockTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        if let localizedName = app.localizedName?.lowercased() {
            print("[DockMinimize Log] Checking localizedName: '\(localizedName)' vs '\(titleLower)'")
            if localizedName == titleLower || localizedName.contains(titleLower) || titleLower.contains(localizedName) {
                return true
            }
        }
        
        if let bundleURL = app.bundleURL {
            let filename = bundleURL.deletingPathExtension().lastPathComponent.lowercased()
            print("[DockMinimize Log] Checking bundle filename: '\(filename)' vs '\(titleLower)'")
            if filename == titleLower || filename.contains(titleLower) || titleLower.contains(filename) {
                return true
            }
        }
        
        return false
    }
    
    private func carbonPoint(from cocoaPoint: NSPoint) -> CGPoint {
        guard let primaryScreen = NSScreen.screens.first else {
            return cocoaPoint
        }
        let screenHeight = primaryScreen.frame.height
        return CGPoint(x: cocoaPoint.x, y: screenHeight - cocoaPoint.y)
    }
    
    private func minimizeActiveWindow(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        var focusedWindowRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        
        if error == .success, let focusedWindow = focusedWindowRef {
            let windowElement = focusedWindow as! AXUIElement
            let result = AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            print("[DockMinimize Log] Successfully minimized window. Set attribute result: \(result.descriptionString)")
        } else {
            print("[DockMinimize Log] Failed to get focused window. AXError: \(error.descriptionString)")
            if error == .cannotComplete {
                print("[DockMinimize Log] DIAGNOSTIC TIP: macOS blocked focused window lookup. TCC database mismatch.")
            }
        }
    }
    
    private func hasVisibleWindows(for app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        var windowListRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef)
        
        guard error == .success, let windows = windowListRef as? [AXUIElement] else {
            print("[DockMinimize Log] hasVisibleWindows check failed. AXError: \(error.descriptionString)")
            return false
        }
        
        for window in windows {
            var isMinimizedRef: CFTypeRef?
            let minError = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &isMinimizedRef)
            
            if minError == .success, let isMinimizedVal = isMinimizedRef {
                let isMinimized = (isMinimizedVal as! CFBoolean) == kCFBooleanTrue
                if !isMinimized {
                    return true // Found at least one visible window
                }
            }
        }
        
        return false // All windows are minimized (or no windows exist)
    }
    
    private func restoreMinimizedWindows(for app: NSRunningApplication, retryCount: Int = 0) {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        
        var windowListRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowListRef)
        
        // If the window server returns -25204 (cannotComplete) because the target app is busy launching
        // or transitioning, wait 0.15s and retry up to 3 times.
        if error == .cannotComplete && retryCount < 3 {
            print("[DockMinimize Log] Failed to get window list of \(app.localizedName ?? "app") due to cannotComplete (-25204). Retrying in 0.15s... (Retry \(retryCount + 1)/3)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.restoreMinimizedWindows(for: app, retryCount: retryCount + 1)
            }
            return
        }
        
        guard error == .success, let windows = windowListRef as? [AXUIElement] else {
            print("[DockMinimize Log] Failed to get window list. AXError: \(error.descriptionString)")
            if error == .cannotComplete {
                print("[DockMinimize Log] DIAGNOSTIC TIP: macOS blocked window list lookup. TCC database mismatch.")
            }
            return
        }
        
        var minimizedWindows: [AXUIElement] = []
        var visibleWindows: [AXUIElement] = []
        
        for window in windows {
            var isMinimizedRef: CFTypeRef?
            let minError = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &isMinimizedRef)
            
            if minError == .success, let isMinimizedVal = isMinimizedRef {
                let isMinimized = (isMinimizedVal as! CFBoolean) == kCFBooleanTrue
                if isMinimized {
                    minimizedWindows.append(window)
                } else {
                    visibleWindows.append(window)
                }
            }
        }
        
        print("[DockMinimize Log] App windows count: \(windows.count), Minimized: \(minimizedWindows.count), Visible: \(visibleWindows.count)")
        
        // Check if we should perform restoration (restore only first minimized window)
        if !minimizedWindows.isEmpty {
            if visibleWindows.isEmpty {
                if let firstMinimized = minimizedWindows.first {
                    print("[DockMinimize Log] Restoring the most recently active minimized window...")
                    unminimizeWindow(firstMinimized)
                }
            } else {
                print("[DockMinimize Log] Skipping restoration: There are visible windows on screen.")
            }
        }
    }
    
    private func unminimizeWindow(_ window: AXUIElement) {
        let result = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        print("[DockMinimize Log] Unminimized window. Set result: \(result.descriptionString), Raise result: \(raiseResult.descriptionString)")
    }
}

// MARK: - Launch on Login & Accessibility Helpers

class LaunchAtLoginHelper: ObservableObject {
    @Published var isEnabled: Bool = false {
        didSet {
            setLaunchAtLogin(isEnabled)
        }
    }
    
    private let appService = SMAppService.mainApp
    
    init() {
        self.isEnabled = appService.status == .enabled
    }
    
    func refreshStatus() {
        self.isEnabled = appService.status == .enabled
    }
    
    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (appService.status == .enabled) else { return }
        
        do {
            if enabled {
                try appService.register()
            } else {
                try appService.unregister()
            }
        } catch {
            print("SMAppService failed: \(error)")
            DispatchQueue.main.async {
                self.isEnabled = self.appService.status == .enabled
            }
        }
    }
}

class AccessibilityHelper: ObservableObject {
    @Published var isTrusted: Bool = false
    
    init() {
        checkStatus()
    }
    
    func checkStatus() {
        isTrusted = AXIsProcessTrusted()
    }
    
    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        checkStatus()
    }
}

// MARK: - SwiftUI Views

struct SettingsView: View {
    @StateObject private var accessibility = AccessibilityHelper()
    @StateObject private var launchAtLogin = LaunchAtLoginHelper()
    
    // Timer to poll accessibility status while Settings is open
    let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(nsImage: getAppIcon())
                    .resizable()
                    .frame(width: 45, height: 45)
                    .padding(.trailing, 10)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("DockMinimize")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("Automatically minimize and restore windows")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(spacing: 16) {
                    
                    // Accessibility Permission Card
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Accessibility Permission")
                                .font(.headline)
                            Spacer()
                            if accessibility.isTrusted {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Enabled")
                                        .font(.subheadline)
                                        .foregroundColor(.green)
                                }
                            } else {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Required")
                                        .font(.subheadline)
                                        .foregroundColor(.orange)
                                }
                            }
                        }
                        
                        Text("This app requires Accessibility access to control, minimize, and restore windows of other applications.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        if !accessibility.isTrusted {
                            Button(action: {
                                accessibility.requestPermission()
                            }) {
                                HStack {
                                    Image(systemName: "hand.tap.fill")
                                    Text("Grant Access in System Settings")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                    )
                    
                    // General Behavior Settings Card
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Behavior")
                            .font(.headline)
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch at login")
                                    .font(.body)
                                Text("Start the application automatically when you log in")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $launchAtLogin.isEnabled)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                    )
                    
                    // About Card
                    VStack(spacing: 6) {
                        Text("DockMinimize v1.0.0")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Created as a utility to toggle window states via Dock click.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
                }
                .padding(20)
            }
        }
        .frame(width: 450, height: 350)
        .onReceive(timer) { _ in
            accessibility.checkStatus()
        }
        .onAppear {
            accessibility.checkStatus()
            launchAtLogin.refreshStatus()
        }
    }
}

#Preview {
    SettingsView()
}
