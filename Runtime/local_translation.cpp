#include "local_translation.h"
#include "llama.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <iomanip>
#include <limits>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t maxPromptBytes = 65'536;
constexpr size_t maxPromptScalars = 32'768;
constexpr int prefillBatchSize = 128;
constexpr int maxOutputTokens = 256;
constexpr int maximumTimeoutMs = 120'000;

void discardLog(ggml_log_level, const char *, void *) {}
double milliseconds(Clock::time_point start, Clock::time_point end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
}
void copyString(char * destination, int capacity, const std::string & value) {
    if (!destination || capacity <= 0) return;
    const size_t count = std::min(value.size(), static_cast<size_t>(capacity - 1));
    std::memcpy(destination, value.data(), count);
    destination[count] = '\0';
}

// Tokens can hold only part of a UTF-8 character. Interrupted output and a
// bounded caller buffer must end at a complete character, even on failure.
size_t utf8Prefix(const std::string & value, size_t limit) {
    const size_t end = std::min(value.size(), limit);
    size_t offset = 0;
    while (offset < end) {
        const unsigned char lead = static_cast<unsigned char>(value[offset]);
        size_t length;
        if (lead <= 0x7f) length = 1;
        else if (lead >= 0xc2 && lead <= 0xdf) length = 2;
        else if (lead >= 0xe0 && lead <= 0xef) length = 3;
        else if (lead >= 0xf0 && lead <= 0xf4) length = 4;
        else break;
        if (offset + length > end) break;
        bool valid = true;
        for (size_t index = 1; index < length; ++index) {
            const unsigned char next = static_cast<unsigned char>(value[offset + index]);
            if ((next & 0xc0) != 0x80) valid = false;
        }
        if (length >= 3) {
            const unsigned char next = static_cast<unsigned char>(value[offset + 1]);
            if ((lead == 0xe0 && next < 0xa0) || (lead == 0xed && next >= 0xa0) ||
                (lead == 0xf0 && next < 0x90) || (lead == 0xf4 && next >= 0x90)) valid = false;
        }
        if (!valid) break;
        offset += length;
    }
    return offset;
}

struct Runtime {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    std::mutex inferenceMutex;
    std::atomic<uint64_t> activeRequest {0};
    std::atomic<uint64_t> cancelledRequest {0};
    Clock::time_point deadline;
    int contextSize = 2048;
    ~Runtime() {
        if (context) llama_free(context);
        if (model) llama_model_free(model);
    }
    int interruption() const {
        const uint64_t active = activeRequest.load(std::memory_order_acquire);
        if (active && cancelledRequest.load(std::memory_order_acquire) == active) return 1;
        if (Clock::now() >= deadline) return 2;
        return 0;
    }
};
bool abortInference(void * opaque) {
    return static_cast<Runtime *>(opaque)->interruption() != 0;
}

struct Metrics {
    Clock::time_point began = Clock::now();
    double firstTokenMs = -1;
    double prefillMs = 0;
    double decodeMs = 0;
    int promptTokens = 0;
    int wrapperControlTokens = 0;
    int bodyControlTokens = 0;
    int outputTokens = 0;
    bool eosReached = false;
    const char * error = "";
};

std::string metricsJSON(const Metrics & metrics, uint64_t requestID, int contextSize, int result) {
    std::ostringstream json;
    json << std::fixed << std::setprecision(3);
    json << "{\"request_id\":" << requestID << ",\"result\":" << result << ",\"ttft_ms\":";
    if (metrics.firstTokenMs >= 0) json << metrics.firstTokenMs;
    else json << "null";
    json << ",\"total_ms\":" << milliseconds(metrics.began, Clock::now())
         << ",\"prefill_ms\":" << metrics.prefillMs
         << ",\"decode_ms\":" << metrics.decodeMs
         << ",\"prompt_tokens\":" << metrics.promptTokens
         << ",\"wrapper_control_tokens\":" << metrics.wrapperControlTokens
         << ",\"body_control_tokens\":" << metrics.bodyControlTokens
         << ",\"output_tokens\":" << metrics.outputTokens
         << ",\"context_tokens\":" << contextSize
         << ",\"cancelled\":" << (result == 1 ? "true" : "false")
         << ",\"timed_out\":" << (result == 2 ? "true" : "false")
         << ",\"truncated\":" << (result == 3 ? "true" : "false")
         << ",\"eos_reached\":" << (metrics.eosReached ? "true" : "false")
         << ",\"error\":\"" << metrics.error << "\"}";
    return json.str();
}

