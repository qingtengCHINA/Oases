// i18n-ignore-file: the keyword table matches the user's prompt, the model's reasoning and shell commands in every language; it is never shown.
import Foundation

/// The objects the thinking "mind" can take. Each one is modelled in `DitherMind.metal`
/// (`shapeSDF`); the raw value is the shader's object id.
enum DitherMindShape: Int, CaseIterable, Sendable {
    case orb = 0
    case magnifier
    case globe
    case document
    case book
    case laptop
    case code
    case pencil
    case camera
    case bulb
    case clock
    case coins
    case cardBox
    case notes
    case heart
    case gears
    case bubble
    case calendar
    case pin
    case folder

    /// An object that suits a prompt, a stretch of reasoning or a command, or nil when
    /// nothing obvious fits.
    static func guess(_ text: String) -> DitherMindShape? {
        let t = text.lowercased()
        guard !t.isEmpty else { return nil }
        for (shape, words) in keywords where words.contains(where: { t.contains($0) }) {
            return shape
        }
        return nil
    }

    /// The object for a running Ogent step. Shell commands are read for a better fit (a
    /// `curl` is the web, `ffmpeg` a camera, `python` code).
    static func forStep(_ kind: AssistantBlockKind) -> DitherMindShape {
        switch kind {
        case .shellTool(let command):
            return guess(command) ?? .laptop
        case .browserTool:
            return .globe
        case .fileReadTool:
            return .document
        case .fileWriteTool, .fileEditTool:
            return .pencil
        case .readImageTool:
            return .camera
        case .memoryTool:
            return .cardBox
        case .text:
            return .bubble
        case .thinking, .info:
            return .orb
        }
    }

    /// The object for a text-chat tool call.
    static func forTool(named name: String) -> DitherMindShape {
        switch name {
        case "web_search": return .magnifier
        case "web_read": return .globe
        case "image_gen", "photo_list": return .camera
        case "speech_synth": return .notes
        case "calendar_read": return .calendar
        case "reminder_create": return .clock
        case "location_current": return .pin
        case "contact_search": return .bubble
        case "apple_clipboard": return .document
        case "memory_write", "memory_get": return .cardBox
        default: return .gears
        }
    }

    private static let keywords: [(DitherMindShape, [String])] = [
        (.magnifier, ["search", "look up", "lookup", "find ", "grep", "搜索", "查找", "查一下", "搜一下", "検索", "검색", "recherche", "suche", "поиск"]),
        (.globe, ["web", "website", "browser", "url", "http", "curl", "wget", "网页", "网站", "浏览", "ウェブ", "웹", "site"]),
        (.camera, ["image", "photo", "picture", "draw", "ffmpeg", "video", "图片", "照片", "画", "视频", "画像", "사진", "이미지"]),
        (.code, ["code", "swift", "python", "javascript", "function", "bug", "compile", "git ", "npm", "代码", "函数", "编译", "程序", "コード", "코드"]),
        (.laptop, ["terminal", "shell", "command", "install", "apk ", "pip ", "命令", "终端", "安装", "运行", "コマンド", "명령"]),
        (.document, ["file", "document", "pdf", "read", "cat ", "文件", "文档", "读取", "ファイル", "파일", "fichier", "datei"]),
        (.pencil, ["write", "draft", "edit", "rewrite", "essay", "写", "改写", "修改", "起草", "書", "작성"]),
        (.cardBox, ["remember", "memory", "recall", "记住", "记忆", "回忆", "記憶", "기억"]),
        (.calendar, ["calendar", "schedule", "meeting", "date", "日程", "日历", "会议", "日期", "予定", "일정"]),
        (.clock, ["time", "remind", "deadline", "alarm", "时间", "提醒", "闹钟", "時間", "시간"]),
        (.coins, ["price", "cost", "money", "budget", "pay", "stock", "价格", "钱", "预算", "费用", "股", "価格", "가격"]),
        (.pin, ["where", "location", "map", "address", "travel", "地址", "位置", "地图", "旅行", "在哪", "場所", "위치"]),
        (.bulb, ["idea", "brainstorm", "creative", "inspire", "想法", "创意", "灵感", "点子", "アイデア", "아이디어"]),
        (.notes, ["music", "song", "melody", "音乐", "歌", "音楽", "음악"]),
        (.book, ["book", "learn", "study", "explain", "history", "书", "学习", "解释", "历史", "本", "勉強", "공부"]),
        (.folder, ["folder", "directory", "workspace", "project", "ls ", "文件夹", "目录", "项目", "フォルダ", "폴더"]),
        (.gears, ["build", "setup", "config", "settings", "fix", "构建", "配置", "设置", "修复", "設定", "설정"]),
        (.heart, ["love", "health", "feel", "喜欢", "爱", "健康", "心情", "好き", "건강"]),
    ]
}
