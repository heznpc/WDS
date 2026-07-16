import AppKit
import CoreGraphics
import Darwin
import Foundation
import WDSAppCore

/// A supported frontmost application WDS may watch or act on.
struct TargetApplication {
    let application: NSRunningApplication
    let bundleIdentifier: String
    let name: String

    init?(_ application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        name = application.localizedName ?? bundleIdentifier
    }

    var processIdentifier: pid_t { application.processIdentifier }
}

/// The exact process a current-draft watch is scoped to for this launch.
struct LocalSessionScope {
    let bundleIdentifier: String
    let processIdentifier: pid_t

    func matches(_ target: TargetApplication) -> Bool {
        bundleIdentifier == target.bundleIdentifier
            && processIdentifier == target.processIdentifier
    }
}

/// One in-memory snapshot of the focused draft, keyed to its process and focus.
struct LocalDraftSnapshot {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let focusEpoch: Int
    let text: String
}

/// Identifies a candidate so a delayed callback for candidate A can never act on
/// candidate B. Keyed on the process, focus, exact range, and original text.
struct CurrentDraftCandidateIdentity: Equatable {
    let bundleIdentifier: String
    let processIdentifier: pid_t
    let focusEpoch: Int
    let range: CurrentDraftUTF16Range
    let originalText: String
}

/// A candidate plus the identity it must still match to remain actionable.
struct CurrentDraftCandidateState {
    let identity: CurrentDraftCandidateIdentity
    let candidate: CurrentDraftDeletionCandidate

    var displayPhrase: String {
        candidate.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A clamped, validated summary of recent mouse motion for overlay flourish.
struct MotionSummary {
    let direction: String
    let speed: Double
    let distance: Double

    static let stationary = MotionSummary(direction: "stationary", speed: 0, distance: 0)

    init(direction: String, speed: Double, distance: Double) {
        let allowedDirections = Set([
            "stationary", "north", "northeast", "east", "southeast",
            "south", "southwest", "west", "northwest",
        ])
        self.direction = allowedDirections.contains(direction) ? direction : "stationary"
        self.speed = min(12_000, max(0, speed.isFinite ? speed : 0))
        self.distance = min(8_000, max(0, distance.isFinite ? distance : 0))
    }
}

/// The resolved on-screen rectangle for an overlay, and whether it was estimated.
struct OverlayTarget {
    let rectangle: CGRect
    let isEstimated: Bool
}

enum PreviewInspectionResult {
    case success(OverlayTarget)
    case failure(String)
}

enum DeleteInspectionResult {
    case success(SafeDeleteInspection)
    case failure(String)
}

enum DeleteExecutionResult {
    case success
    case failure(String)
}

enum CandidateInspectionResult {
    case success(CGRect)
    case failure(String)
}

/// The most recent effect-test outcome, rendered as a menu info line.
enum OverlayOutcome {
    case notTested
    case rendering
    case verified(frames: Int, elapsedMilliseconds: Int)
    case failed(String)

    var menuTitle: String {
        switch self {
        case .notTested:
            return "최근 효과: 아직 확인하지 않음"
        case .rendering:
            return "최근 효과: 렌더 중…"
        case .verified(let frames, let elapsedMilliseconds):
            return "최근 효과: 렌더 확인 • \(frames)프레임 • \(elapsedMilliseconds)ms"
        case .failed(let reason):
            return "최근 효과: 확인 실패 • \(reason)"
        }
    }
}
