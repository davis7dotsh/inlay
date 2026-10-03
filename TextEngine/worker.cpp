#include "llama.h"
#include "json.hpp"

#include <algorithm>
#include <charconv>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <thread>
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
constexpr size_t maxRequestBytes = 64 * 1024;
constexpr size_t maxTextBytes = 24 * 1024;
constexpr size_t maxSystemPromptBytes = 4096;
constexpr int contextSize = 8192;
constexpr int maxOutputTokens = 2048;
constexpr int batchSize = 512;
constexpr auto inferenceLimit = std::chrono::seconds(15);
constexpr auto engineVersion = "llama.cpp-b10516-b95502ba-inlay3";

void emit(const json &event) {
    std::cout << event.dump(-1, ' ', false, json::error_handler_t::replace) << '\n' << std::flush;
    if (!std::cout) std::_Exit(0);
}

void emitError(const std::string &message, const std::string &id = {}) {
    json event = {{"type", "error"}, {"message", message}};
    if (!id.empty()) event["id"] = id;
    emit(event);
}

void libraryLog(ggml_log_level level, const char *message, void *) {
    // Never log token text or the prompt. Keep upstream diagnostics off stdout.
    if (level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN) std::fputs(message, stderr);
}

void watchParent() {
    const pid_t parent = getppid();
    if (parent <= 1) std::_Exit(0);
#if defined(__linux__)
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

std::optional<std::string> stringField(const json &request, const char *key) {
    const auto field = request.find(key);
    if (field == request.end() || !field->is_string()) return std::nullopt;
    const auto text = field->get<std::string>();
    if (text.find('\0') != std::string::npos) return std::nullopt;
    return text;
}

std::string trim(const std::string &text) {
    const auto first = text.find_first_not_of(" \r\n\t");
    if (first == std::string::npos) return {};
    return text.substr(first, text.find_last_not_of(" \r\n\t") - first + 1);
}

std::vector<llama_token> tokenize(const llama_vocab *vocab, const std::string &text, bool special) {
    const int count = -llama_tokenize(vocab, text.data(), static_cast<int>(text.size()), nullptr, 0, false, special);
    if (count <= 0 || count > contextSize) return {};
    std::vector<llama_token> tokens(count);
    if (llama_tokenize(vocab, text.data(), static_cast<int>(text.size()), tokens.data(), count, false, special) != count) return {};
    return tokens;
}

struct Deadline { Clock::time_point value; };
bool shouldAbort(void *context) { return Clock::now() >= static_cast<Deadline *>(context)->value; }

void correct(llama_context *context, const llama_vocab *vocab, const json &request) {
    const auto id = stringField(request, "id");
    if (!id || id->empty() || id->size() > 256) { emitError("A correction request needs a valid id."); return; }
    const auto text = stringField(request, "text");
    const auto language = stringField(request, "language");
    const auto systemPrompt = stringField(request, "systemPrompt");
    if (!text || trim(*text).empty() || text->size() > maxTextBytes) {
        emitError("The transcript is empty or too long for local correction.", *id); return;
    }
    if (!language || language->empty() || language->size() > 32) {
        emitError("A correction request needs a valid language.", *id); return;
    }
    if (!systemPrompt || trim(*systemPrompt).empty() || systemPrompt->size() > maxSystemPromptBytes) {
        emitError("The cleanup system prompt must be nonempty and fit within 4 KB.", *id); return;
    }
    const auto terms = request.find("terms");
    size_t termsBytes = 0;
    if (terms == request.end() || !terms->is_array() || terms->size() > 256) {
        emitError("Preferred terms must be a list of at most 256 words or phrases.", *id); return;
    }
    for (const auto &term : *terms) {
        if (!term.is_string()) { emitError("Preferred terms must be strings.", *id); return; }
        const auto value = term.get<std::string>();
        termsBytes += value.size();
        if (value.empty() || value.size() > 256 || value.find('\0') != std::string::npos || termsBytes > 16384) {
            emitError("Preferred terms exceed the local correction limit.", *id); return;
        }
    }

    const auto start = Clock::now();
    const std::string content = json{{"transcript", *text}, {"preferredTerms", *terms}, {"language", *language}}.dump();
    auto tokens = tokenize(vocab, "<|im_start|>system\n", true);
    // Custom system instructions and transcript JSON are ordinary content;
    // only these fixed strings can introduce ChatML role/control tokens.
    const auto system = tokenize(vocab, *systemPrompt, false);
    const auto userRole = tokenize(vocab, "<|im_end|>\n<|im_start|>user\n", true);
    const auto body = tokenize(vocab, content, false);
    const auto suffix = tokenize(vocab, "<|im_end|>\n<|im_start|>assistant\n", true);
    if (tokens.empty() || system.empty() || userRole.empty() || body.empty() || suffix.empty()) {
        emitError("Could not tokenize the cleanup prompt and transcript.", *id); return;
    }
    tokens.insert(tokens.end(), system.begin(), system.end());
    tokens.insert(tokens.end(), userRole.begin(), userRole.end());
    tokens.insert(tokens.end(), body.begin(), body.end());
    tokens.insert(tokens.end(), suffix.begin(), suffix.end());
    if (tokens.size() + maxOutputTokens > contextSize) {
        emitError("The cleanup prompt, transcript, and dictionary exceed the correction context. The original text is kept.", *id); return;
    }

    llama_memory_clear(llama_get_memory(context), true);
    const auto clear = [context](llama_context *) {
        llama_set_abort_callback(context, nullptr, nullptr);
        llama_memory_clear(llama_get_memory(context), true);
    };
    const std::unique_ptr<llama_context, decltype(clear)> clearAfter(context, clear);
    Deadline deadline{start + inferenceLimit};
    llama_set_abort_callback(context, shouldAbort, &deadline);
    const auto decode = [&](llama_token *data, int count) {
        return Clock::now() < deadline.value && llama_decode(context, llama_batch_get_one(data, count)) == 0;
    };
    for (size_t offset = 0; offset < tokens.size(); offset += batchSize) {
        const auto count = static_cast<int>(std::min<size_t>(batchSize, tokens.size() - offset));
        if (!decode(tokens.data() + offset, count)) {
            emitError("Local correction exceeded its time limit or could not decode. The original text is kept.", *id); return;
        }
    }

    const auto sampler = std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)>(llama_sampler_init_greedy(), llama_sampler_free);
    std::string output;
    for (int generated = 0; generated < maxOutputTokens; ++generated) {
        if (Clock::now() >= deadline.value) {
            emitError("Local correction exceeded its time limit. The original text is kept.", *id); return;
        }
        llama_token token = llama_sampler_sample(sampler.get(), context, -1);
        if (llama_vocab_is_eog(vocab, token)) {
            const auto result = trim(output);
            if (result.empty()) { emitError("The text model returned no correction.", *id); return; }
            emit({{"type", "result"}, {"id", *id}, {"text", result},
                  {"elapsed", std::chrono::duration<double>(Clock::now() - start).count()}});
            return;
        }
        std::vector<char> piece(256);
        int count = llama_token_to_piece(vocab, token, piece.data(), static_cast<int>(piece.size()), 0, false);
        if (count < 0) {
            piece.resize(static_cast<size_t>(-count));
            count = llama_token_to_piece(vocab, token, piece.data(), static_cast<int>(piece.size()), 0, false);
        }
        if (count < 0 || output.size() + static_cast<size_t>(count) > maxTextBytes) {
            emitError("The text model returned too much text. The original transcript is kept.", *id); return;
        }
        output.append(piece.data(), count);
        if (!decode(&token, 1)) {
            emitError("Local correction exceeded its time limit or could not decode. The original text is kept.", *id); return;
        }
    }
    // A truncated rewrite is never returned as a successful transcript.
    emitError("The correction reached its output limit. The original transcript is kept.", *id);
}
} // namespace

