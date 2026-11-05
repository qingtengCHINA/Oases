import Foundation

/// Native host-side artifact bridge for project deliverables.
///
/// The Linux sandbox remains the agent workspace, but some user-facing
/// artifacts are better produced by stable native primitives than by asking
/// Alpine to install packages at runtime. This keeps common tasks like
/// "make a PPTX" and "download this direct file URL" from ending as a long
/// chain of package probes with no final file.
final class ArtifactBridgeTool: AgentTool, @unchecked Sendable {
    let descriptor = ToolDescriptor(
        name: "artifact_bridge",
        summary: """
        Create or download user-facing deliverable files directly into iOS Documents/Ogent Artifacts. \
        Use action=create_pptx when the user asks for a PPTX deck and shell dependencies are not required. \
        Use action=create_docx when the user asks for a Word document/report from gathered content. \
        Use action=download_url for direct http/https file or video URLs. \
        Returns an openable file marker for preview/share in the chat UI.
        """,
        displayName: "Artifacts", // i18n-ignore: source label for planner/ToolCatalog routing; UI uses localizedDisplayName
        localizedDisplayName: String(localized: "Artifacts", comment: "Tool name on tool cards"),
        inputSchemaJSON: """
        {"type":"object","required":["action"],"properties":{"action":{"type":"string","enum":["create_pptx","create_docx","download_url"]},"filename":{"type":"string","description":"Output filename. .pptx/.docx is added for create actions when missing."},"title":{"type":"string","description":"Deck or document title."},"slides":{"type":"array","description":"Slides for create_pptx.","items":{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"},"bullets":{"type":"array","items":{"type":"string"}}}}},"sections":{"type":"array","description":"Sections for create_docx.","items":{"type":"object","properties":{"heading":{"type":"string"},"body":{"type":"string"},"bullets":{"type":"array","items":{"type":"string"}}}}},"content":{"type":"string","description":"Plain text or markdown-like body for create_docx."},"url":{"type":"string","description":"Direct http/https URL for download_url."},"timeout":{"type":"number","description":"Download timeout seconds.","default":600}}}
        """,
        surfaces: [.project],
        requiresPermission: true
    )

