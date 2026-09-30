#include "local_translation.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
std::string escapeJSON(const std::string & input) {
    std::string output;
    for (const unsigned char character : input) {
        switch (character) {
        case '"': output += "\\\""; break;
        case '\\': output += "\\\\"; break;
        case '\n': output += "\\n"; break;
        case '\r': output += "\\r"; break;
        case '\t': output += "\\t"; break;
        default:
            if (character < 0x20) {
                constexpr char hex[] = "0123456789abcdef";
                output += "\\u00";
                output += hex[character >> 4];
                output += hex[character & 0xf];
            } else { output += character; }
        }
    }
    return output;
}
} // namespace

int main(int argc, char ** argv) {
    try {
        std::string modelPath, promptPath;
        int maxTokens = 256, timeoutMs = 30'000, gpuLayers = -1, contextSize = 2048;
        int iterations = 1, cancelAfterMs = -1;
        for (int index = 1; index < argc; ++index) {
            const std::string option = argv[index];
            if (option == "--version") { std::cout << lc_version() << '\n'; return 0; }
            if (option == "--help") {
                std::cout << "caption-local-benchmark --model FILE --prompt-file FILE "
                    "[--iterations N] [--max-tokens 1..256] [--timeout-ms N] "
                    "[--cancel-after-ms N] [--gpu-layers N] [--context 2048|4096]\n"
                    "Prompt files must contain the model's complete chat template. "
                    "JSON output includes the explicitly supplied test text.\n";
                return 0;
            }
            if (index + 1 >= argc) throw std::runtime_error("Missing argument value.");
            const std::string value = argv[++index];
            if (option == "--model") modelPath = value;
            else if (option == "--prompt-file") promptPath = value;
            else if (option == "--iterations") iterations = std::stoi(value);
            else if (option == "--max-tokens") maxTokens = std::stoi(value);
            else if (option == "--timeout-ms") timeoutMs = std::stoi(value);
            else if (option == "--cancel-after-ms") cancelAfterMs = std::stoi(value);
            else if (option == "--gpu-layers") gpuLayers = std::stoi(value);
            else if (option == "--context") contextSize = std::stoi(value);
            else throw std::runtime_error("Unknown argument.");
        }
        if (modelPath.empty() || promptPath.empty() || iterations < 1 || iterations > 100 ||
            cancelAfterMs > 120'000) throw std::runtime_error("Invalid benchmark arguments; use --help.");
        std::ifstream file(promptPath, std::ios::binary);
        if (!file) throw std::runtime_error("Could not open prompt file.");
        const std::string prompt((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        char error[1024];
        const auto loadBegan = std::chrono::steady_clock::now();
        void * handle = lc_load(modelPath.c_str(), gpuLayers, contextSize, error, sizeof(error));
        const double loadMs = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - loadBegan).count();
        if (!handle) {
            std::cout << "{\"event\":\"load\",\"success\":false,\"load_ms\":" << loadMs
                      << ",\"error\":\"" << escapeJSON(error) << "\"}\n";
            return 1;
        }
        std::cout << std::fixed << std::setprecision(3)
                  << "{\"event\":\"load\",\"success\":true,\"load_ms\":" << loadMs
                  << ",\"version\":\"" << escapeJSON(lc_version()) << "\"}\n" << std::flush;
        bool failed = false;
        for (int iteration = 0; iteration < iterations; ++iteration) {
            const uint64_t request = static_cast<uint64_t>(iteration + 1);
            std::vector<char> output(16'384), stats(4096);
            std::mutex doneMutex;
            std::condition_variable doneCondition;
            bool done = false;
            std::thread cancellation;
            if (cancelAfterMs >= 0) {
                cancellation = std::thread([&] {
                    std::unique_lock lock(doneMutex);
                    if (!doneCondition.wait_for(lock, std::chrono::milliseconds(cancelAfterMs), [&] { return done; })) {
                        lc_cancel(handle, request);
                    }
                });
            }
            const int result = lc_translate(handle, request, prompt.c_str(), maxTokens, timeoutMs,
                output.data(), static_cast<int>(output.size()), stats.data(), static_cast<int>(stats.size()));
            { std::lock_guard lock(doneMutex); done = true; }
            doneCondition.notify_one();
            if (cancellation.joinable()) cancellation.join();
            std::cout << "{\"event\":\"translation\",\"iteration\":" << iteration + 1
                      << ",\"result\":" << result << ",\"output\":\"" << escapeJSON(output.data())
                      << "\",\"stats\":" << (stats[0] ? stats.data() : "null") << "}\n" << std::flush;
            failed = failed || result < 0;
            // A stale cancellation must not poison the following iteration.
            lc_cancel(handle, request);
        }
        lc_free(handle);
        return failed ? 1 : 0;
    } catch (const std::exception & error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
