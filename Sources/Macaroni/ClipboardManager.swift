import Cocoa

/// Polls the general pasteboard (there's no push notification API for it) and
/// keeps a rolling history of copied text. Polling every 0.4s is cheap and is
/// the standard approach every clipboard-manager app uses.
final class ClipboardManager {

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var date: Date

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
    }

    private(set) var history: [Entry] = []
    private let maxEntries: Int
    private var lastChangeCount: Int
    private var timer: Timer?

    /// Called on the main thread whenever the history changes.
    var onChange: (() -> Void)?

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        // Added in .common modes rather than Timer.scheduledTimer's default:
        // while the menu bar panel is open the run loop is in a tracking mode,
        // and a default-mode timer would silently stop firing until it closes.
        let newTimer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        record(text)
    }

    /// Adds text to the history. If the exact same text is already stored
    /// *anywhere* in the history, it is moved back to the top and its
    /// timestamp refreshed rather than stored a second time — so copying the
    /// same snippet repeatedly never fills the list with duplicates.
    private func record(_ text: String) {
        if let existingIndex = history.firstIndex(where: { $0.text == text }) {
            var entry = history.remove(at: existingIndex)
            entry.date = Date()
            history.insert(entry, at: 0)
        } else {
            history.insert(Entry(text: text, date: Date()), at: 0)
            if history.count > maxEntries {
                history.removeLast(history.count - maxEntries)
            }
        }
        onChange?()
    }

    /// Puts a previous entry back on the pasteboard and moves it to the top.
    func recopy(_ entry: Entry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        // Setting the pasteboard bumps changeCount — remember it so the poller
        // doesn't treat our own re-copy as a brand-new clipboard event.
        lastChangeCount = pasteboard.changeCount

        if let index = history.firstIndex(where: { $0.id == entry.id }) {
            var moved = history.remove(at: index)
            moved.date = Date()
            history.insert(moved, at: 0)
            onChange?()
        }
    }

    func delete(_ entry: Entry) {
        history.removeAll { $0.id == entry.id }
        onChange?()
    }

    func clearHistory() {
        history.removeAll()
        onChange?()
    }
}
