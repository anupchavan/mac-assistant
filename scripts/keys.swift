// Usage: keys fn+space | fn-hold <ms> | fn-tap | esc | return | type <text>
import CoreGraphics
import Foundation

let fnKey: CGKeyCode = 63
let space: CGKeyCode = 49
let escape: CGKeyCode = 53
let returnKey: CGKeyCode = 36
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

guard CGPreflightPostEventAccess() else {
    _ = CGRequestPostEventAccess()
    FileHandle.standardError.write(Data("keys: not allowed to post events; grant Accessibility to this app\n".utf8))
    exit(77)
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
case "return":
    key(returnKey)
case "type":
    for character in args.dropFirst().joined(separator: " ").utf16 {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            var unit = character
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            post(event)
        }
    }
default:
    FileHandle.standardError.write(Data("usage: keys fn+space | fn-hold <ms> | fn-tap | esc | return | type <text>\n".utf8))
    exit(64)
}
