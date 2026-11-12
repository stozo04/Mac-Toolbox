import CLlama
import Foundation

public enum EmbedderError: Error, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self { case .failed(let why): why }
    }
}

public enum Prompts {
    public static func query(_ text: String) -> String { "task: search result | query: \(text)" }
}

public final class LlamaEmbedder {
    public static let budgets = [70, 140, 280, 560, 1120]
    public static let dimension = 768
    public static let vectorVersion = 1
    public static let buildTag = LLAMA_BUILD_TAG
    public static var vectorSource: String {
        "google/embeddinggemma-2@\(EmbeddingModel.revision.prefix(7)) llama.cpp-vectors\(vectorVersion) text-q8_0+mmproj-q8_0"
    }

    public let textOnly: Bool
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var media: OpaquePointer?
    private var batch: OpaquePointer?
    private let vocab: OpaquePointer?
    private let embeddingSize: Int
    private let rowSize: Int
    private let maxTokens: Int
    private static let maxSequences = 16
    private static let audioSeconds = 30
    private var sequences: Int32 = 0
    private var tokens = 0
    private var position: llama_pos = 0

    public init(model files: EmbeddingModel.Located, textOnly: Bool) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(files.text.path, modelParams) else {
            throw EmbedderError.failed("Can't load \(files.text.lastPathComponent).")
        }
        let maxTokens = textOnly ? 512 : 2048
        var params = llama_context_default_params()
        params.n_ctx = UInt32(maxTokens)
        params.n_batch = UInt32(maxTokens)
        params.n_ubatch = UInt32(maxTokens)
        params.n_seq_max = UInt32(Self.maxSequences)
        params.kv_unified = true
        params.embeddings = true
        params.pooling_type = LLAMA_POOLING_TYPE_MEAN
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw EmbedderError.failed("Can't create a llama.cpp context.")
        }
        var media: OpaquePointer?
        if !textOnly {
            var mediaParams = mtmd_context_params_default()
            mediaParams.use_gpu = true
            mediaParams.print_timings = false
            mediaParams.warmup = true
            mediaParams.image_min_tokens = 1
            mediaParams.image_max_tokens = 1120
            media = mtmd_init_from_file(files.media.path, model, mediaParams)
            if media == nil {
                llama_free(context)
                llama_model_free(model)
                throw EmbedderError.failed("Can't load \(files.media.lastPathComponent).")
            }
        }
        self.textOnly = textOnly
        self.model = model
        self.context = context
        self.media = media
        batch = llama_batch_ext_init(context)
        vocab = llama_model_get_vocab(model)
        embeddingSize = Int(llama_model_n_embd_out(model))
        rowSize = Int(llama_model_n_embd_inp(model))
        self.maxTokens = maxTokens
        do {
            _ = try embedTexts([Prompts.query("warm up")])
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    public func close() {
        if let batch { llama_batch_ext_free(batch) }
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (batch, media, context, model) = (nil, nil, nil, nil)
    }

    public func embedTexts(_ texts: [String]) throws -> [[Float]] {
        guard context != nil else { throw EmbedderError.failed("The model is closed.") }
        reset()
        var vectors: [[Float]] = []
        for text in texts {
            let tokens = tokenize(text)
            if sequences == Self.maxSequences || self.tokens + tokens.count > maxTokens { vectors += try run() }
            begin()
            for token in tokens { try add(token: token) }
        }
        if sequences > 0 { vectors += try run() }
        return vectors
    }

    public func embedImage(_ path: String, budget: Int) throws -> [Float] {
        guard media != nil else { throw EmbedderError.failed("This model was started for text only.") }
        guard Self.budgets.contains(budget) else { throw EmbedderError.failed("Budget must be one of \(Self.budgets).") }
        return try embedMedia(path, image: true, budget: budget)
    }

    public func embedAudio(_ path: String) throws -> [Float] {
        guard media != nil else { throw EmbedderError.failed("This model was started for text only.") }
        return try embedMedia(path, image: false, budget: 0)
    }

    private func embedMedia(_ path: String, image: Bool, budget: Int) throws -> [Float] {
        let bitmap = try load(path, image: image, budget: budget)
        defer { mtmd_bitmap_free(bitmap) }
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        var bitmaps: [OpaquePointer?] = [bitmap]
        let status = String(cString: mtmd_default_marker()).withCString { marker in
            var text = mtmd_input_text(text: marker, text_len: strlen(marker), add_special: true, parse_special: true)
            return mtmd_tokenize(media, chunks, &text, &bitmaps, 1)
        }
        guard status == 0 else { throw EmbedderError.failed("Can't tokenize the input (\(status)).") }
        reset()
        begin()
        for index in 0..<mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, index)
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var count = 0
                guard let tokens = mtmd_input_chunk_get_tokens_text(chunk, &count) else { continue }
                for i in 0..<count { try add(token: tokens[i]) }
            } else {
                guard mtmd_encode_chunk(media, chunk) == 0, let rows = mtmd_get_output_embd(media) else {
                    throw EmbedderError.failed("The encoder failed on this input.")
                }
                try add(rows: rows, count: mtmd_input_chunk_get_n_tokens(chunk))
            }
        }
        return try run()[0]
    }

    private func load(_ path: String, image: Bool, budget: Int) throws -> OpaquePointer {
        let wrapper = mtmd_helper_bitmap_init_from_file(media, path, false, mtmd_helper_init_opt_default())
        if let video = wrapper.video_ctx {
            if let bitmap = wrapper.bitmap { mtmd_bitmap_free(bitmap) }
            mtmd_helper_video_free(video)
            throw EmbedderError.failed("Video goes in as frames and sound, not as a file.")
        }
        guard let bitmap = wrapper.bitmap else { throw EmbedderError.failed("Can't read the input.") }
        guard mtmd_bitmap_is_audio(bitmap) != image else {
            mtmd_bitmap_free(bitmap)
            throw EmbedderError.failed(image ? "Not an image." : "Not audio.")
        }
        if image {
            let width = Int(mtmd_bitmap_get_nx(bitmap)), height = Int(mtmd_bitmap_get_ny(bitmap))
            guard let target = ImageSizing.targetSize(height: height, width: width, budget: budget) else {
                mtmd_bitmap_free(bitmap)
                throw EmbedderError.failed("The image is too thin to embed.")
            }
            guard target != (height, width) else { return bitmap }
            defer { mtmd_bitmap_free(bitmap) }
            let pixels = ImageSizing.resizeBicubic(mtmd_bitmap_get_data(bitmap), width: width, height: height,
                                                   toWidth: target.width, toHeight: target.height)
            guard let resized = mtmd_bitmap_init(UInt32(target.width), UInt32(target.height), pixels) else {
                throw EmbedderError.failed("Can't resize the image.")
            }
            return resized
        }
        let samples = mtmd_bitmap_get_n_bytes(bitmap) / MemoryLayout<Float>.size
        let limit = Self.audioSeconds * Int(mtmd_get_audio_sample_rate(media))
        guard samples > limit else { return bitmap }
        defer { mtmd_bitmap_free(bitmap) }
        let prefix = mtmd_bitmap_get_data(bitmap).withMemoryRebound(to: Float.self, capacity: limit) {
            mtmd_bitmap_init_from_audio(limit, $0)
        }
        guard let prefix else { throw EmbedderError.failed("Can't cut the audio at 30 seconds.") }
        return prefix
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        }
        tokens.removeLast(tokens.count - Int(max(count, 0)))
        if tokens.count > maxTokens {
            tokens = Array(tokens[0..<(maxTokens - 1)]) + [llama_vocab_eos(vocab)]
        }
        return tokens
    }

    private func begin() {
        sequences += 1
        position = 0
    }

    private func reset() {
        llama_batch_ext_clear(batch)
        sequences = 0
        tokens = 0
    }

    private func add(token: llama_token) throws {
        try place(llama_batch_ext_add_token(batch, sequences - 1, token))
    }

    private func add(rows: UnsafeMutablePointer<Float>, count: Int) throws {
        for row in 0..<count {
            let embd = llama_embd(data: rows + row * rowSize, n_rows: 1, n_embd: rowSize)
            try place(llama_batch_ext_add_embd(batch, sequences - 1, embd))
        }
    }

    private func place(_ index: Int32) throws {
        guard index >= 0 else { throw EmbedderError.failed("The batch is full (\(index)).") }
        var pos: [llama_pos] = [position, 0, 0, 0]
        guard llama_batch_ext_set_pos(batch, index, &pos), llama_batch_ext_set_output_embd(batch, index, true) else {
            throw EmbedderError.failed("Can't place token \(index).")
        }
        position += 1
        tokens += 1
    }

    private func run() throws -> [[Float]] {
        defer { reset() }
        let status = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard status == 0 else { throw EmbedderError.failed("llama_process failed (\(status)).") }
        return try (0..<sequences).map { sequence in
            guard let pooled = llama_get_embeddings_seq(context, sequence) else {
                throw EmbedderError.failed("No pooled embedding for input \(sequence).")
            }
            var sum = 0.0
            for i in 0..<embeddingSize { sum += Double(pooled[i]) * Double(pooled[i]) }
            let scale = sum > 0 ? Float(1 / sum.squareRoot()) : 0
            return (0..<embeddingSize).map { pooled[$0] * scale }
        }
    }

    private static let backend: Void = {
        llama_log_set(LlamaLog.callback, nil)
        mtmd_helper_log_set(LlamaLog.callback, nil)
        llama_backend_init()
    }()
}

enum LlamaLog {
    static let callback: ggml_log_callback = { level, text, _ in
        guard let text, level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, level != GGML_LOG_LEVEL_CONT else { return }
        FileHandle.standardError.write(Data(String(cString: text).utf8))
    }
}
