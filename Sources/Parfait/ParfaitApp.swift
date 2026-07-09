import SwiftUI

struct ParfaitApp: App {
    var body: some Scene {
        MenuBarExtra("Parfait", systemImage: "cup.and.saucer") {
            Text("Parfait")
        }
        .menuBarExtraStyle(.window)
    }
}
