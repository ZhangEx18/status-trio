import AppKit

enum AboutIcon {
    static var githubMark: NSImage? {
        guard let url = Bundle.module.url(
            forResource: "GitHubMark",
            withExtension: "svg"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
