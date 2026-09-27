import CoreGraphics
import Foundation

// Prints the CGWindowID of the first on-screen window owned by the given app.
let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "PiCanvas"
guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
for window in list {
    guard let owner = window[kCGWindowOwnerName as String] as? String, owner == target else { continue }
    guard let number = window[kCGWindowNumber as String] as? Int else { continue }
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    if layer == 0 {
        print(number)
        exit(0)
    }
}
exit(2)
