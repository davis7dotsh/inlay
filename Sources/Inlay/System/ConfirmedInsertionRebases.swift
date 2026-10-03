/// Tracks cursor movement caused by this batch's confirmed insertions. Targets
/// include field identity and selection; a caller must revalidate the resulting
/// anchor before using it. An external cursor/focus change never grants a rebase.
struct ConfirmedInsertionRebases<Target: Equatable> {
    private var entries: [(original: Target, confirmed: Target)] = []

    mutating func inserted(at original: Target, confirmed: Target) {
        entries = entries.map { $0.confirmed == original ? ($0.original, confirmed) : $0 }
        entries.append((original, confirmed))
    }

    func destination(for original: Target, isUnchanged: (Target) -> Bool) -> Target {
        guard let entry = entries.last(where: { $0.original == original }),
              isUnchanged(entry.confirmed) else { return original }
        return entry.confirmed
    }

    mutating func removeAll() { entries.removeAll() }
}