    func invoke(argumentsJSON: String, onProgress: @escaping @Sendable (String) -> Void) async throws -> ToolResult {
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        let action = ((args["action"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "create_pptx":
            return try Self.createPPTX(args: args, onProgress: onProgress)
        case "create_docx":
            return try Self.createDOCX(args: args, onProgress: onProgress)
        case "download_url":
            return try await Self.downloadURL(args: args, onProgress: onProgress)
        default:
            return .textOnly("artifact_bridge requires action=create_pptx, action=create_docx, or action=download_url.")
        }
    }

    private static func createPPTX(
        args: [String: Any],
        onProgress: @escaping @Sendable (String) -> Void
    ) throws -> ToolResult {
        onProgress("[artifact] build pptx package\n")
        let title = ((args["title"] as? String) ?? "Ogent Deck")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let slides = parseSlides(args["slides"], fallbackTitle: title.isEmpty ? "Ogent Deck" : title)
        var filename = ((args["filename"] as? String) ?? "\(slug(title.isEmpty ? "ogent-deck" : title)).pptx")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if filename.isEmpty { filename = "ogent-deck.pptx" }
        if !filename.lowercased().hasSuffix(".pptx") {
            filename += ".pptx"
        }

        let target = try outputURL(filename: filename)
        let package = PPTXPackageBuilder(slides: slides)
        let archive = try package.build()
        try archive.write(to: target, options: .atomic)

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.int64Value
            ?? Int64(archive.count)
        return .textOnly("""
        Created PPTX: \(target.lastPathComponent)
        size=\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        ios=\(target.path)
        [oases:open]\(target.path)
        """)
    }

    private static func createDOCX(
        args: [String: Any],
        onProgress: @escaping @Sendable (String) -> Void
    ) throws -> ToolResult {
        onProgress("[artifact] build docx package\n")
        let title = ((args["title"] as? String) ?? "Ogent Document")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let content = (args["content"] as? String) ?? ""
        let sections = parseDocSections(
            args["sections"],
            content: content,
            fallbackTitle: title.isEmpty ? "Ogent Document" : title
        )
        var filename = ((args["filename"] as? String) ?? "\(slug(title.isEmpty ? "ogent-document" : title)).docx")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if filename.isEmpty { filename = "ogent-document.docx" }
        if !filename.lowercased().hasSuffix(".docx") {
            filename += ".docx"
        }

        let target = try outputURL(filename: filename)
        let package = DOCXPackageBuilder(
            title: title.isEmpty ? "Ogent Document" : title,
            sections: sections
        )
        let archive = try package.build()
        try archive.write(to: target, options: .atomic)

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.int64Value
            ?? Int64(archive.count)
        return .textOnly("""
        Created DOCX: \(target.lastPathComponent)
        size=\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        ios=\(target.path)
        [oases:open]\(target.path)
        """)
    }

    private static func downloadURL(
        args: [String: Any],
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> ToolResult {
        guard let raw = args["url"] as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .textOnly("artifact_bridge download_url requires a valid http/https url.")
        }

        let timeout = max(30, min((args["timeout"] as? NSNumber)?.doubleValue ?? 600, 3600))
        var filename = ((args["filename"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if filename.isEmpty {
            filename = url.lastPathComponent.isEmpty ? "download.bin" : url.lastPathComponent
        }
        if filename.isEmpty { filename = "download.bin" }

        onProgress("[artifact] download \(url.absoluteString)\n")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)
        let (temporaryURL, response) = try await session.download(from: url)
        defer { session.invalidateAndCancel() }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return .textOnly("[download error] HTTP status \(status)")
        }

        let target = try outputURL(filename: filename)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: temporaryURL, to: target)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: target.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let mime = response.mimeType ?? "application/octet-stream"

        return .textOnly("""
        Downloaded: \(target.lastPathComponent)
        mime=\(mime)
        size=\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        ios=\(target.path)
        [oases:open]\(target.path)
        """)
    }

    private static func parseSlides(_ value: Any?, fallbackTitle: String) -> [PPTXSlide] {
        guard let rawSlides = value as? [Any], !rawSlides.isEmpty else {
            return [
                PPTXSlide(title: fallbackTitle, bullets: ["Created locally on device.", "Generated by Ogent artifact bridge."])
            ]
        }

        let slides = rawSlides.compactMap { item -> PPTXSlide? in
            guard let dict = item as? [String: Any] else { return nil }
            let title = ((dict["title"] as? String) ?? "Slide")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var bullets: [String] = []
            if let array = dict["bullets"] as? [Any] {
                bullets += array.compactMap { $0 as? String }
            }
            if let body = dict["body"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bullets += body
                    .split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            let cleaned = bullets
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return PPTXSlide(title: title.isEmpty ? "Slide" : title, bullets: cleaned)
        }

        return slides.isEmpty
            ? [PPTXSlide(title: fallbackTitle, bullets: ["Created locally on device."])]
            : Array(slides.prefix(40))
    }

    private static func parseDocSections(_ value: Any?, content: String, fallbackTitle: String) -> [DOCXSection] {
        if let rawSections = value as? [Any], !rawSections.isEmpty {
            let sections = rawSections.compactMap { item -> DOCXSection? in
                guard let dict = item as? [String: Any] else { return nil }
                let heading = ((dict["heading"] as? String) ?? (dict["title"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var paragraphs: [String] = []
                var bullets: [String] = []
                if let body = dict["body"] as? String {
                    paragraphs = body
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                if let array = dict["bullets"] as? [Any] {
                    bullets = array
                        .compactMap { $0 as? String }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                }
                guard !heading.isEmpty || !paragraphs.isEmpty || !bullets.isEmpty else { return nil }
                return DOCXSection(heading: heading, paragraphs: paragraphs, bullets: bullets)
            }
            if !sections.isEmpty { return Array(sections.prefix(60)) }
        }

        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty else {
            return [DOCXSection(heading: fallbackTitle, paragraphs: ["Created locally on device by Ogent artifact bridge."], bullets: [])]
        }

        var sections: [DOCXSection] = []
        var currentHeading = fallbackTitle
        var paragraphs: [String] = []
        var bullets: [String] = []

        func flush() {
            let heading = currentHeading.trimmingCharacters(in: .whitespacesAndNewlines)
            if !heading.isEmpty || !paragraphs.isEmpty || !bullets.isEmpty {
                sections.append(DOCXSection(heading: heading, paragraphs: paragraphs, bullets: bullets))
            }
            paragraphs = []
            bullets = []
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                flush()
                currentHeading = line.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                bullets.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines))
            } else if line.isEmpty {
                continue
            } else {
                paragraphs.append(line)
            }
        }
        flush()
        return sections.isEmpty
            ? [DOCXSection(heading: fallbackTitle, paragraphs: [content], bullets: [])]
            : Array(sections.prefix(60))
    }

    private static func outputURL(filename: String) throws -> URL {
        let directory = ISHRootfsManager.exportsURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return uniqueDestination(in: directory, filename: filename)
    }

    private static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let fm = FileManager.default
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let base = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var candidate = directory.appendingPathComponent(cleaned)
        var index = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = directory.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private static func slug(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .lowercased()
        return collapsed.isEmpty ? "ogent-deck" : String(collapsed.prefix(48))
    }
}

private struct PPTXSlide {
    let title: String
    let bullets: [String]
}

private struct DOCXSection {
    let heading: String
    let paragraphs: [String]
    let bullets: [String]
}

private struct DOCXPackageBuilder {
    let title: String
    let sections: [DOCXSection]

    func build() throws -> Data {
        var archive = StoredZipArchive()
        try archive.add(path: "[Content_Types].xml", data: contentTypes())
        try archive.add(path: "_rels/.rels", data: rootRelationships())
        try archive.add(path: "docProps/core.xml", data: coreProperties())
        try archive.add(path: "docProps/app.xml", data: appProperties())
        try archive.add(path: "word/document.xml", data: document())
        try archive.add(path: "word/styles.xml", data: styles())
        return archive.finalize()
    }

    private func utf8(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func contentTypes() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
        """)
    }

    private func rootRelationships() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """)
    }

    private func coreProperties() -> Data {
        let escapedTitle = xmlEscape(title)
        let now = ISO8601DateFormatter().string(from: Date())
        return utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(escapedTitle)</dc:title><dc:creator>Ogent</dc:creator><cp:lastModifiedBy>Ogent</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """)
    }

    private func appProperties() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Ogent</Application><DocSecurity>0</DocSecurity><ScaleCrop>false</ScaleCrop><Company>Oases</Company><LinksUpToDate>false</LinksUpToDate><SharedDoc>false</SharedDoc><HyperlinksChanged>false</HyperlinksChanged><AppVersion>1.0</AppVersion></Properties>
        """)
    }

    private func document() -> Data {
        let body = documentBody()
        return utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """)
    }

    private func documentBody() -> String {
        var paragraphs = [paragraph(title, style: "Title")]
        let safeSections = sections.isEmpty
            ? [DOCXSection(heading: "", paragraphs: ["Created locally on device by Ogent."], bullets: [])]
            : sections

        for section in safeSections {
            let heading = section.heading.trimmingCharacters(in: .whitespacesAndNewlines)
            if !heading.isEmpty, heading != title {
                paragraphs.append(paragraph(heading, style: "Heading1"))
            }
            for item in section.paragraphs {
                paragraphs.append(paragraph(item, style: nil))
            }
            for item in section.bullets {
                paragraphs.append(bullet(item))
            }
        }
        return paragraphs.joined()
    }

    private func styles() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/><w:rPr><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="360"/></w:pPr><w:rPr><w:b/><w:sz w:val="44"/><w:szCs w:val="44"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:before="320" w:after="160"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:style></w:styles>
        """)
    }

    private func paragraph(_ text: String, style: String?) -> String {
        let styleXML = style.map { #"<w:pStyle w:val="\#($0)"/>"# } ?? ""
        return """
        <w:p><w:pPr>\(styleXML)<w:spacing w:after="120"/></w:pPr><w:r><w:t xml:space="preserve">\(xmlEscape(text))</w:t></w:r></w:p>
        """
    }

    private func bullet(_ text: String) -> String {
        """
        <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:spacing w:after="80"/><w:ind w:left="720" w:hanging="360"/></w:pPr><w:r><w:t xml:space="preserve">• \(xmlEscape(text))</w:t></w:r></w:p>
        """
    }

    private func xmlEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private struct PPTXPackageBuilder {
    let slides: [PPTXSlide]

    func build() throws -> Data {
        var archive = StoredZipArchive()
        let safeSlides = slides.isEmpty ? [PPTXSlide(title: "Ogent Deck", bullets: [])] : slides

        try archive.add(path: "[Content_Types].xml", data: contentTypes(slideCount: safeSlides.count))
        try archive.add(path: "_rels/.rels", data: rootRelationships())
        try archive.add(path: "ppt/presentation.xml", data: presentation(slideCount: safeSlides.count))
        try archive.add(path: "ppt/_rels/presentation.xml.rels", data: presentationRelationships(slideCount: safeSlides.count))
        try archive.add(path: "ppt/slideMasters/slideMaster1.xml", data: slideMaster())
        try archive.add(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: slideMasterRelationships())
        try archive.add(path: "ppt/slideLayouts/slideLayout1.xml", data: slideLayout())
        try archive.add(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: slideLayoutRelationships())
        try archive.add(path: "ppt/theme/theme1.xml", data: theme())

        for (index, slide) in safeSlides.enumerated() {
            let number = index + 1
            try archive.add(path: "ppt/slides/slide\(number).xml", data: slideXML(slide: slide, index: number))
            try archive.add(path: "ppt/slides/_rels/slide\(number).xml.rels", data: slideRelationships())
        }

        return archive.finalize()
    }

    private func utf8(_ string: String) -> Data {
        Data(string.utf8)
    }

    private func contentTypes(slideCount: Int) -> Data {
        let slides = (1...slideCount)
            .map { #"<Override PartName="/ppt/slides/slide\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"# }
            .joined()
        return utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\(slides)</Types>
        """)
    }

    private func rootRelationships() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>
        """)
    }

    private func presentation(slideCount: Int) -> Data {
        let ids = (1...slideCount)
            .map { #"<p:sldId id="\#(255 + $0)" r:id="rId\#($0 + 1)"/>"# }
            .joined()
        return utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """)
    }

    private func presentationRelationships(slideCount: Int) -> Data {
        let slides = (1...slideCount)
            .map { #"<Relationship Id="rId\#($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#($0).xml"/>"# }
            .joined()
        return utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>\(slides)</Relationships>
        """)
    }

    private func slideXML(slide: PPTXSlide, index: Int) -> Data {
        let title = xmlEscape(slide.title)
        let bullets = slide.bullets.isEmpty ? [""] : slide.bullets
        let bodyParagraphs = bullets.prefix(14).map { text in
            """
            <a:p><a:pPr marL="342900" indent="-171450"><a:buChar char="•"/></a:pPr><a:r><a:rPr lang="en-US" sz="2800"/><a:t>\(xmlEscape(text))</a:t></a:r></a:p>
            """
        }.joined()
        let accent = index % 2 == 0 ? "2F80ED" : "30D158"
        return utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="111116"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="720000" y="700000"/><a:ext cx="10700000" cy="1200000"/></a:xfrm><a:solidFill><a:srgbClr val="111116"/></a:solidFill></p:spPr><p:txBody><a:bodyPr wrap="square"/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" sz="4600" b="1"><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:rPr><a:t>\(title)</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="Body"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="860000" y="2150000"/><a:ext cx="10300000" cy="3900000"/></a:xfrm><a:solidFill><a:srgbClr val="111116"/></a:solidFill></p:spPr><p:txBody><a:bodyPr wrap="square"/><a:lstStyle/>\(bodyParagraphs)</p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="4" name="Accent"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="720000" y="1850000"/><a:ext cx="10400000" cy="70000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(accent)"/></a:solidFill></p:spPr></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """)
    }

    private func slideRelationships() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>
        """)
    }

    private func slideMaster() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="111116"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>
        """)
    }

