import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let contentViewURL = root.appendingPathComponent("Sources/TraceView/Views/ContentView.swift")
let tabBarURL = root.appendingPathComponent("Sources/TraceView/Views/LogView/TabBarView.swift")

let contentView = try String(contentsOf: contentViewURL, encoding: .utf8)
let tabBar = try String(contentsOf: tabBarURL, encoding: .utf8)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

require(!contentView.contains("NavigationSplitView"), "ContentView should not use NavigationSplitView overlay layout")
require(contentView.contains("isSidebarVisible"), "sidebar visibility should be explicit app state")
require(contentView.contains("sidebarWidth"), "sidebar should have deterministic width state")
require(contentView.contains("SidebarLayout.defaultWidth"), "sidebar should default to the approved fixed-column width")
require(contentView.contains(".frame(width: sidebarWidth"), "sidebar column should occupy real measured width")
require(!tabBar.contains("safeAreaInsets.leading"), "TabBarView should not offset itself for sidebar overlap")

print("PASS")
