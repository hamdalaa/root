import Foundation

/// Finds rebuildable build output (node_modules, .build, target…) in projects that have been idle for a while.
///
/// An artifact folder only counts when the folder next to it has the marker file of the tool that produces it
/// (node_modules needs package.json, target needs Cargo.toml or pom.xml), so an ordinary folder called
/// "build" or "target" is never offered.
enum CleanupProjectScanner {
    struct Artifact: Sendable {
        let folder: String
        /// File names, or suffixes starting with "." for bundles like `.xcodeproj`.
        let markers: [String]
    }

    private static let node = ["package.json"]
    private static let python = ["pyproject.toml", "setup.py", "setup.cfg", "requirements.txt", "Pipfile"]
    private static let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]

    static let artifacts: [Artifact] = [
        Artifact(folder: "node_modules", markers: node),
        Artifact(folder: ".next", markers: node),
        Artifact(folder: ".nuxt", markers: node),
        Artifact(folder: ".svelte-kit", markers: node),
        Artifact(folder: ".turbo", markers: node),
        Artifact(folder: ".parcel-cache", markers: node),
        Artifact(folder: ".angular", markers: ["angular.json"]),
        Artifact(folder: ".build", markers: ["Package.swift"]),
        Artifact(folder: "DerivedData", markers: [".xcodeproj", ".xcworkspace", "Package.swift"]),
        Artifact(folder: "Pods", markers: ["Podfile"]),
        Artifact(folder: "target", markers: ["Cargo.toml", "pom.xml"]),
        Artifact(folder: ".gradle", markers: gradle),
        Artifact(folder: "build", markers: gradle + ["pubspec.yaml"]),
        Artifact(folder: ".dart_tool", markers: ["pubspec.yaml"]),
        Artifact(folder: "__pycache__", markers: python),
        Artifact(folder: ".pytest_cache", markers: python),
        Artifact(folder: ".mypy_cache", markers: python),
        Artifact(folder: ".ruff_cache", markers: python),
        Artifact(folder: ".tox", markers: python),
    ]

    private static let artifactNames = Set(artifacts.map(\.folder))
    private static let skippedFolders: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures",
                                                       ".Trash", ".git", "vendor"]
    static let maxDepth = 5
    static let minimumBytes: Int64 = 1_000_000
    private static let maxFoldersVisited = 25_000

    static func scan(_ env: CleanupEnvironment, _ cancel: CleanupCancellation) -> CleanupCategoryResult {
        var collector = CleanupCollector(env: env, cancel: cancel)
        var denied = 0
        var visitedRoots = Set<String>()
        var budget = maxFoldersVisited
        let cutoff = env.now.addingTimeInterval(-Double(env.projectIdleDays) * 86_400)

        for root in env.projectRoots {
            guard CleanupFS.isDirectory(root), let real = CleanupSafety.realPath(root),
                  visitedRoots.insert(real.lowercased()).inserted else { continue }
            walk(root, root: root, depth: 0, cutoff: cutoff, collector: &collector, denied: &denied,
                 budget: &budget, cancel: cancel)
        }
        return collector.result(.projectArtifacts, extraDenied: denied)
    }

    private static func walk(_ folder: URL, root: URL, depth: Int, cutoff: Date, collector: inout CleanupCollector,
                             denied: inout Int, budget: inout Int, cancel: CleanupCancellation) {
        guard depth <= maxDepth, budget > 0, !cancel.isCancelled else { return }
        budget -= 1
        let children = CleanupFS.children(of: folder, denied: &denied)
        let names = children.map(\.lastPathComponent)

        let matches = artifacts(presentIn: names)
        if !matches.isEmpty {
            let activity = lastActivity(of: folder, children: children)
            if activity < cutoff {
                for artifact in matches {
                    collector.add(folder.appendingPathComponent(artifact.folder), root: root,
                                  name: folder.lastPathComponent, detail: artifact.folder, isCache: false,
                                  inUseBy: nil, lastActivity: activity, minimumBytes: minimumBytes)
                }
            }
        }

        for child in children {
            let name = child.lastPathComponent
            guard !name.hasPrefix("."), !artifactNames.contains(name), !skippedFolders.contains(name),
                  !isBundle(name), CleanupFS.isDirectory(child) else { continue }
            walk(child, root: root, depth: depth + 1, cutoff: cutoff, collector: &collector, denied: &denied,
                 budget: &budget, cancel: cancel)
        }
    }

    /// The artifact folders in a listing whose producing tool's marker sits alongside them.
    static func artifacts(presentIn names: [String]) -> [Artifact] {
        let present = Set(names)
        return artifacts.filter { artifact in
            present.contains(artifact.folder) && artifact.markers.contains { marker in
                marker.hasPrefix(".") ? names.contains { $0.hasSuffix(marker) } : present.contains(marker)
            }
        }
    }

    /// Newest modification among the project folder, its top two levels (skipping artifacts) and git metadata.
    /// Editing a deeply nested file may not show up here, which is why the threshold is in weeks, not days.
    static func lastActivity(of project: URL, children: [URL]) -> Date {
        var newest = CleanupFS.modificationDate(project) ?? .distantPast
        func consider(_ url: URL) {
            if let date = CleanupFS.modificationDate(url), date > newest { newest = date }
        }
        var ignored = 0
        for child in children where !artifactNames.contains(child.lastPathComponent) {
            consider(child)
            guard CleanupFS.isDirectory(child), !child.lastPathComponent.hasPrefix(".") else { continue }
            for grandchild in CleanupFS.children(of: child, denied: &ignored).prefix(200)
            where !artifactNames.contains(grandchild.lastPathComponent) {
                consider(grandchild)
            }
        }
        let git = project.appendingPathComponent(".git")
        for marker in ["index", "HEAD", "FETCH_HEAD", "logs/HEAD"] {
            consider(git.appendingPathComponent(marker))
        }
        return newest
    }

    private static func isBundle(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return [".app", ".xcodeproj", ".xcworkspace", ".photoslibrary", ".bundle", ".framework", ".xcarchive"]
            .contains { lowered.hasSuffix($0) }
    }
}
