# Project instructions

- The user prefers feature-based commits and separate pushes for each feature. Keep each commit buildable and push each completed feature separately unless the user requests a different workflow. The configured remote is the user-provided `https://github.com/SeoJHeasdw/live-ko-catption`.

- This is an independent, native macOS app for one English speaker and Korean captions. Keep it isolated from the sibling asset, music, and TTS engines. Do not import their configuration, dependencies, model servers, or launch scripts.
- Preserve fully local inference after Apple's initial language downloads. Do not add cloud services or system-audio capture unless requested.
- Keep audio callbacks small. Recognition and translation must not run on the audio callback. Bound audio queues and report dropped input honestly.
- Construct AVFoundation's foreign-thread callbacks in a nonisolated factory. Do not create an `AVAudioNodeTapBlock` inside a MainActor method: Swift 6 can infer MainActor isolation and trap at the first real microphone buffer. Use `AudioPump.makeTapBlock()` and `AudioCallbackBridge` and run `./scripts/check-audio-callbacks.sh` after audio changes.
- Provisional Korean captions remain gray and editable. A caption becomes final only when its ASR source is final and the exact current source revision has been translated. Reject stale translation results.
- Keep finalized text stable. Do not translate the complete session history for every partial update. Coalesce partial work and prioritize final results.
- Build with `./scripts/build-app.sh`. Run `swift run --build-system native CaptionCoreChecks` when modifying caption state or translation scheduling.
- UI preview data must be clearly labeled and must not contain invented performance measurements. Build success and state checks do not prove live microphone accuracy or latency.
- Before adding SDK APIs, check their actual minimum OS version; the current SDK is newer than the supported macOS 26.4 deployment target.
