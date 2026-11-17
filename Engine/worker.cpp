#include "whisper.h" // Silero VAD
#include "parakeet.h"
#include "json.hpp"

// whisper.cpp vendors dr_wav inside miniaudio. Compile only its file decoder;
// microphone ownership and recording permissions stay in the macOS app.
#define MA_NO_DEVICE_IO
#define MA_NO_THREADING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_NO_FLAC
#define MA_NO_MP3
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <algorithm>
#include <charconv>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <unordered_set>
#include <variant>
#include <vector>
#include <unistd.h>
#if defined(__APPLE__)
#include <sys/event.h>
#elif defined(__linux__)
#include <signal.h>
#include <sys/prctl.h>
#endif

namespace {

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
constexpr size_t maxRequestBytes = 1024 * 1024;
constexpr size_t maxVocabularyBytes = 384 * 1024;
constexpr size_t maxPromptBytes = 8192;
constexpr size_t minSamples = PARAKEET_SAMPLE_RATE / 5;
constexpr size_t maxRecordingSeconds = 7200;
constexpr size_t maxSamples = PARAKEET_SAMPLE_RATE * maxRecordingSeconds;
// Parakeet's dynamic encoder attends across the whole clip, so memory grows
// quadratically with length. Long takes are decoded in bounded windows cut at
// detected pauses; anything up to one window is a single unchanged pass.
constexpr size_t windowSamples = PARAKEET_SAMPLE_RATE * 120;
constexpr size_t preferredCutSamples = PARAKEET_SAMPLE_RATE * 60;

void emit(const json &event) {
    std::cout << event.dump(-1, ' ', false, json::error_handler_t::replace) << '\n' << std::flush;
    if (!std::cout) std::_Exit(0); // The app closed its end of the pipe.
}

void emitError(const std::string &message, const std::string &id = {}) {
    json event = {{"type", "error"}, {"message", message}};
    if (!id.empty()) event["id"] = id;
    emit(event);
}

void libraryLog(ggml_log_level level, const char *message, void *) {
    // No debug logs: upstream debug output can contain decoded tokens.
    if (level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN) {
        std::fputs(message, stderr);
    }
}

void watchParent() {
    const pid_t parent = getppid();
    if (parent <= 1) std::_Exit(0);
#if defined(__linux__)
    // Kill even during an uninterruptible model call if the supervisor dies.
    if (prctl(PR_SET_PDEATHSIG, SIGKILL) == 0) {
        if (getppid() != parent) std::_Exit(0);
        return;
    }
#elif defined(__APPLE__)
    const int queue = kqueue();
    struct kevent change;
    EV_SET(&change, parent, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, nullptr);
    if (queue >= 0 && kevent(queue, &change, 1, nullptr, 0, nullptr) == 0) {
        std::thread([queue] {
            struct kevent event;
            while (kevent(queue, nullptr, 0, &event, 1, nullptr) < 0 && errno == EINTR) {}
            std::_Exit(0);
        }).detach();
        return;
    }
    if (queue >= 0) close(queue);
#endif
    std::thread([parent] {
        while (getppid() == parent) std::this_thread::sleep_for(std::chrono::seconds(1));
        std::_Exit(0);
    }).detach();
}

// Keep the decoder on the same file descriptor for the whole job; the decoded
// sample buffer below never needs to grow with the duration of the recording.
struct WaveFile {
    ma_dr_wav wav{};
    bool opened = false;
    WaveFile() = default;
    WaveFile(const WaveFile &) = delete;
    WaveFile &operator=(const WaveFile &) = delete;
    ~WaveFile() { if (opened) ma_dr_wav_uninit(&wav); }

    std::optional<std::string> open(const std::string &path) {
        std::error_code error;
        if (!std::filesystem::is_regular_file(path, error)) {
            return "The recording is missing or is not a regular file.";
        }
        const auto bytes = std::filesystem::file_size(path, error);
        if (error || bytes > maxSamples * sizeof(float) + 64 * 1024) {
            return "The recording cannot be read or exceeds the two-hour limit.";
        }
        opened = ma_dr_wav_init_file(&wav, path.c_str(), nullptr);
        if (!opened) return "The recording is not a readable WAV file.";
        if (wav.channels != 1 || wav.sampleRate != PARAKEET_SAMPLE_RATE) {
            return "The recording must be mono, 16 kHz WAV audio.";
        }
        if (!((wav.translatedFormatTag == 1 && wav.bitsPerSample == 16) ||
              (wav.translatedFormatTag == 3 && wav.bitsPerSample == 32))) {
            return "The recording must use PCM16 or float32 WAV samples.";
        }
        if (wav.totalPCMFrameCount < minSamples || wav.totalPCMFrameCount > maxSamples) {
            return "Record between 0.2 seconds and 2 hours of audio.";
        }
        return std::nullopt;
    }

