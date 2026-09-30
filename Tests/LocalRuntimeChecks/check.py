"""Explicit native ABI checks using authored text, without microphone/network."""
import argparse
import ctypes
import json
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument("--runtime", required=True)
parser.add_argument("--model", required=True)
args = parser.parse_args()
lib = ctypes.CDLL(args.runtime)
lib.lc_load.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
lib.lc_load.restype = ctypes.c_void_p
lib.lc_translate.argtypes = [ctypes.c_void_p, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_int,
                            ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
lib.lc_translate.restype = ctypes.c_int
lib.lc_cancel.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
lib.lc_free.argtypes = [ctypes.c_void_p]
error = ctypes.create_string_buffer(1024)
handle = lib.lc_load(args.model.encode(), -1, 2048, error, 1024)
assert handle, error.value.decode()
prefix = "<｜hy_begin▁of▁sentence｜><｜hy_User｜>Translate the following segment into Korean, without additional explanation:\n\n"
suffix = "<｜hy_Assistant｜>"
base = (prefix + "The meeting starts at three. Please bring the revised plan." + suffix).encode()
long_prompt = (prefix + "Before we begin please check the revised plan carefully and prepare the next discussion. " * 30 + suffix).encode()


def call(identifier, prompt=base, budget=160, timeout=30000, capacity=16384):
    output = ctypes.create_string_buffer(capacity)
    stats = ctypes.create_string_buffer(4096)
    code = lib.lc_translate(handle, identifier, prompt, budget, timeout, output, capacity, stats, 4096)
    # Decoding also verifies that interrupted/truncated outputs are valid UTF-8.
    return {"request_id": identifier, "code": code, "output": output.value.decode("utf-8"),
            "stats": json.loads(stats.value)}


rows = []
result = {}
try:
    thread = threading.Thread(target=lambda: result.setdefault("row", call(1, long_prompt, 256)))
    thread.start()
    time.sleep(.02)
    rows.append(call(100))
    lib.lc_cancel(handle, 1)
    thread.join(timeout=10)
    assert not thread.is_alive(), "Canceled native request did not return."
    rows.append(result["row"])
    assert rows[0]["code"] == -3, rows[0]  # Immediate busy rejection.
    assert result["row"]["code"] == 1, result
    lib.lc_cancel(handle, 1)  # A stale request ID cannot cancel the next request.
    rows.append(call(2))
    assert rows[-1]["code"] == 0, rows[-1]
    for row, expected in [(call(3, timeout=1), 2), (call(4, budget=1), 3),
                          (call(5, capacity=8), 3), (call(6, prompt=b"Test " * 3000), -2),
                          (call(7), 0)]:
        rows.append(row)
        assert row["code"] == expected, row
finally:
    lib.lc_free(handle)
for row in rows:
    print(json.dumps(row, ensure_ascii=False))
print(json.dumps({"event": "complete", "checks": 8, "passed": True}))
