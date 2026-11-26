import Foundation
import Observation

/// State for the Cleanup screen. Shared so a finished scan survives switching sidebar sections.
@MainActor
@Observable
final class CleanupStore {
    static let shared = CleanupStore()

    enum Phase: Equatable {
        case idle, scanning, ready, cleaning, finished
    }

    enum CategoryState: Equatable {
        case waiting, scanning, done
    }

    static let idleDayChoices = [7, 14, 30, 60, 90, 180, 365]
    private static let idleDaysKey = "cleanup.projectIdleDays"

    private(set) var phase: Phase = .idle
    private(set) var categoryStates: [CleanupCategoryID: CategoryState] = [:]
    private(set) var results: [CleanupCategoryID: CleanupCategoryResult] = [:]
    private(set) var selection: Set<String> = []
    private(set) var expanded: Set<CleanupCategoryID> = []
    private(set) var history: CleanupHistory
    private(set) var outcome: CleanupOutcome?
    private(set) var cleanedCount = 0
    private(set) var cleanTotal = 0
    private(set) var cleaningName = ""
    private(set) var scanStarted: Date?
    private(set) var projectIdleDays: Int

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanCancel = CleanupCancellation()
    @ObservationIgnored private var lastEnvironment: CleanupEnvironment?
    @ObservationIgnored private var isFullScan = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = CleanupHistory.load(from: defaults)
        let stored = defaults.integer(forKey: Self.idleDaysKey)
        projectIdleDays = Self.idleDayChoices.contains(stored) ? stored : 30
    }

    // MARK: Derived

    var orderedResults: [CleanupCategoryResult] {
        CleanupCategoryID.allCases.compactMap { results[$0] }
    }

    var reclaimableBytes: Int64 { orderedResults.reduce(0) { $0 + $1.totalBytes } }

    var selectedEntries: [(CleanupCategoryID, CleanupItem)] {
        orderedResults.flatMap { result in
            result.items.filter { selection.contains($0.id) }.map { (result.category, $0) }
        }
    }

    var selectedBytes: Int64 { selectedEntries.reduce(0) { $0 + $1.1.bytes } }
    var selectedCount: Int { selectedEntries.count }

    func selectedBytes(in category: CleanupCategoryID) -> Int64 {
        results[category]?.items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.bytes } ?? 0
    }

    var deniedCount: Int { orderedResults.reduce(0) { $0 + $1.deniedCount } }

    var finishedCategoryCount: Int { categoryStates.values.filter { $0 == .done }.count }

    // MARK: Selection

    enum Mark { case on, off, mixed }

    func mark(for category: CleanupCategoryID) -> Mark {
        guard let items = results[category]?.items, !items.isEmpty else { return .off }
        let count = items.filter { selection.contains($0.id) }.count
        return count == 0 ? .off : count == items.count ? .on : .mixed
    }

    /// Ticking a category selects everything except items in use; ticking it again clears it.
    func toggle(_ category: CleanupCategoryID) {
        guard let items = results[category]?.items, !items.isEmpty else { return }
        let ids = items.map(\.id)
        if mark(for: category) == .off {
            let preferred = items.filter { $0.inUseBy == nil }.map(\.id)
            selection.formUnion(preferred.isEmpty ? ids : preferred)
        } else {
            selection.subtract(ids)
        }
    }

    func isSelected(_ item: CleanupItem) -> Bool { selection.contains(item.id) }

    func setSelected(_ item: CleanupItem, _ isOn: Bool) {
        guard selection.contains(item.id) != isOn else { return }
        if isOn { selection.insert(item.id) } else { selection.remove(item.id) }
    }

    func toggleExpanded(_ category: CleanupCategoryID) {
        if expanded.contains(category) { expanded.remove(category) } else { expanded.insert(category) }
    }

    // MARK: Scanning

    func scan() {
        cancelScan()
        let cancel = CleanupCancellation()
        scanCancel = cancel
        results = [:]
        selection = []
        expanded = []
        outcome = nil
        categoryStates = Dictionary(uniqueKeysWithValues: CleanupCategoryID.allCases.map { ($0, .scanning) })
        scanStarted = Date()
        phase = .scanning
        isFullScan = true
        let idleDays = projectIdleDays
        scanTask = Task { [weak self] in
            let env = await CleanupLiveEnvironment.make(projectIdleDays: idleDays)
            await self?.run(CleanupCategoryID.allCases, env: env, cancel: cancel)
        }
    }

    /// Re-scans one category (after changing its settings) without touching the others.
    func rescan(_ category: CleanupCategoryID) {
        guard phase == .ready, let base = lastEnvironment else { return }
        var env = base
        env.projectIdleDays = projectIdleDays
        env.now = Date()
        let cancel = CleanupCancellation()
        scanCancel = cancel
        categoryStates[category] = .scanning
        if let old = results[category] { selection.subtract(old.items.map(\.id)) }
        results[category] = nil
        phase = .scanning
        isFullScan = false
        scanTask = Task { [weak self] in await self?.run([category], env: env, cancel: cancel) }
    }

    private func run(_ categories: [CleanupCategoryID], env: CleanupEnvironment, cancel: CleanupCancellation) async {
        lastEnvironment = env
        await withTaskGroup(of: CleanupCategoryResult.self) { group in
            for category in categories {
                group.addTask { await CleanupEngine.offMain { CleanupScanner.scan(category, env: env, cancel: cancel) } }
            }
            for await result in group {
                guard !cancel.isCancelled else { continue }
                results[result.category] = result
                categoryStates[result.category] = .done
            }
        }
        guard !cancel.isCancelled else { return }
        finishScan(categories)
    }

    private func finishScan(_ scanned: [CleanupCategoryID]) {
        let deduplicated = CleanupEngine.deduplicate(orderedResults)
        results = Dictionary(uniqueKeysWithValues: deduplicated.map { ($0.category, $0) })
        for category in scanned {
            guard category.isSelectedByDefault, let items = results[category]?.items else { continue }
            selection.formUnion(items.filter(\.isSelectedByDefault).map(\.id))
        }
        let valid = Set(results.values.flatMap { $0.items.map(\.id) })
        selection.formIntersection(valid)
        phase = .ready
        scanTask = nil
        var updated = history
        updated.lastScanDate = Date()
        updated.lastScanBytes = reclaimableBytes
        commit(updated)
    }

    /// Stops a running scan. Keeps the screen's previous state if there was nothing to show yet.
    func cancelScan() {
        scanCancel.cancel()
        scanTask?.cancel()
        scanTask = nil
        guard phase == .scanning else { return }
        // A partial full scan would understate the total, so it's dropped; a cancelled single-category rescan
        // keeps the other categories' results.
        let keep = !isFullScan && !results.isEmpty
        phase = keep ? .ready : .idle
        if keep {
            for (category, state) in categoryStates where state == .scanning { categoryStates[category] = nil }
        } else {
            results = [:]
            categoryStates = [:]
            selection = []
        }
    }

    func setProjectIdleDays(_ days: Int) {
        guard days != projectIdleDays, Self.idleDayChoices.contains(days) else { return }
        projectIdleDays = days
        defaults.set(days, forKey: Self.idleDaysKey)
        rescan(.projectArtifacts)
    }

    // MARK: Cleaning

    func plan(deleteCachesImmediately: Bool) -> [CleanupPlanEntry] {
        CleanupEngine.plan(selectedEntries, deleteCachesImmediately: deleteCachesImmediately)
    }

    func clean(deleteCachesImmediately: Bool) {
        guard phase == .ready, let env = lastEnvironment else { return }
        let plan = plan(deleteCachesImmediately: deleteCachesImmediately)
        guard !plan.isEmpty else { return }
        phase = .cleaning
        cleanedCount = 0
        cleanTotal = plan.count
        cleaningName = ""
        let cancel = CleanupCancellation()
        Task { [weak self] in
            let outcome = await CleanupEngine.offMain {
                CleanupEngine.execute(plan, env: env, cancel: cancel) { index, name in
                    Task { @MainActor in self?.reportProgress(index, name) }
                }
            }
            self?.finishClean(outcome)
        }
    }

    private func reportProgress(_ index: Int, _ name: String) {
        guard phase == .cleaning, index >= cleanedCount else { return }
        cleanedCount = index
        if !name.isEmpty { cleaningName = name }
    }

    private func finishClean(_ outcome: CleanupOutcome) {
        self.outcome = outcome
        cleanedCount = cleanTotal
        phase = .finished
        var updated = history
        updated.lastCleanDate = outcome.date
        updated.lastCleanFreedBytes = outcome.measuredFreedBytes
        updated.lastCleanTrashedBytes = outcome.trashedBytes
        updated.lastCleanDeletedBytes = outcome.deletedBytes
        commit(updated)
        results = [:]
        selection = []
    }

    func dismissOutcome() {
        guard phase == .finished else { return }
        outcome = nil
        phase = .idle
        categoryStates = [:]
    }

    private func commit(_ updated: CleanupHistory) {
        guard updated != history else { return }
        history = updated
        updated.save(to: defaults)
    }
}
