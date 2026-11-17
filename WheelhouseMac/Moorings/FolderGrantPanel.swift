import AppKit
import Foundation

/// The NSOpenPanel of a folder grant: folders only, hidden files shown. The panel runs out of process, so it can start in a folder the
/// app can't read; the URL it returns carries the user's grant.
@MainActor
enum FolderGrantPanel {
    static func choose(startingAt folder: URL, title: String, message: String, prompt: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = folder
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
}
