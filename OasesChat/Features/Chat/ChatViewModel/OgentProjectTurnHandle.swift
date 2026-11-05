enum OgentConversationMemorySelfTest {
    static func run() async -> String {
        await OgentConversationMemoryIngestor.runSelfTest()
    }

    static func runCompactionSelfTest() async -> String {
        await OgentConversationMemoryIngestor.runCompactionSelfTest()
    }
}

struct OgentProjectTurnHandle {
    let sessionID: String
    let projectID: String?
}

