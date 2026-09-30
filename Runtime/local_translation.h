#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// All paths and text are UTF-8. A handle owns exactly one inference context.
// Translate calls are serialized by the caller; simultaneous calls return -3.
// Request IDs must be nonzero and unique while a handle is alive.
void * lc_load(const char * modelPath, int gpuLayers, int contextSize,
               char * error, int errorCapacity);
// 0 complete, 1 cancelled, 2 timed out, 3 truncated; negative values are errors.
// A nonzero result must never be published as a completed translation.
int lc_translate(void * handle, uint64_t requestID, const char * prompt,
                 int maxTokens, int timeoutMs, char * output, int outputCapacity,
                 char * statsJSON, int statsCapacity);
// Cancels only this currently active request, never a later request.
void lc_cancel(void * handle, uint64_t requestID);
// Cancels and waits for active native computation before releasing the handle.
// The caller must prevent new translate/cancel calls once freeing begins.
void lc_free(void * handle);
const char * lc_version(void);

#ifdef __cplusplus
}
#endif