    private func slideMasterRelationships() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
        """)
    }

    private func slideLayout() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """)
    }

    private func slideLayoutRelationships() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """)
    }

    private func theme() -> Data {
        utf8("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Ogent"><a:themeElements><a:clrScheme name="Ogent"><a:dk1><a:srgbClr val="111116"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F1F25"/></a:dk2><a:lt2><a:srgbClr val="F6F7FB"/></a:lt2><a:accent1><a:srgbClr val="2F80ED"/></a:accent1><a:accent2><a:srgbClr val="30D158"/></a:accent2><a:accent3><a:srgbClr val="FF9F0A"/></a:accent3><a:accent4><a:srgbClr val="FF453A"/></a:accent4><a:accent5><a:srgbClr val="BF5AF2"/></a:accent5><a:accent6><a:srgbClr val="64D2FF"/></a:accent6><a:hlink><a:srgbClr val="2F80ED"/></a:hlink><a:folHlink><a:srgbClr val="BF5AF2"/></a:folHlink></a:clrScheme><a:fontScheme name="Ogent"><a:majorFont><a:latin typeface="Aptos Display"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Aptos"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Ogent"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """)
    }

    private func xmlEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private struct StoredZipArchive {
    private struct Entry {
        let path: String
        let data: Data
        let crc32: UInt32
        let offset: UInt32
    }

    private var bytes = Data()
    private var entries: [Entry] = []

    mutating func add(path: String, data: Data) throws {
        let name = Data(path.utf8)
        guard name.count <= Int(UInt16.max), data.count <= Int(UInt32.max), bytes.count <= Int(UInt32.max) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let crc = CRC32.checksum(data)
        let offset = UInt32(bytes.count)

        bytes.appendLE32(0x04034b50)
        bytes.appendLE16(20)
        bytes.appendLE16(0)
        bytes.appendLE16(0)
        bytes.appendLE16(0)
        bytes.appendLE16(0)
        bytes.appendLE32(crc)
        bytes.appendLE32(UInt32(data.count))
        bytes.appendLE32(UInt32(data.count))
        bytes.appendLE16(UInt16(name.count))
        bytes.appendLE16(0)
        bytes.append(name)
        bytes.append(data)

        entries.append(Entry(path: path, data: data, crc32: crc, offset: offset))
    }

    mutating func finalize() -> Data {
        let centralOffset = UInt32(bytes.count)
        for entry in entries {
            let name = Data(entry.path.utf8)
            bytes.appendLE32(0x02014b50)
            bytes.appendLE16(20)
            bytes.appendLE16(20)
            bytes.appendLE16(0)
            bytes.appendLE16(0)
            bytes.appendLE16(0)
            bytes.appendLE16(0)
            bytes.appendLE32(entry.crc32)
            bytes.appendLE32(UInt32(entry.data.count))
            bytes.appendLE32(UInt32(entry.data.count))
            bytes.appendLE16(UInt16(name.count))
            bytes.appendLE16(0)
            bytes.appendLE16(0)
            bytes.appendLE16(0)
            bytes.appendLE16(0)
            bytes.appendLE32(0)
            bytes.appendLE32(entry.offset)
            bytes.append(name)
        }

        let centralSize = UInt32(bytes.count) - centralOffset
        bytes.appendLE32(0x06054b50)
        bytes.appendLE16(0)
        bytes.appendLE16(0)
        bytes.appendLE16(UInt16(entries.count))
        bytes.appendLE16(UInt16(entries.count))
        bytes.appendLE32(centralSize)
        bytes.appendLE32(centralOffset)
        bytes.appendLE16(0)
        return bytes
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i in
        var crc = UInt32(i)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
