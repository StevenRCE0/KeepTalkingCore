import Foundation
import Testing

@testable import KeepTalkingSDK

/// A thread workspace outlives its runs. A run's harvest delivers the files
/// THAT run wrote — never one an earlier run left behind, which used to be
/// re-delivered by every later run and credited to the wrong action.
struct WorkspaceHarvestTests {

    @Test("harvest delivers only files written or rewritten since the run started")
    func harvestSkipsEarlierRunsLeftovers() throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kt-harvest-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: workspace.appendingPathComponent(name))
        }
        let slots: Set<String> = [workspace.appendingPathComponent("result").standardizedFileURL.path]
        func harvested(since baseline: [String: KeepTalkingIOManager.WorkspaceFileStamp]) -> [String] {
            KeepTalkingIOManager.harvestCandidates(
                in: workspace, declaredSlotPaths: slots, baseline: baseline
            ).map(\.lastPathComponent)
        }

        // First run: everything it wrote outside its slot is its output.
        let first = KeepTalkingIOManager.workspaceFileStamps(in: workspace)
        try write("list_windows.swift", "print(1)")
        try write("notes.txt", "a")
        try write("result", "slot")
        #expect(harvested(since: first) == ["list_windows.swift", "notes.txt"])

        // Second run: the untouched leftover stays out; a rewrite and a new file are in.
        let second = KeepTalkingIOManager.workspaceFileStamps(in: workspace)
        try write("notes.txt", "ab")
        try write("shot.png", "png")
        #expect(harvested(since: second) == ["notes.txt", "shot.png"])

        // A run that writes nothing harvests nothing.
        let third = KeepTalkingIOManager.workspaceFileStamps(in: workspace)
        #expect(harvested(since: third).isEmpty)
    }
}
