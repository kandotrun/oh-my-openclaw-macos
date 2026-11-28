import Foundation
import OhMyOpenClawCore

/// What the connection form's browser sign-in button signs in to.
enum ConnectionFormSignIn: Equatable {
    /// The Gateway the form's URL or setup code names, with the form's inputs.
    case formInputs
    /// The Gateway the sign-in state is for: a failed sign-in again with what it was given, or else that
    /// Gateway with what is saved for it. The form can be empty while that Gateway still asks for a
    /// sign-in: a setup code leaves the form once it is sent, and a relaunch starts with an empty form.
    case stateTarget

    /// Nil while a connection change or a sign-in is under way, or while neither the form nor the
    /// sign-in state names a Gateway.
    static func start(formNamesGateway: Bool, signIn: CloudflareAccessSignInState, connecting: Bool) -> ConnectionFormSignIn? {
        guard !connecting, !signIn.isRunning else { return nil }
        // The form may have changed while the sign-in ran, so trying it again repeats the one that failed.
        // An edit after the failure lets go of it, and the form's inputs count again.
        if case .failed = signIn { return .stateTarget }
        if formNamesGateway { return .formInputs }
        return signIn.target == nil ? nil : .stateTarget
    }
}
