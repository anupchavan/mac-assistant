// Posts real key events into the session event tap, so a verifier can press the keys a
// computer-use tool cannot (fn). Usage: swift scripts/keys.swift fn+space | fn-hold <ms> | fn-tap | esc
import CoreGraphics
import Foundation

let fnKey: CGKeyCode = 63
let space: CGKeyCode = 49
let escape: CGKeyCode = 53
let source = CGEventSource(stateID: .hidSystemState)

func post(_ event: CGEvent?) {
    event?.post(tap: .cgSessionEventTap)
    usleep(30_000)
}

func fn(down: Bool) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: fnKey, keyDown: down)
    event?.type = .flagsChanged
    event?.flags = down ? .maskSecondaryFn : []
    post(event)
}

func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        post(event)
    }
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "fn+space":
    fn(down: true)
    key(space, flags: .maskSecondaryFn)
    fn(down: false)
case "fn-hold":
    fn(down: true)
    usleep(useconds_t((Int(args.dropFirst().first ?? "600") ?? 600) * 1000))
    fn(down: false)
case "fn-tap":
    fn(down: true)
    usleep(80_000)
    fn(down: false)
case "esc":
    key(escape)
default:
    FileHandle.standardError.write(Data("usage: keys.swift fn+space | fn-hold <ms> | fn-tap | esc\n".utf8))
    exit(64)
}