int main(int argc, char **argv) {
    watchParent();
    std::string modelPath;
    int threads = 4;
    for (int i = 1; i < argc; ++i) {
        const std::string argument = argv[i];
        if (argument == "--help") {
            std::fputs("Usage: inlay-text-engine --model MODEL.gguf [--threads 1..32]\nJSON lines on stdin and stdout; diagnostics only on stderr.\n", stderr);
            return 0;
        } else if (argument == "--model" && i + 1 < argc) modelPath = argv[++i];
        else if (argument == "--threads" && i + 1 < argc) {
            const std::string value = argv[++i];
            const auto parsed = std::from_chars(value.data(), value.data() + value.size(), threads);
            if (parsed.ec != std::errc() || parsed.ptr != value.data() + value.size() || threads < 1 || threads > 32) {
                emitError("The thread count must be between 1 and 32."); return 1;
            }
        } else { emitError("Usage: inlay-text-engine --model MODEL.gguf [--threads 1..32]"); return 1; }
    }
    std::error_code fileError;
    if (modelPath.empty() || !std::filesystem::is_regular_file(modelPath, fileError)) {
        emitError("The proof model is missing. Configure the server's GGUF model path."); return 1;
    }
    llama_log_set(libraryLog, nullptr);
    llama_backend_init();
    auto parameters = llama_model_default_params();
    parameters.n_gpu_layers = 99;
    const auto model = std::unique_ptr<llama_model, decltype(&llama_model_free)>(
        llama_model_load_from_file(modelPath.c_str(), parameters), llama_model_free);
    if (!model) { emitError("Could not load the local text model."); return 1; }
    auto contextParameters = llama_context_default_params();
    contextParameters.n_ctx = contextSize;
    contextParameters.n_batch = batchSize;
    contextParameters.n_ubatch = batchSize;
    contextParameters.n_threads = threads;
    contextParameters.n_threads_batch = threads;
    contextParameters.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
    contextParameters.no_perf = true;
    const auto context = std::unique_ptr<llama_context, decltype(&llama_free)>(
        llama_init_from_model(model.get(), contextParameters), llama_free);
    if (!context) { emitError("Could not allocate local text-model memory."); return 1; }
    emit({{"type", "ready"}, {"engineVersion", engineVersion}});
    std::string line;
    while (std::cin) {
        line.clear();
        char character;
        while (std::cin.get(character) && character != '\n') {
            if (line.size() >= maxRequestBytes) { emitError("Correction request exceeds 64 KB."); return 1; }
            line.push_back(character);
        }
        if (line.empty()) continue;
        try {
            const auto request = json::parse(line);
            if (request.is_object() && stringField(request, "type") == "quit") return 0;
            if (!request.is_object() || stringField(request, "type") != "correct") {
                emitError("Expected a correction request."); continue;
            }
            correct(context.get(), llama_model_get_vocab(model.get()), request);
        } catch (const json::exception &) { emitError("The correction request is invalid JSON."); }
        catch (const std::exception &) { emitError("The local text model could not correct this transcript."); }
    }
    return 0;
}
