#if DEBUG
import Foundation

// MARK: - Error helpers (shared across DebugRPC* files)
//
// OpenMinis puts these at the top of `DebugRPCProviderChat.swift`; that
// file isn't ported here yet (its body drives `AIChatViewModel` via
// `ViewModelCache`, which needs the Sessions write-path bridge first).
// Extracting the two helpers into their own file lets the other
// `DebugRPC*` files compile and register their methods.

struct DebugRPCErr: Error {
    let code: Int
    let message: String
    init(_ code: Int, _ message: String) {
        self.code = code
        self.message = message
    }
}

func require<T>(_ value: T?, _ name: String) throws -> T {
    guard let v = value else {
        throw DebugRPCErr(-32602, "Missing required param: \(name)")
    }
    return v
}
#endif
