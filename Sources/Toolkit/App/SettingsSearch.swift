import Foundation

/// A setting search can find: its page, its title and caption, and whether
/// it's on a mouse's own page rather than the Mouse list.
struct SettingsEntry: Identifiable {
    let section: AppSection
    /// The row's or card's title on its page, which is also its anchor there.
    let title: LocalizedStringResource
    /// What a result calls it, where the title only makes sense on its page:
    /// "Check for updates" for the Updates card, as System Settings names its
    /// results.
    var name: LocalizedStringResource?
    var caption: LocalizedStringResource?
    var perMouse = false
    /// On a page with tabs (Window Layout's), the tab it's on.
    var tab: String?

    init(_ section: AppSection, _ title: LocalizedStringResource, name: LocalizedStringResource? = nil,
         caption: LocalizedStringResource? = nil, perMouse: Bool = false, tab: String? = nil) {
        self.section = section
        self.title = title
        self.name = name
        self.caption = caption
        self.perMouse = perMouse
        self.tab = tab
    }

    /// What a result shows.
    var shown: LocalizedStringResource { name ?? title }

    /// Where it is on its page: rows are anchored by their title.
    var anchor: String { title.key }
    var id: String { "\(section.rawValue)/\(anchor)" }

    /// Its name in the reader's words, and in English too, so either finds it.
    fileprivate var names: [String] {
        [String(localized: title), title.key] + (name.map { [String(localized: $0), $0.key] } ?? [])
    }

    /// Its name and what it says below it.
    fileprivate var texts: [String] {
        names + (caption.map { [String(localized: $0), $0.key] } ?? [])
    }
}

/// System Settings' search: the pages and settings that match, for the
/// sidebar to list in place of the pages.
enum SettingsIndex {
    /// Not rows `scripts/settings-index.py` finds: the switch in the header
    /// of each tool that can be in the menu bar.
    static let headers: [SettingsEntry] = [
        SettingsEntry(.capture, "Show in the menu bar", name: "Show Screen Capture in the menu bar"),
        SettingsEntry(.awake, "Show in the menu bar", name: "Show Keep Awake in the menu bar"),
        SettingsEntry(.mixer, "Show in the menu bar", name: "Show the Audio Mixer in the menu bar"),
        SettingsEntry(.mouse, "Show in the menu bar", name: "Show Mouse in the menu bar"),
        SettingsEntry(.layout, "Show in the menu bar", name: "Show Window Layout in the menu bar"),
    ]

    /// A page, or a setting on one.
    struct Hit: Identifiable {
        let section: AppSection
        /// Nil for the page itself.
        let entry: SettingsEntry?
        var id: String { entry?.id ?? section.rawValue }
    }

    /// As System Settings lists them: the pages whose name matches, then the
    /// settings whose name does, then those that match only in what they say
    /// below it. Every word must be found; case and accents don't count.
    static func search(_ query: String) -> [Hit] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        func matches(_ texts: [String]) -> Bool {
            words.allSatisfy { word in texts.contains { $0.localizedStandardContains(word) } }
        }
        let order = [AppSection.general, .about] + AppSection.tools
        func rank(_ section: AppSection) -> Int { order.firstIndex(of: section) ?? order.count }
        let all = (entries + headers).sorted { rank($0.section) < rank($1.section) }
        let pages = order.filter { matches([$0.title, $0.summary]) }.map { Hit(section: $0, entry: nil) }
        let named = all.filter { matches($0.names) }
        let described = all.filter { !matches($0.names) && matches($0.texts) }
        return pages + (named + described).map { Hit(section: $0.section, entry: $0) }
    }
}
