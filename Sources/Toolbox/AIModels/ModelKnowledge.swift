import Foundation

/// Turns a model's file name, format and owner into words a person can use: what it is and what it does.
enum ModelKnowledge {
    struct Description: Equatable {
        var name: String
        var summary: String
        var kind: ModelKind
        var tags: [String] = []
    }

    /// `label` is the file or folder name without its extension; `path` is where it sits inside the folder it was found in
    /// (used for matching only, never the whole path, so a folder called "Bookmarks" can't make anything a speech model).
    static func describe(label: String, path: String, format: String, owner: String?, gguf: GGUFInfo?) -> Description {
        let lower = label.lowercased()
        let haystack = lower + " " + path.lowercased()
        let quant = quantization(in: label)
        var tags = [format]
        if let quant { tags.append(quant) }
        if let size = gguf?.sizeLabel { tags.append("\(size) parameters") }

        // Models of specific apps first: the app's own words beat a guess from the name.
        if owner == "DigUp" || mentions(haystack, "embeddinggemma") {
            if lower.hasPrefix("mmproj") || gguf?.architecture == "clip" {
                return Description(name: "EmbeddingGemma 2 (images and audio)",
                                   summary: "The picture-and-sound half of EmbeddingGemma 2. DigUp uses it to understand photos, screenshots and recordings when it indexes them, so a search can find them by what they show or say.",
                                   kind: .embedding, tags: tags)
            }
            return Description(name: "EmbeddingGemma 2 (text)",
                               summary: "Turns text into numbers that capture its meaning. DigUp uses it to search your files by meaning, so a search finds notes about the same thing even when the words differ.",
                               kind: .embedding, tags: tags)
        }

        for rule in rules where rule.matches.contains(where: { mentions(haystack, $0) }) {
            return Description(name: rule.title ?? displayName(label, gguf), summary: rule.summary, kind: rule.kind, tags: tags + rule.tags)
        }

        if let arch = gguf?.architecture {
            if embeddingArchitectures.contains(arch) {
                return Description(name: displayName(label, gguf),
                                   summary: "Turns text into numbers that capture its meaning, for searching and matching by meaning rather than exact words.",
                                   kind: .embedding, tags: tags + [arch])
            }
            if arch == "clip" || gguf?.type == "mmproj" {
                return Description(name: displayName(label, gguf),
                                   summary: "The vision part of a language model: it lets the model look at pictures.",
                                   kind: .vision, tags: tags + [arch])
            }
            return Description(name: displayName(label, gguf),
                               summary: "A language model (\(arch)) that reads and writes text: chat, answers, summaries or code, depending on how it was trained. It runs on this Mac with llama.cpp-style apps.",
                               kind: .language, tags: tags + [arch])
        }

        switch format {
        case "Core ML": return Description(name: displayName(label, nil), summary: "A model in Apple's Core ML format\(owner.map { ", used by \($0)" } ?? ""). Core ML runs it on the Mac's Neural Engine and GPU.", kind: .other, tags: tags)
        case "ONNX": return Description(name: displayName(label, nil), summary: "A model in the portable ONNX format\(owner.map { ", used by \($0)" } ?? "").", kind: .other, tags: tags)
        case "Safetensors": return Description(name: displayName(label, nil), summary: "Model weights in the safetensors format, the usual way models are shared on Hugging Face\(owner.map { "; used by \($0)" } ?? "").", kind: .other, tags: tags)
        case "TensorFlow Lite": return Description(name: displayName(label, nil), summary: "A small TensorFlow Lite model\(owner.map { " used by \($0)" } ?? "") for on-device predictions.", kind: .other, tags: tags)
        default: return Description(name: displayName(label, nil), summary: "A machine-learning model file\(owner.map { " used by \($0)" } ?? "").", kind: .other, tags: tags)
        }
    }

    private struct Rule {
        let matches: [String]
        let title: String?
        let summary: String
        let kind: ModelKind
        var tags: [String] = []
    }

    private static let embeddingArchitectures: Set<String> = ["bert", "nomic-bert", "nomic-bert-moe", "jina-bert-v2", "jina-bert-v3", "gemma-embedding", "modern-bert", "neo-bert"]