    std::optional<std::string> read(float *samples, size_t count) {
        if (ma_dr_wav_read_pcm_frames_f32(&wav, count, samples) != count) return "The recording is incomplete.";
        for (size_t i = 0; i < count; ++i) {
            if (!std::isfinite(samples[i])) return "The recording contains invalid audio samples.";
            samples[i] = std::clamp(samples[i], -1.0f, 1.0f);
        }
        return std::nullopt;
    }
};

std::string trim(std::string text) {
    constexpr auto space = " \t\r\n";
    const auto first = text.find_first_not_of(space);
    if (first == std::string::npos) return {};
    return text.substr(first, text.find_last_not_of(space) - first + 1);
}

struct Window {
    size_t end; // Relative to the front of the rolling PCM buffer.
    bool hasSpeech;
};

// Look a little past the furthest possible cut. That gives Silero context
// for speech starting just before a boundary, even if the prefix was silent.
constexpr size_t lookaheadSamples = PARAKEET_SAMPLE_RATE;

std::optional<Window> nextWindow(whisper_vad_context *vad, const std::vector<float> &samples, size_t remaining) {
    const bool last = remaining <= windowSamples;
    // Leave a little context for the final window rather than decoding a
    // handful of frames on their own when a take just exceeds the limit.
    const size_t limit = last ? remaining : std::min(windowSamples, remaining - lookaheadSamples);
    // Silence elsewhere in the take must not dilute a brief or quiet phrase.
    // Skip only digital silence outright; let Silero decide on anything else.
    if (std::none_of(samples.begin(), samples.end(), [](float s) { return s != 0.0f; })) return Window{limit, false};

    auto detection = whisper_vad_default_params();
    detection.threshold = 0.5f;
    detection.min_speech_duration_ms = 120;
    const std::unique_ptr<whisper_vad_segments, decltype(&whisper_vad_free_segments)> speech(
        whisper_vad_segments_from_samples(vad, detection, samples.data(), static_cast<int>(samples.size())),
        whisper_vad_free_segments);
    if (!speech) return std::nullopt;
    const int count = whisper_vad_segments_n_segments(speech.get());
    if (last || count == 0) return Window{limit, count > 0};

    const auto toSample = [](float centiseconds) {
        return static_cast<size_t>(centiseconds * (PARAKEET_SAMPLE_RATE / 100));
    };
    size_t cut = limit, longest = 0;
    const auto considerPause = [&](size_t start, size_t end) {
        start = std::max(start, preferredCutSamples);
        end = std::min(end, limit);
        if (end > start && end - start >= longest) {
            longest = end - start;
            cut = start + longest / 2;
        }
    };
    size_t previousEnd = 0;
    for (int i = 0; i < count; ++i) {
        const size_t start = toSample(whisper_vad_segments_get_segment_t0(speech.get(), i));
        considerPause(previousEnd, start);
        previousEnd = toSample(whisper_vad_segments_get_segment_t1(speech.get(), i));
    }
    considerPause(previousEnd, limit);
    const auto firstSpeech = toSample(whisper_vad_segments_get_segment_t0(speech.get(), 0));
    return Window{cut, firstSpeech < cut};
}

std::optional<std::string> stringField(const json &request, const char *key) {
    const auto field = request.find(key);
    if (field == request.end() || !field->is_string()) return std::nullopt;
    const auto value = field->get<std::string>();
    if (value.find('\0') != std::string::npos) return std::nullopt;
    return value;
}

std::variant<std::vector<std::string>, std::string> vocabularyTerms(const json &request) {
    const auto field = request.find("vocabularyTerms");
    if (field == request.end()) {
        // Older callers supplied unstructured text. Preserve it as one complete
        // hint, or omit all of it if it cannot fit; never silently take a suffix.
        const auto prompt = request.contains("prompt") ? stringField(request, "prompt") : std::optional<std::string>("");
        if (!prompt || prompt->size() > maxPromptBytes) {
            return "Custom vocabulary must be a string of at most 8192 bytes.";
        }
        return prompt->empty() ? std::vector<std::string>{} : std::vector<std::string>{*prompt};
    }
    if (!field->is_array() || field->size() > 8192) {
        return "Vocabulary terms must be an ordered array of at most 8192 strings.";
    }
    std::vector<std::string> terms;
    std::unordered_set<std::string> seen;
    size_t bytes = 0;
    for (const auto &entry : *field) {
        if (!entry.is_string()) return "Vocabulary terms must contain only strings.";
        const auto term = entry.get<std::string>();
        if (term.empty() || term.size() > 16384 || trim(term) != term ||
            std::any_of(term.begin(), term.end(), [](unsigned char character) { return character < 32 || character == 127; })) {
            return "Vocabulary terms must be nonempty single-line text of at most 16384 bytes without surrounding whitespace.";
        }
        bytes += term.size();
        if (bytes > maxVocabularyBytes) return "Vocabulary terms exceed the 384 KB text limit.";
        if (seen.insert(term).second) terms.push_back(term);
    }
    return terms;
}

bool validLanguagePreference(const std::string &language) {
    static const std::unordered_set<std::string> languages = {
        "auto", "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu",
        "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk",
        // Legacy preferences guide proofreading, never Parakeet recognition.
        "ja", "zh", "ko", "hi", "ar"
    };
    return languages.count(language) > 0;
}

void transcribe(parakeet_context *context, whisper_vad_context *vad, int threads, const json &request) {
    const auto id = stringField(request, "id");
    if (!id || id->empty() || id->size() > 256) {
        emitError("A transcription request needs a nonempty id (up to 256 bytes).");
        return;
    }
    const auto path = stringField(request, "path");
    if (!path || path->empty() || path->size() > 4096) {
        emitError("A transcription request needs a valid WAV path.", *id);
        return;
    }
    const auto language = request.contains("language") ? stringField(request, "language") : std::optional<std::string>("en");
    if (!language || !validLanguagePreference(*language)) {
        emitError("The language preference is invalid.", *id);
        return;
    }
    const auto vocabulary = vocabularyTerms(request);
    if (const auto failure = std::get_if<std::string>(&vocabulary)) {
        emitError(*failure, *id);
        return;
    }

    const auto start = Clock::now();
    const auto &terms = std::get<std::vector<std::string>>(vocabulary);
    WaveFile file;
    if (const auto failure = file.open(*path)) {
        emitError(*failure, *id);
        return;
    }
    const auto total = static_cast<size_t>(file.wav.totalPCMFrameCount);
    auto parameters = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY);
    parameters.n_threads = threads;
    parameters.no_context = true; // Never leak one dictation (or window) into the next.
    std::vector<float> samples;
    samples.reserve(std::min(total, windowSamples + lookaheadSamples));
    std::string text;
    int lastProgress = -1;
    const auto report = [&](size_t done) {
        // Credit only completed ASR (or a skipped silent window), not merely
        // the end of the encoder callback, which precedes token decoding.
        const int percent = static_cast<int>(100ULL * done / total);
        if (percent != lastProgress) {
            lastProgress = percent;
            emit({{"type", "progress"}, {"id", *id}, {"value", percent / 100.0}});
        }
    };
    report(0);
    for (size_t done = 0; done < total;) {
        const size_t kept = samples.size();
        samples.resize(std::min(windowSamples + lookaheadSamples, total - done));
        if (const auto failure = file.read(samples.data() + kept, samples.size() - kept)) {
            emitError(*failure, *id);
            return;
        }
        const auto window = nextWindow(vad, samples, total - done);
        if (!window) {
            emitError("Local speech detection failed. Retry transcription.", *id);
            return;
        }
        if (window->hasSpeech) {
            // The full API, unlike parakeet_chunk, also handles windows longer
            // than the model's nominal encoder context without truncation.
            if (parakeet_full(context, parameters, samples.data(), static_cast<int>(window->end)) != 0) {
                emitError("Local transcription failed. Retry transcription.", *id);
                return;
            }
            std::string part;
            for (int i = 0; i < parakeet_full_n_segments(context); ++i) {
                part += parakeet_full_get_segment_text(context, i);
            }
            part = trim(std::move(part));
            if (!part.empty()) {
                if (!text.empty()) text += ' ';
                text += part;
            }
        }
        done += window->end;
        report(done);
        // Keep the unconsumed suffix, including lookahead. No source frame is
        // read twice, and consecutive ASR inputs neither overlap nor drop out.
        samples.erase(samples.begin(), samples.begin() + window->end);
    }
    emit({{"type", "result"}, {"id", *id}, {"text", trim(std::move(text))},
          {"duration", static_cast<double>(total) / PARAKEET_SAMPLE_RATE}, {"elapsed", std::chrono::duration<double>(Clock::now() - start).count()},
          // Parakeet auto-selects the spoken language but exposes no language ID
          // or vocabulary prompting API. Never claim a hint was applied.
          {"language", "auto"}, {"includedTerms", json::array()}, {"omittedTerms", terms},
          {"tokenCount", 0}, {"tokenBudget", 0}});
}

} // namespace

