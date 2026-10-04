Local translation runtime

This runtime is independent of other Javis engines. It exposes a small C ABI
from one dylib, links pinned llama.cpp/ggml statically, embeds Metal kernel source,
and uses only Apple system frameworks at runtime. It has no server, HTTP client,
background model download, cloud fallback, or user-text logging.
It never scans external backend plugins or reads GGML_BACKEND_PATH.

Build:
  ./scripts/build-local-runtime.sh

Outputs:
  .build/local-runtime/libcaption_local_translation.dylib
  .build/local-runtime/caption-local-benchmark

The app copies the dylib to Contents/Frameworks and signs it before signing the
app. The library install name is @rpath/libcaption_local_translation.dylib; it
can also be loaded by absolute bundle path via dlopen. No companion llama/ggml
dylib or shader file needs copying. Third-party notices should retain llama.cpp's
MIT license (Runtime/llama-cpp-LICENSE.txt). Model files are installed separately
and must retain their own upstream attribution/license.

Pinned upstream source:
  https://github.com/ggml-org/llama.cpp/tree/7fe450e19305b828c199d602c23a8337aaa1f03b
  llama.cpp v0.5.0 / b11146
  Archive SHA-256: a6861d549427f814dc591c439e08206f67ffaba0248344d421589abf18199e67
Local build tools: cmake 4.1.2 and ninja 1.13.0 in .build/tools/local-runtime.
No global packages are installed. Build inputs are downloaded only when absent.

The exact official Hy-MT2-1.8B single-user chat format is:
  <｜hy_begin▁of▁sentence｜><｜hy_User｜>PROMPT<｜hy_Assistant｜>
The response ends with the model's <｜hy_place▁holder▁no▁2｜> EOG token.
Source: https://huggingface.co/tencent/Hy-MT2-1.8B/raw/main/chat_template.jinja
The caller supplies this already-formatted UTF-8 prompt. The dense 7B wrapper is
<|startoftext|>PROMPT<|extra_0|>. Only these exact outer wrappers enable special
token parsing; all body text is tokenized literally, including role-token
spellings supplied in source, context or dictionaries. Automatic BOS insertion
is disabled. Initial decoding is greedy. The app also keeps its fast baseline
when input contains reserved model markers, without modifying recognized text.

lc_translate_bytes takes the exact UTF-8 byte length and rejects embedded NUL,
invalid UTF-8, incomplete wrappers and more than 32,768 Unicode scalars. The app
and benchmark use this entry point, so text cannot be silently cut at a C-string
boundary. Legacy lc_translate remains available for NUL-terminated clients and
shares the same literal-body tokenization policy.

One handle has one context and admits one translate call at a time. Context is
2048 or 4096 tokens; generation is at most 256 tokens; prompts are at most 64KiB
and must fit together with the output allowance. KV memory is cleared between
requests, including a request after cancellation. No transcript cache is reused.

lc_cancel acts only on its active nonzero request ID. The caller must check a
cancelled queued job before invoking lc_translate; IDs should never be reused.
Metal cannot be interrupted by upstream's CPU abort callback. Cancellation and
deadlines are checked between 128-token prefill batches and generated tokens;
an in-flight GPU operation must finish before the call returns. Timings report
actual elapsed work, including an overshoot, rather than a claimed hard deadline.
lc_free cancels an active request and waits for actual native completion. Callers
must prevent all new calls when freeing a handle and must not dlclose while a
native call is still active.

Every nonzero result is incomplete and must not finalize a caption:
  0 complete; 1 cancelled; 2 deadline; 3 output/token truncation;
  -1 invalid arguments; -2 prompt budget; -3 concurrent request;
  -4 llama decode/token error; -5 unexpected native exception.
Output is NUL-terminated UTF-8, trimmed to a complete character on interruption.
Statistics report actual TTFT, total, prefill and decode milliseconds, prompt
and output tokens, EOG/completion/cancellation/truncation state. Wrapper/body
control-token counts expose the tokenization boundary for checks. No input/output
text is written by the dylib. The explicitly invoked benchmark CLI prints its
supplied test translation and real statistics as JSONL.
