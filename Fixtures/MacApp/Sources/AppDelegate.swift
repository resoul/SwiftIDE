import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let greeter = Greeter(name: "mac")

    func applicationDidFinishLaunching(_ notification: Notification) {
        print(greeter.greeting(), Build.flavour)
    }
}
