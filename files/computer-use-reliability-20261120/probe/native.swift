import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let args = CommandLine.arguments
func json(_ value: Any) { print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!) }
switch args.count > 1 ? args[1] : "state" {
case "lock":
  let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW)
  guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { print("no SACLockScreenImmediate"); exit(2) }
  typealias Lock = @convention(c) () -> Int32
  print("SACLockScreenImmediate", unsafeBitCast(symbol, to: Lock.self)())
case "lum":
  guard let image = NSImage(contentsOfFile: args[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { json(["error": "unreadable"]); exit(0) }
  let width = 64, height = max(1, 64 * image.height / max(1, image.width))
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  var sum = 0.0, dark = 0, distinct = Set<UInt32>()
  for i in stride(from: 0, to: pixels.count, by: 4) {
    let l = 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
    sum += l; if l < 8 { dark += 1 }
    distinct.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
  }
  let n = Double(pixels.count / 4)
  json(["width": image.width, "height": image.height, "meanLuma": (sum / n).rounded(), "darkFraction": (Double(dark) / n * 100).rounded() / 100, "colors64": distinct.count])
default:
  let session = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
  let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
  json(["screenIsLocked": session["CGSSessionScreenIsLocked"] as? Bool ?? false, "onConsole": session["kCGSSessionOnConsoleKey"] as? Bool ?? false,
        "loginDone": session["kCGSessionLoginDoneKey"] as? Bool ?? false, "mainDisplayAsleep": CGDisplayIsAsleep(CGMainDisplayID()) != 0,
        "onScreenWindows": windows.count, "onScreenOwners": Array(Set(windows.compactMap { $0[kCGWindowOwnerName as String] as? String })).sorted().prefix(12).joined(separator: ","),
        "axTrusted": AXIsProcessTrusted(), "screenCapture": CGPreflightScreenCaptureAccess()])
}
