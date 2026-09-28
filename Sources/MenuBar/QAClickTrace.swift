import Foundation

/// Temporary, synthetic-QA-only lifecycle probe. Remove after notification click replay.
/// The closed enum deliberately cannot carry tokens, event content, identities or dates.
public enum QAClickTrace {
    public enum Stage: String {
        case launch, becameActive, responseWithToken, responseWithoutToken
        case reopenNotification, reopenOrdinary, routeBegin, routeHighlighted, routeMessage, routeNoDestination
        case showRequested, waitingActivation, waitingAnchor, showSucceeded, showFailed
        case popoverDidShow, popoverWillClose, closeRequested, deactivated
    }
    public static func record(_ stage: Stage) {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".qa") == true else { return }
        NSLog("[DEBUG-click] %@", stage.rawValue)
    }
}
