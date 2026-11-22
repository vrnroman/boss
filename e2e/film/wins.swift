// Prints on-screen window ids for an owner name: "<id> <layer> <width> <height> <name>"
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == CommandLine.arguments[1] {
  let b = w["kCGWindowBounds"] as! [String: Any]
  print(w["kCGWindowNumber"]!, w["kCGWindowLayer"]!, b["Width"]!, b["Height"]!, (w["kCGWindowName"] as? String) ?? "")
}