struct Batch {
    llama_batch value = llama_batch_init(prefillBatchSize, 0, 1);
    ~Batch() { llama_batch_free(value); }
    void set(const llama_token * tokens, int count, int position, bool finalPrompt) {
        value.n_tokens = count;
        for (int index = 0; index < count; ++index) {
            value.token[index] = tokens[index];
            value.pos[index] = position + index;
            value.n_seq_id[index] = 1;
            value.seq_id[index][0] = 0;
            value.logits[index] = finalPrompt && index == count - 1;
        }
    }
};

// These are the pinned models' exact single-user wrappers. A role spelling in
// source text, dictionary text or context is data, even when identical to one
// of these tokens. Never enable special parsing for the untrusted body.
struct PromptParts { std::string_view prefix, body, suffix; };
bool splitPrompt(std::string_view prompt, PromptParts & parts) {
    constexpr std::string_view smallPrefix = "<｜hy_begin▁of▁sentence｜><｜hy_User｜>";
    constexpr std::string_view smallSuffix = "<｜hy_Assistant｜>";
    constexpr std::string_view densePrefix = "<|startoftext|>";
    constexpr std::string_view denseSuffix = "<|extra_0|>";
    for (const auto & wrapper : {std::pair {smallPrefix, smallSuffix}, std::pair {densePrefix, denseSuffix}}) {
        if (!prompt.starts_with(wrapper.first)) continue;
        if (!prompt.ends_with(wrapper.second) || prompt.size() <= wrapper.first.size() + wrapper.second.size()) return false;
        parts = {wrapper.first,
            prompt.substr(wrapper.first.size(), prompt.size() - wrapper.first.size() - wrapper.second.size()), wrapper.second};
        return true;
    }
    // Existing ABI checks and diagnostics also use unwrapped prompts. They
    // remain supported as literal text without implicit BOS/EOS insertion.
    parts = {{}, prompt, {}};
    return true;
}

bool tokenizePart(const llama_vocab * vocabulary, std::string_view part, bool special,
                  std::vector<llama_token> & tokens, int capacity, Metrics & metrics) {
    if (part.empty()) return true;
    std::vector<llama_token> piece(capacity);
    const int count = llama_tokenize(vocabulary, part.data(), static_cast<int>(part.size()),
        piece.data(), capacity, false, special);
    if (count <= 0 || count > capacity || static_cast<int>(tokens.size()) + count > capacity) return false;
    for (int index = 0; index < count; ++index) {
        if (llama_vocab_is_control(vocabulary, piece[index])) {
            if (special) ++metrics.wrapperControlTokens;
            else ++metrics.bodyControlTokens;
        }
    }
    tokens.insert(tokens.end(), piece.begin(), piece.begin() + count);
    return true;
}
} // namespace

extern "C" void * lc_load(const char * modelPath, int gpuLayers, int contextSize,
                          char * error, int errorCapacity) {
    copyString(error, errorCapacity, "");
    try {
        if (!modelPath || !*modelPath || (contextSize != 0 && contextSize != 2048 && contextSize != 4096)) {
            copyString(error, errorCapacity, "Invalid model path or context size; use 2048 or 4096.");
            return nullptr;
        }
        static std::once_flag initialized;
        std::call_once(initialized, [] {
            llama_log_set(discardLog, nullptr);
            ggml_log_set(discardLog, nullptr);
            // Static backends register themselves. Do not scan the executable
            // directory, working directory or GGML_BACKEND_PATH for plugins.
            llama_backend_init();
        });
        auto runtime = std::make_unique<Runtime>();
        runtime->contextSize = contextSize == 0 ? 2048 : contextSize;
        auto modelParameters = llama_model_default_params();
        modelParameters.n_gpu_layers = std::clamp(gpuLayers, -1, 999);
        modelParameters.progress_callback = nullptr;
        runtime->model = llama_model_load_from_file(modelPath, modelParameters);
        if (!runtime->model) {
            copyString(error, errorCapacity, "Local GGUF model could not be loaded.");
            return nullptr;
        }
        auto contextParameters = llama_context_default_params();
        contextParameters.n_ctx = runtime->contextSize;
        contextParameters.n_batch = prefillBatchSize;
        contextParameters.n_ubatch = prefillBatchSize;
        contextParameters.n_seq_max = 1;
        const int threads = std::clamp(static_cast<int>(std::thread::hardware_concurrency() / 2), 1, 8);
        contextParameters.n_threads = threads;
        contextParameters.n_threads_batch = threads;
        contextParameters.no_perf = false;
        contextParameters.abort_callback = abortInference;
        contextParameters.abort_callback_data = runtime.get();
        // No inference is active during context construction.
        runtime->deadline = Clock::time_point::max();
        runtime->context = llama_init_from_model(runtime->model, contextParameters);
        if (!runtime->context) {
            copyString(error, errorCapacity, "Local inference context could not be created.");
            return nullptr;
        }
        return runtime.release();
    } catch (...) {
        copyString(error, errorCapacity, "Local runtime initialization failed.");
        return nullptr;
    }
}

