import Foundation

private let resolverLogger = AppLogger(category: "WebAppResolver")

/// Translates a `(scope, scopeContext, relativeHtmlPath)` triple into the
/// host file URL of the HTML and the directory the WebView is granted
/// read access to: the HTML's own folder, handed to
/// `WKWebView.loadFileURL(_:allowingReadAccessTo:)` so relative
/// `<script src="…">` / `<link href="…">` / `<img src="…">` references to
/// siblings and subfolders load.
///
/// All inputs are sandbox-relative so the row survives container UUID
/// rotation across reinstalls — the host base is recomputed at launch.
enum WebAppPathResolver {
    struct Resolved {
        let htmlURL: URL
        /// The directory passed to `loadFileURL(_:allowingReadAccessTo:)`:
        /// the folder that holds `htmlURL`, for every scope. Page JavaScript
        /// can read everything under it, so it is never the session root
        /// (that would expose attachments and the rest of the session) or a
        /// whole mounted folder.
        let readAccessRoot: URL
    }

    enum ResolveError: Error, CustomStringConvertible {
        case missingContext
        case unknownMount
        case sourceMissing
        case escapesScope

        var description: String {
            switch self {
            case .missingContext: return "WebApp shortcut is missing scope context (sessionId or mountId)."
            case .unknownMount:   return "Mount no longer exists or hasn't been authorized in this run."
            case .sourceMissing:  return "Source HTML file is missing — the file may have been moved or deleted."
            case .escapesScope:   return "WebApp shortcut path escapes its scope and was rejected."
            }
        }
    }

    /// Resolve a shortcut to a host URL pair. Caller is responsible for
    /// presenting `ResolveError` to the user (e.g. an offer to remove the
    /// stale tile). Reads `MountedFoldersManager.shared` on `MainActor`
    /// when the scope is `.mount`, so call from main.
    @MainActor
    static func resolve(_ shortcut: WebAppShortcut) throws -> Resolved {
        let base: URL
        switch shortcut.pathScope {
        case .sessionAttachment:
            guard let sid = shortcut.scopeContext else { throw ResolveError.missingContext }
            // OpenMinis exposes these roots as AIChatViewModel statics over its
            // `Library/MinisChat/minis/<sid>/...` tree. OasesChat routes the same
            // buckets through OasesFsRouter, which is session-aware.
            guard let url = OasesPathResolver.hostURL(
                forGuest: OasesPathResolver.attachments, sessionId: sid
            ) else { throw ResolveError.missingContext }
            base = url
        case .sessionWorkspace:
            guard let sid = shortcut.scopeContext else { throw ResolveError.missingContext }
            guard let url = OasesPathResolver.hostURL(
                forGuest: OasesPathResolver.workspace, sessionId: sid
            ) else { throw ResolveError.missingContext }
            base = url
        case .shared:
            // `shared` is the FileProvider-visible App Group root, not a
            // session bucket — same directory the Files app shows.
            base = AppGroup.fileProviderShared
        case .mount:
            guard let raw = shortcut.scopeContext, let mountId = UUID(uuidString: raw) else {
                throw ResolveError.missingContext
            }
            guard let mountRoot = MountedFoldersManager.shared.resolvedURL(for: mountId) else {
                throw ResolveError.unknownMount
            }
            base = mountRoot
        }

        // Strip any leading slash so appendingPathComponent doesn't anchor
        // the stored path absolutely (which would defeat the scope).
        let trimmed = shortcut.htmlPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Normalise the HTML and the scope root the same way, through
        // symlinks as well as "..": WebKit checks the read grant against real
        // paths, so two differently shaped paths make it refuse the load
        // ("outside the sandbox", a black screen), and a symlink inside the
        // scope pointing out of it must not pass a lexical prefix test.
        // (Same fix as upstream OpenMinis T-ios-webapp-shared-blackscreen.)
        let candidate = LocalHTMLSandbox.normalized(base.appendingPathComponent(trimmed))
        let scopeRoot = LocalHTMLSandbox.normalized(base)

        // Reject paths that escape the scope (e.g. "../../other-session/..").
        if !candidate.path.hasPrefix(scopeRoot.path + "/") && candidate.path != scopeRoot.path {
            resolverLogger.warning("resolve: path escapes scope; candidate=\(candidate.path) scopeRoot=\(scopeRoot.path)")
            throw ResolveError.escapesScope
        }

        if !FileManager.default.fileExists(atPath: candidate.path) {
            throw ResolveError.sourceMissing
        }

        // Read access is the HTML's own folder, whatever the scope. It used to
        // be the session root (attachments/, workspace/ and everything else
        // in the session) or the whole mount, which let page JavaScript read
        // unrelated files. Sibling and nested assets still load; a page that
        // reaches up with "../" no longer does. `candidate` is already
        // normalised and inside the scope, so its parent is too.
        let readAccessRoot = candidate.deletingLastPathComponent()

        return Resolved(htmlURL: candidate, readAccessRoot: readAccessRoot)
    }
}