    private static let rules: [Rule] = [
        Rule(matches: ["silero-vad", "silero_vad"], title: "Silero VAD",
             summary: "Hears when someone is speaking and when it is silent (voice activity detection), so apps can skip the quiet parts of a recording.", kind: .speech),
        Rule(matches: ["speakerkit", "pyannote", "speaker_segmenter", "speaker_embedder", "diariz"], title: nil,
             summary: "Works out who is speaking when in a recording (speaker detection), so a transcript can say \"Speaker 1\" and \"Speaker 2\".", kind: .speech),
        Rule(matches: ["whisper*", "ggml-tiny", "ggml-base", "ggml-small", "ggml-medium", "ggml-large", "parakeet*", "wav2vec*"], title: nil,
             summary: "Turns speech into text (transcription). It listens to audio and writes down what was said, on this Mac.", kind: .speech),
        Rule(matches: ["kokoro*", "piper", "xtts*", "bark", "tts"], title: nil,
             summary: "Turns written text into spoken audio (text to speech).", kind: .audio),
        Rule(matches: ["demucs*", "spleeter"], title: nil, summary: "Separates a song into vocals, drums, bass and other parts.", kind: .audio),
        Rule(matches: ["stable-diffusion*", "stable_diffusion*", "sdxl*", "sd_xl*", "flux", "sd3", "dreamshaper*"], title: nil,
             summary: "Creates images from a written description (text to image).", kind: .imageGeneration),
        Rule(matches: ["ltx*"], title: nil,
             summary: "Creates video, with sound, from a written description or a still picture (text to video, image to video).", kind: .videoGeneration),
        Rule(matches: ["realesrgan*", "esrgan*", "upscal*"], title: nil, summary: "Makes images bigger and sharper (upscaling).", kind: .vision),
        Rule(matches: ["u2net*", "isnet*", "birefnet*", "rembg*", "modnet*"], title: nil, summary: "Cuts the subject out of a photo by finding what is foreground and what is background.", kind: .vision),
        Rule(matches: ["segment-anything*", "sam_vit*", "sam2*", "mobile_sam*"], title: nil, summary: "Outlines any object in a picture that you point at (segmentation).", kind: .vision),
        Rule(matches: ["yolo*", "detr*", "ssd_mobilenet*", "efficientdet*"], title: nil, summary: "Finds and names the objects in a picture, such as people, cars or animals (object detection).", kind: .vision),
        Rule(matches: ["siglip", "clip"], title: nil, summary: "Understands pictures and text together, so a picture can be matched to a description.", kind: .vision),
        Rule(matches: ["resnet*", "mobilenet*", "efficientnet*", "vit-", "convnext*"], title: nil, summary: "Recognizes what is in a picture (image classification).", kind: .vision),
        Rule(matches: ["minilm*", "bge-", "bge_", "gte-", "e5-", "nomic-embed*", "mxbai*", "snowflake-arctic-embed*", "text-embedding", "sentence-transformers"], title: nil,
             summary: "Turns text into numbers that capture its meaning, for searching and matching by meaning rather than exact words.", kind: .embedding),
        Rule(matches: ["optimization_guide*", "optimization-guide*"], title: "Chrome on-device models",
             summary: "Small prediction models Chrome downloads to make browsing smoother and safer, such as guessing which pages you will open next. Chrome manages them.", kind: .other),
        Rule(matches: ["visualintelligence*", "visualgrounding*"], title: "Visual grounding (Apple)",
             summary: "Part of Apple's Visual Intelligence: it helps macOS understand what is in a picture. macOS manages and updates it.", kind: .vision),
        Rule(matches: ["llama*", "mistral*", "mixtral*", "gemma*", "qwen*", "phi-", "phi3", "phi4", "deepseek*", "smollm*", "glm", "gpt-oss", "nemotron*", "command-r", "granite*", "olmo*", "falcon*", "tinyllama*", "starcoder*", "codellama*", "yi-"], title: nil,
             summary: "A language model that reads and writes text: chat, answers, summaries or code. It runs on this Mac, without the internet.", kind: .language),
    ]

    /// Whether `word` appears as a word in `text`: it has to start one ("clip" is in "clip-vit", not in "paperclip"), and
    /// unless it ends in "*", "-" or "_" a letter may not follow ("clip" is not in "clipboard", "llama*" is in "llamafile").
    /// Digits may follow, so "gemma" finds "gemma3" and "qwen2.5".
    static func mentions(_ text: String, _ word: String) -> Bool {
        let open = word.hasSuffix("*"), core = open ? String(word.dropLast()) : word
        let tail = open || core.hasSuffix("-") || core.hasSuffix("_") ? "" : "(?![a-z])"
        return text.range(of: "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: core) + tail, options: .regularExpression) != nil
    }

    /// "Meta-Llama-3.1-8B-Instruct-Q4_K_M" → "Meta Llama 3.1 8B Instruct"
    static func displayName(_ label: String, _ gguf: GGUFInfo?) -> String {
        if let name = gguf?.name, !name.isEmpty { return name }
        var base = label
        if let quant = quantization(in: label), let range = base.range(of: quant, options: .caseInsensitive) { base.removeSubrange(range) }
        let words = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
        return words.isEmpty ? label : words.joined(separator: " ")
    }

    /// "Q8_0", "Q4_K_M", "F16", "BF16", "IQ3_XS" found in a file name.
    static func quantization(in label: String) -> String? {
        let pattern = #"(?i)(?<![A-Za-z0-9])(i?q[1-8]_[0-9a-z_]+|bf16|f16|f32)(?![A-Za-z0-9])"#
        guard let range = label.range(of: pattern, options: .regularExpression) else { return nil }
        return label[range].uppercased()
    }
}
