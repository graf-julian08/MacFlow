import Foundation

/// Decides which tools apply to a dropped set of files. Like conversions,
/// tools only appear when their implementation can handle the actual files.
enum ToolCatalog {

    struct Tools: Equatable {
        var primary: [FileTool]
        var more: [FileTool]
        var isEmpty: Bool { primary.isEmpty && more.isEmpty }
        static let none = Tools(primary: [], more: [])
    }

    static let metadataFormats: Set<String> = ["jpg", "heic", "tiff", "png"]

    static func tools(for files: [ClassifiedFile]) -> Tools {
        let formats = files.compactMap(\.format)
        guard formats.count == files.count, let first = formats.first else { return .none }
        let category = first.category
        guard formats.allSatisfy({ $0.category == category }) else { return .none }
        let caps = EngineCapabilities.shared
        let single = files.count == 1

        switch category {
        case .image:
            guard formats.allSatisfy(caps.canDecodeImage) else { return .none }
            if single {
                var primary: [FileTool] = [.compress]
                if metadataFormats.contains(first.id) { primary.append(.metadata) }
                primary += [.adjust, .crop, .rotate, .redact, .background]
                var more: [FileTool] = [.resize, .removeBackground, .readQR, .annotate, .makePDF]
                if !metadataFormats.contains(first.id) { more.removeAll { $0 == .metadata } }
                return Tools(primary: primary, more: more)
            }
            var primary: [FileTool] = [.makePDF, .compress, .resize, .rotate, .adjust, .background]
            if formats.allSatisfy({ metadataFormats.contains($0.id) }) { primary.insert(.metadata, at: 2) }
            return Tools(primary: primary, more: [.removeBackground])

        case .video:
            guard formats.allSatisfy({ ConversionCatalog.avVideoSources.contains($0.id) }) else { return .none }
            if single {
                return Tools(primary: [.videoCompress, .trim, .videoRotate, .mute, .extractAudio, .snapshot, .speed], more: [])
            }
            return Tools(primary: [.videoCompress, .videoRotate, .mute, .extractAudio], more: [])

        case .audio:
            guard formats.allSatisfy({ ConversionCatalog.avAudioSources.contains($0.id) }) else { return .none }
            if single { return Tools(primary: [.audioTrim, .volume, .fade, .channels], more: []) }
            return Tools(primary: [.volume, .fade, .channels], more: [])

        case .pdf:
            if single {
                // Splitting a one-page PDF would only reproduce it.
                let more: [FileTool] = PDFTools.pageCount(files[0].url) > 1 ? [.splitPDF, .extractText] : [.extractText]
                return Tools(primary: [.pdfCompress, .pages, .pdfMetadata, .protect, .watermark, .pageNumbers, .ocr], more: more)
            }
            return Tools(primary: [.mergePDF, .pdfCompress, .protect, .watermark, .pageNumbers, .extractText], more: [])

        case .archive:
            guard caps.bsdtarPath != nil, formats.allSatisfy({ ConversionCatalog.archiveReadable.contains($0.id) || ["gz", "bz2", "xz"].contains($0.id) }) else { return .none }
            if single { return Tools(primary: [.extract, .archiveContents, .testArchive], more: []) }
            return Tools(primary: [.extract, .testArchive], more: [])

        case .structuredData:
            guard formats.allSatisfy({ $0.id == "json" }) else { return .none }
            return Tools(primary: [.prettyPrint, .minify], more: [])

        case .subtitle:
            guard formats.allSatisfy({ ["srt", "vtt", "sbv"].contains($0.id) }) else { return .none }
            return Tools(primary: [.shiftTiming], more: [])

        default:
            return .none
        }
    }
}

/// Where image-tool results go: the source format whenever it can be written
/// on this Mac, otherwise a format that keeps the image's qualities.
enum ImageToolOutput {
    static func format(for source: FileFormat, hasAlpha: Bool) -> FileFormat {
        let registry = FormatRegistry.shared
        let caps = EngineCapabilities.shared
        switch source.id {
        case "svg", "ico", "icns", "exr", "tga", "psd", "jxl":
            return registry["png"]
        case "raw":
            return registry["jpg"]
        case "gif":
            return registry["gif"]
        default:
            if caps.canEncodeImage(source) { return source }
            return hasAlpha ? registry["png"] : registry["jpg"]
        }
    }
}
