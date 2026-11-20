import AppKit
import CoreGraphics
import Darwin
import Foundation
import Security
import os

#if FAULTS
let faultHooks = true
#else
let faultHooks = false
#endif
let log = Logger(subsystem: "com.tron.unlock", category: "broker")
let runDir = "/Library/Application Support/Tron/run"
let pluginSocket = runDir + "/plugin.sock"
let leaseMarker = NSHomeDirectory() + "/.tron-unlock/lease-active"
let controlSocket = NSHomeDirectory() + "/.tron-unlock/control.sock"
let pluginPeerRequirement = "anchor apple and identifier \"com.apple.SecurityAgentHelper.arm64\""

typealias LockFunction = @convention(c) () -> Int32
func lockScreen() -> Int32 {
  let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW)
  guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { return -1 }
  return unsafeBitCast(symbol, to: LockFunction.self)()
}

func screenLocked() -> Bool {
  (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
}

func stamp() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

func listen(_ path: String, mode: mode_t) -> Int32 {
  unlink(path)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { raw in _ = path.withCString { strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count) } }
  let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  precondition(bound == 0 && chmod(path, mode) == 0 && Darwin.listen(fd, 8) == 0, "listen \(path): \(errno)")
  return fd
}

func connectTo(_ path: String) -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { raw in _ = path.withCString { strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count) } }
  let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  if ok != 0 { fputs("broker not running\n", stderr); exit(3) }
  return fd
}

func readLine(_ fd: Int32) -> String {
  var bytes = [UInt8]()
  var byte: UInt8 = 0
  while bytes.count < 256, read(fd, &byte, 1) == 1, byte != 10 { bytes.append(byte) }
  return String(decoding: bytes, as: UTF8.self)
}

func reply(_ fd: Int32, _ text: String) { _ = text.withCString { write(fd, $0, strlen($0)) } }

func guarded(_ fd: Int32) {
  var on: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

func peerSatisfies(_ fd: Int32, _ requirementText: String) -> Bool {
  var token = audit_token_t()
  var length = socklen_t(MemoryLayout<audit_token_t>.size)
  guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
  let data = withUnsafeBytes(of: &token) { Data($0) }
  var code: SecCode?
  var requirement: SecRequirement?
  guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code,
        SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
  return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

protocol ApprovalSource { func start(_ grant: @escaping (_ task: String, _ seconds: Int) -> Void) }

final class LocalStubApproval: ApprovalSource {
  func start(_ grant: @escaping (String, Int) -> Void) {}
}

final class Lease {
  enum State { case idle, approved(task: String, seconds: Int, expires: Date), active(task: String, ends: Date) }
  var state = State.idle
  var fault = "none"
  var shield: [NSWindow] = []
  var tap: CFMachPort?
  var endTimer: Timer?
  var pollTimer: Timer?

  func approve(task: String, seconds: Int) -> Bool {
    if case .active = state { return false }
    guard (1...600).contains(seconds) else { return false }
    state = .approved(task: task, seconds: seconds, expires: Date().addingTimeInterval(30))
    log.notice("lease approved task=\(task, privacy: .public) seconds=\(seconds)")
    print(stamp(), "approved", task, seconds); fflush(stdout)
    return true
  }

  func answerPlugin() -> String {
    guard case let .approved(task, seconds, expires) = state, expires > Date() else {
      print(stamp(), "plugin DENY no-approval"); fflush(stdout)
      return "DENY\n"
    }
    state = .active(task: task, ends: Date().addingTimeInterval(TimeInterval(seconds)))
    FileManager.default.createFile(atPath: leaseMarker, contents: Data(task.utf8))
    print(stamp(), "plugin ALLOW", task); fflush(stdout)
    DispatchQueue.main.async { self.begin(seconds: seconds) }
    return "ALLOW\n"
  }

  func begin(seconds: Int) {
    endTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { _ in self.end("lease-expired") }
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
      guard !screenLocked() else { return }
      timer.invalidate()
      self.showShield()
      self.armPhysicalInput()
      print(stamp(), "unlocked; shield up; physical-input monitor armed"); fflush(stdout)
    }
  }

  func showShield() {
    shield = NSScreen.screens.map { screen in
      let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
      window.level = .screenSaver
      window.ignoresMouseEvents = true
      window.backgroundColor = NSColor.black.withAlphaComponent(0.15)
      window.collectionBehavior = [.canJoinAllSpaces, .stationary]
      let label = NSTextField(labelWithString: "Tron is using this Mac. Touch any key or the mouse to lock it.")
      label.font = .systemFont(ofSize: 20, weight: .semibold)
      label.textColor = .white
      label.drawsBackground = true
      label.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9)
      label.frame = NSRect(x: 0, y: screen.frame.height - 60, width: screen.frame.width, height: 40)
      label.alignment = .center
      window.contentView?.addSubview(label)
      window.orderFrontRegardless()
      return window
    }
  }

  func armPhysicalInput() {
    let mask = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel, .flagsChanged]
      .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
      let lease = Unmanaged<Lease>.fromOpaque(info!).takeUnretainedValue()
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { lease.end("tap-disabled"); return nil }
      if event.getIntegerValueField(.eventSourceUnixProcessID) == 0 { lease.end("physical-input type=\(type.rawValue)") }
      return nil
    }, userInfo: Unmanaged.passUnretained(self).toOpaque())
    guard let tap else { end("no-input-monitor"); return }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
  }

  func end(_ reason: String) {
    guard case .active = state else { return }
    let started = Date()
    var result: Int32 = -1
    for _ in 0..<20 where !screenLocked() {
      result = lockScreen()
      usleep(50_000)
    }
    guard screenLocked() else {
      print(stamp(), "RELOCK FAILED reason=\(reason) SACLockScreenImmediate=\(result); lease stays active"); fflush(stdout)
      log.fault("relock failed reason=\(reason, privacy: .public)")
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.end(reason) }
      return
    }
    state = .idle
    unlink(leaseMarker)
    endTimer?.invalidate()
    pollTimer?.invalidate()
    if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    tap = nil
    shield.forEach { $0.orderOut(nil) }
    shield = []
    print(stamp(), "relock reason=\(reason) SACLockScreenImmediate=\(result) ms=\(Int(Date().timeIntervalSince(started) * 1000))"); fflush(stdout)
    log.notice("lease ended reason=\(reason, privacy: .public)")
  }
}

