Continuous local-engine stability check

Run ./scripts/check-continuous-pipeline.sh for 1,800 seconds of uninterrupted,
real-wall-clock file input, followed by a 30-second stop/restart pass. It generates
one small synthetic English fixture with the installed macOS Samantha voice and
loops it instead of storing a 30-minute WAV. It never opens a microphone or
requests/downloads language assets. The local English ASR and both English-to-
Korean translation strategies must already be installed.

For a shorter run, first generate the fixture if needed:
  say -v Samantha -r 168 -o .build/continuous-checks/continuous-english.aiff --input-file Tests/ContinuousPipelineChecks/fixture.txt
Then invoke:
  ./scripts/check-continuous-pipeline.sh --fixture .build/continuous-checks/continuous-english.aiff --duration-seconds 60 --restart-seconds 15 --output docs/qa/raw/continuous-pipeline-short.json

The audio passes through the production foreign-queue tap factory, AudioPump,
bounded analyzer input stream, real SpeechAnalyzer/SpeechTranscriber, production
CaptionModel.receive and translation scheduler/deadlines, and real installed
TranslationSession calls. Live translation sessions are reused across successful
requests and retired after cancellation. Context leases are created/retired for
individual jobs, matching production. The app's microphone permission/start
path and SwiftUI rendering are bypassed. The second pass starts a new analyzer
while preserving source history and inserts a three-second timestamp boundary to
prevent cross-run context grouping.

The observer checks only a recent 24-row tail every 200 ms. Display and resource
samples are taken every five seconds, with bounded arrays and no full-history
state snapshots. A full raw history is audited once after each stop and exported
only at completion. Progress JSON is replaced atomically every five seconds.

Pass criteria:
- The requested continuous input duration completes without the production model
  unexpectedly stopping or reporting audio converter/dropped-buffer problems.
- Every actual final ASR source remains in the production timeline, in order.
- Every final translated raw source matches an actual completed translation call
  for the exact current revision; display final/context invariants also hold.
- Stop drains translation work, leaves no active injected engine calls, and
  restores idle plus an enabled Start action. The second input pass also completes.

Reported memory/CPU are for the test process, excluding Apple's out-of-process
language services. Lag is file-input/model-state lag, excluding hardware and UI
rendering. Gray observations and visual-final-to-gray transitions are samples,
not exhaustive UI frame counts. Exact revision matching is a state correctness
check, not a translation quality score. Long-run resource measurements do not
establish real-speaker accuracy, microphone stability, or network-disabled use.

No-argument runs save to a fresh UTC timestamp plus process-ID filename under
docs/qa/raw, preserving earlier evidence. Explicit --output paths can still be
chosen for a deliberate run. The duration/restart arguments must be finite and
frame conversions are checked before conversion to integer sample counts.

CancellationProbe.swift isolates actual installed Apple Translation calls,
without ASR/model/UI, and supports both, session_only, task_only, none, and

  deferred_session

cleanup modes. Deferred mode cancels the Swift Task first and calls SDK cancel
only after the actual native await exits. An optional fourth argument repeats
the 81-character fixture and a fifth argument sets rounds (maximum 500). Every
round includes a fresh short translation recovery check so decoder overload
from a burst of long requests does not masquerade as cancellation failure.
The older burst probe reports remain historical evidence and must be interpreted
with their different workload and overlap confounders. To compile the probe:
  xcrun swiftc -swift-version 6 -target arm64-apple-macos26.4 -parse-as-library Sources/LiveKoCaption/OperationDeadline.swift Tests/ContinuousPipelineChecks/CancellationProbe.swift -o .build/continuous-checks/CancellationProbe
Example:
  .build/continuous-checks/CancellationProbe docs/qa/raw/translation-cancel-new.json deferred_session 20 128