extern "C" int lc_translate(void * handle, uint64_t requestID, const char * prompt,
                            int maxTokens, int timeoutMs, char * output, int outputCapacity,
                            char * statsJSON, int statsCapacity) {
    const size_t bytes = prompt ? strnlen(prompt, maxPromptBytes + 1) : 0;
    return lc_translate_bytes(handle, requestID, prompt, static_cast<int>(bytes), maxTokens,
        timeoutMs, output, outputCapacity, statsJSON, statsCapacity);
}

extern "C" int lc_translate_bytes(void * handle, uint64_t requestID, const char * prompt,
                                  int promptBytes, int maxTokens, int timeoutMs,
                                  char * output, int outputCapacity,
                                  char * statsJSON, int statsCapacity) {
    copyString(output, outputCapacity, "");
    copyString(statsJSON, statsCapacity, "");
    Metrics metrics;
    auto runtime = static_cast<Runtime *>(handle);
    int result = -1;
    std::string generated;
    bool inferenceStarted = false;
    auto finish = [&] {
        if (inferenceStarted) {
            llama_synchronize(runtime->context);
            if (result == 0 || result == 3) {
                if (const int interrupted = runtime->interruption(); interrupted != 0) result = interrupted;
            }
        }
        if (output && outputCapacity > 0) {
            const size_t count = utf8Prefix(generated, static_cast<size_t>(outputCapacity - 1));
            copyString(output, outputCapacity, generated.substr(0, count));
            if (result == 0 && count != generated.size()) result = 3;
        }
        copyString(statsJSON, statsCapacity,
            metricsJSON(metrics, requestID, runtime ? runtime->contextSize : 0, result));
        return result;
    };
    if (!runtime || !requestID || !prompt || promptBytes < 1 ||
        promptBytes > static_cast<int>(maxPromptBytes) || !output || outputCapacity < 1 ||
        maxTokens < 1 || maxTokens > maxOutputTokens || timeoutMs < 1 || timeoutMs > maximumTimeoutMs) {
        metrics.error = "Invalid runtime arguments.";
        return finish();
    }
    std::unique_lock lock(runtime->inferenceMutex, std::try_to_lock);
    if (!lock.owns_lock()) {
        result = -3;
        metrics.error = "Another inference request is active.";
        return finish();
    }
    struct ActiveGuard {
        Runtime * runtime;
        ~ActiveGuard() { runtime->activeRequest.store(0, std::memory_order_release); }
    } activeGuard {runtime};
    runtime->cancelledRequest.store(0, std::memory_order_release);
    runtime->deadline = metrics.began + std::chrono::milliseconds(timeoutMs);
    runtime->activeRequest.store(requestID, std::memory_order_release);
    inferenceStarted = true;
    try {
        const std::string input(prompt, static_cast<size_t>(promptBytes));
        if (input.find('\0') != std::string::npos || utf8Prefix(input, input.size()) != input.size()) {
            metrics.error = "Prompt contains NUL or invalid UTF-8.";
            return finish();
        }
        const size_t scalars = std::count_if(input.begin(), input.end(), [](unsigned char byte) {
            return (byte & 0xc0) != 0x80;
        });
        if (scalars > maxPromptScalars) {
            metrics.error = "Prompt exceeds the Unicode scalar limit.";
            return finish();
        }
        PromptParts parts;
        if (!splitPrompt(input, parts)) {
            metrics.error = "Incomplete Hy-MT2 chat wrapper.";
            return finish();
        }
        const llama_vocab * vocabulary = llama_model_get_vocab(runtime->model);
        std::vector<llama_token> tokens;
        tokens.reserve(runtime->contextSize);
        if (!tokenizePart(vocabulary, parts.prefix, true, tokens, runtime->contextSize, metrics) ||
            !tokenizePart(vocabulary, parts.body, false, tokens, runtime->contextSize, metrics) ||
            !tokenizePart(vocabulary, parts.suffix, true, tokens, runtime->contextSize, metrics) ||
            metrics.bodyControlTokens != 0 || tokens.empty() || tokens.size() + maxTokens > static_cast<size_t>(runtime->contextSize)) {
            result = -2;
            metrics.promptTokens = static_cast<int>(tokens.size());
            metrics.error = "Prompt and output budget exceed the fixed context.";
            return finish();
        }
        const int tokenCount = static_cast<int>(tokens.size());
        metrics.promptTokens = tokenCount;
        llama_memory_clear(llama_get_memory(runtime->context), true);
        llama_perf_context_reset(runtime->context);
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
            llama_sampler_init_greedy(), llama_sampler_free);
        if (!sampler) {
            metrics.error = "Sampler allocation failed.";
            return finish();
        }
        Batch batch;
        const auto prefillBegan = Clock::now();
        for (int position = 0; position < tokenCount; position += prefillBatchSize) {
            result = runtime->interruption();
            if (result != 0) {
                metrics.prefillMs = milliseconds(prefillBegan, Clock::now());
                return finish();
            }
            const int count = std::min(prefillBatchSize, tokenCount - position);
            batch.set(tokens.data() + position, count, position, position + count == tokenCount);
            const int decoded = llama_decode(runtime->context, batch.value);
            llama_synchronize(runtime->context);
            if (decoded != 0) {
                result = runtime->interruption();
                if (result == 0) { result = -4; metrics.error = "Prompt decoding failed."; }
                metrics.prefillMs = milliseconds(prefillBegan, Clock::now());
                return finish();
            }
        }
        // GPU execution may be asynchronous until logits are requested.
        llama_synchronize(runtime->context);
        metrics.prefillMs = milliseconds(prefillBegan, Clock::now());
        const auto decodeBegan = Clock::now();
        for (int index = 0; index < maxTokens; ++index) {
            result = runtime->interruption();
            if (result != 0) break;
            const llama_token token = llama_sampler_sample(sampler.get(), runtime->context, -1);
            if (llama_vocab_is_eog(vocabulary, token)) {
                metrics.eosReached = true;
                result = 0;
                break;
            }
            std::vector<char> piece(64);
            int length = llama_token_to_piece(vocabulary, token, piece.data(),
                static_cast<int>(piece.size()), 0, false);
            if (length < 0) {
                piece.resize(static_cast<size_t>(-length));
                length = llama_token_to_piece(vocabulary, token, piece.data(),
                    static_cast<int>(piece.size()), 0, false);
            }
            if (length < 0) { result = -4; metrics.error = "Token decoding failed."; break; }
            generated.append(piece.data(), static_cast<size_t>(length));
            ++metrics.outputTokens;
            if (length > 0 && metrics.firstTokenMs < 0) {
                metrics.firstTokenMs = milliseconds(metrics.began, Clock::now());
            }
            if (generated.size() >= static_cast<size_t>(outputCapacity) || index + 1 == maxTokens) {
                result = 3;
                break;
            }
            batch.set(&token, 1, tokenCount + index, true);
            const int decoded = llama_decode(runtime->context, batch.value);
            llama_synchronize(runtime->context);
            if (decoded != 0) {
                result = runtime->interruption();
                if (result == 0) { result = -4; metrics.error = "Token generation failed."; }
                break;
            }
        }
        llama_synchronize(runtime->context);
        metrics.decodeMs = milliseconds(decodeBegan, Clock::now());
        if (result == 0 && !metrics.eosReached) result = 3;
        // If cancellation arrived while the final GPU operation completed,
        // honor it before returning a result to the caller.
        if (const int interrupted = runtime->interruption(); interrupted != 0) result = interrupted;
        return finish();
    } catch (...) {
        result = -5;
        metrics.error = "Local inference failed.";
        return finish();
    }
}

extern "C" void lc_cancel(void * handle, uint64_t requestID) {
    if (!handle || !requestID) return;
    auto runtime = static_cast<Runtime *>(handle);
    uint64_t previous = runtime->cancelledRequest.load(std::memory_order_acquire);
    for (;;) {
        if (runtime->activeRequest.load(std::memory_order_acquire) != requestID || previous == requestID) return;
        if (runtime->cancelledRequest.compare_exchange_weak(previous, requestID,
                std::memory_order_acq_rel, std::memory_order_acquire)) return;
    }
}

extern "C" void lc_free(void * handle) {
    if (!handle) return;
    auto runtime = static_cast<Runtime *>(handle);
    lc_cancel(handle, runtime->activeRequest.load(std::memory_order_acquire));
    // Free waits for actual native completion, rather than assuming a Swift
    // task cancellation has already released GPU/CPU resources.
    { std::lock_guard lock(runtime->inferenceMutex); }
    delete runtime;
}

extern "C" const char * lc_version(void) {
    return "caption-local-runtime/1 llama.cpp/v0.5.0 " LC_LLAMA_PIN;
}