func serve() {
  signal(SIGPIPE, SIG_IGN)
  let lease = Lease()
  mkdir(NSHomeDirectory() + "/.tron-unlock", 0o700)
  if access(leaseMarker, F_OK) == 0 {
    print(stamp(), "stale lease marker; relock SACLockScreenImmediate=\(screenLocked() ? 0 : lockScreen())"); fflush(stdout)
    unlink(leaseMarker)
  }
  let plugin = listen(pluginSocket, mode: 0o666)
  let control = listen(controlSocket, mode: 0o600)
  LocalStubApproval().start { task, seconds in DispatchQueue.main.async { _ = lease.approve(task: task, seconds: seconds) } }
  Thread.detachNewThread {
    while true {
      let fd = accept(plugin, nil, nil)
      guard fd >= 0 else { continue }
      guarded(fd)
      guard peerSatisfies(fd, pluginPeerRequirement) else { print(stamp(), "plugin peer rejected"); fflush(stdout); close(fd); continue }
      Thread.detachNewThread {
        let request = readLine(fd)
        let mode = DispatchQueue.main.sync { lease.fault }
        print(stamp(), "plugin request=\(request) fault=\(mode)"); fflush(stdout)
        switch mode {
        case "hang": sleep(5)
        case "crash": abort()
        case "garbage": reply(fd, "ALLOWX\n")
        default: reply(fd, request == "UNLOCK" ? DispatchQueue.main.sync { lease.answerPlugin() } : "DENY\n")
        }
        close(fd)
      }
    }
  }
  Thread.detachNewThread {
    while true {
      let fd = accept(control, nil, nil)
      guard fd >= 0 else { continue }
      guarded(fd)
      let words = readLine(fd).split(separator: " ").map(String.init)
      switch words.first {
      case "APPROVE" where words.count == 3: reply(fd, DispatchQueue.main.sync { lease.approve(task: words[1], seconds: Int(words[2]) ?? 0) } ? "OK\n" : "ERR\n")
      case "FAULT" where words.count == 2 && faultHooks: DispatchQueue.main.sync { lease.fault = words[1] }; reply(fd, "OK\n")
      case "END": DispatchQueue.main.sync { lease.end("stop") }; reply(fd, "OK\n")
      default: reply(fd, "ERR\n")
      }
      close(fd)
    }
  }
  signal(SIGTERM, SIG_IGN)
  let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
  term.setEventHandler { lease.end("sigterm"); exit(0) }
  term.resume()
  print(stamp(), "serving"); fflush(stdout)
  NSApplication.shared.setActivationPolicy(.accessory)
  NSApplication.shared.run()
}

func control(_ line: String) {
  let fd = connectTo(controlSocket)
  reply(fd, line + "\n")
  print(readLine(fd))
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "serve": serve()
case "approve" where args.count == 4: control("APPROVE \(args[2]) \(args[3])")
case "fault" where args.count == 3: control("FAULT \(args[2])")
case "end": control("END")
case "lock": print("SACLockScreenImmediate", lockScreen())
case "state": print("{\"screenLocked\":\(screenLocked())}")
default: fputs("usage: tron-unlock-broker serve | approve <task> <seconds> | fault none|hang|crash|garbage | end | lock | state\n", stderr); exit(2)
}
