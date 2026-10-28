import CWebP
import Foundation

enum WebPError: LocalizedError {
    case encodeFailed

    var errorDescription: String? { "The image could not be saved as WebP." }
}

/// Writes WebP files with libwebp.
enum WebPEncoder {
    /// `rgba` holds `height` rows of `stride` bytes, 4 bytes per pixel, colors not premultiplied by alpha.
    static func encode(rgba: UnsafeRawPointer, width: Int, height: Int, stride: Int, hasAlpha: Bool,
                       quality: Int, lossless: Bool, exif: Data?) throws -> Data {
        var config = WebPConfig()
        guard WebPConfigPreset(&config, WEBP_PRESET_PHOTO, Float(quality)) != 0 else { throw WebPError.encodeFailed }
        config.method = 4
        if lossless { config.lossless = 1; config.quality = 75 }  // quality is the effort spent shrinking, not a loss
        if hasAlpha { config.alpha_quality = 100 }
        guard WebPValidateConfig(&config) != 0 else { throw WebPError.encodeFailed }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw WebPError.encodeFailed }
        picture.width = Int32(width)
        picture.height = Int32(height)
        picture.use_argb = lossless || hasAlpha ? 1 : 0
        defer { WebPPictureFree(&picture) }
        let imported = hasAlpha
            ? WebPPictureImportRGBA(&picture, rgba.assumingMemoryBound(to: UInt8.self), Int32(stride))
            : WebPPictureImportRGBX(&picture, rgba.assumingMemoryBound(to: UInt8.self), Int32(stride))
        guard imported != 0 else { throw WebPError.encodeFailed }

        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        let ok = withUnsafeMutablePointer(to: &writer) { pointer -> Bool in
            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(pointer)
            return WebPEncode(&config, &picture) != 0
        }
        guard ok, let bytes = writer.mem else { throw WebPError.encodeFailed }
        let plain = Data(bytes: bytes, count: writer.size)
        guard let exif, !exif.isEmpty else { return plain }
        return (try? addExif(exif, to: plain)) ?? plain
    }

    /// Puts an EXIF block (TIFF data, without the "Exif" prefix) into a finished WebP file.
    static func addExif(_ exif: Data, to webp: Data) throws -> Data {
        try webp.withUnsafeBytes { (file: UnsafeRawBufferPointer) in
            try exif.withUnsafeBytes { (block: UnsafeRawBufferPointer) in
                var input = WebPData(bytes: file.bindMemory(to: UInt8.self).baseAddress, size: file.count)
                guard let mux = WebPMuxCreate(&input, 1) else { throw WebPError.encodeFailed }
                defer { WebPMuxDelete(mux) }
                var chunk = WebPData(bytes: block.bindMemory(to: UInt8.self).baseAddress, size: block.count)
                guard WebPMuxSetChunk(mux, "EXIF", &chunk, 1) == WEBP_MUX_OK else { throw WebPError.encodeFailed }
                var output = WebPData()
                WebPDataInit(&output)
                defer { WebPDataClear(&output) }
                guard WebPMuxAssemble(mux, &output) == WEBP_MUX_OK, let bytes = output.bytes else { throw WebPError.encodeFailed }
                return Data(bytes: bytes, count: output.size)
            }
        }
    }
}