int main(int argc, char **argv) {
    std::ios::sync_with_stdio(false);
    std::string model;
    std::string vadModel;
    int threads = static_cast<int>(std::clamp(std::thread::hardware_concurrency(), 1u, 8u));
    for (int i = 1; i < argc; ++i) {
        const std::string argument = argv[i];
        if (argument == "--help") {
            std::fputs("Usage: inlay-engine --model PATH --vad-model PATH [--threads 1..32]\nJSON lines on stdin and stdout; diagnostics only on stderr.\n", stderr);
            return 0;
        }
        if ((argument != "--model" && argument != "--vad-model" && argument != "--threads") || i + 1 >= argc) {
            emitError("Usage: inlay-engine --model PATH --vad-model PATH [--threads 1..32]");
            return 2;
        }
        const std::string value = argv[++i];
        if (argument == "--model") {
            model = value;
        } else if (argument == "--vad-model") {
            vadModel = value;
        } else {
            const auto parsed = std::from_chars(value.data(), value.data() + value.size(), threads);
            if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size() || threads < 1 || threads > 32) {
                emitError("The thread count must be between 1 and 32.");
                return 2;
            }
        }
    }
    std::error_code error;
    if (model.empty() || !std::filesystem::is_regular_file(model, error)) {
        emitError("The speech model is missing. Configure the server's speech model path.");
        return 2;
    }
    if (vadModel.empty() || !std::filesystem::is_regular_file(vadModel, error)) {
        emitError("The speech detector is missing. Configure the server's VAD model path.");
        return 2;
    }

    watchParent();
    whisper_log_set(libraryLog, nullptr);
    parakeet_log_set(libraryLog, nullptr);
    ggml_log_set(libraryLog, nullptr);
    auto parameters = parakeet_context_default_params();
    parameters.use_gpu = true;
    const std::unique_ptr<parakeet_context, decltype(&parakeet_free)> context(
        parakeet_init_from_file_with_params(model.c_str(), parameters), parakeet_free);
    if (!context) {
        emitError("The model could not be loaded. Check available memory or download it again.");
        return 1;
    }
    auto vadParameters = whisper_vad_default_context_params();
    vadParameters.n_threads = std::min(threads, 2);
    vadParameters.use_gpu = false;
    const std::unique_ptr<whisper_vad_context, decltype(&whisper_vad_free)> vad(
        whisper_vad_init_from_file_with_params(vadModel.c_str(), vadParameters), whisper_vad_free);
    if (!vad) {
        emitError("The local speech detector could not load. Rebuild Inlay to restore it.");
        return 1;
    }
    emit({{"type", "ready"}, {"engineVersion", std::string("parakeet.cpp/") + parakeet_version()}});

    // Fixed-size reads prevent a malformed caller from allocating unbounded RAM.
    std::vector<char> buffer(maxRequestBytes + 1);
    while (std::cin.getline(buffer.data(), buffer.size())) {
        const auto request = json::parse(buffer.data(), nullptr, false);
        if (request.is_discarded() || !request.is_object()) {
            emitError("Expected one JSON object per line.");
            continue;
        }
        const auto type = stringField(request, "type");
        if (type == "quit") return 0;
        if (type != "transcribe") {
            emitError("Unknown request type.", stringField(request, "id").value_or(""));
            continue;
        }
        transcribe(context.get(), vad.get(), threads, request);
    }
    if (!std::cin.eof()) {
        emitError("The request exceeds the 1 MB limit.");
        return 2;
    }
    return 0;
}
