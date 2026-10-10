# GetImage in 0.7.2 (development)

`GetImage` still returns the latest submitted frame as RGB: uint8 for an 8-bit
window, uint16 in 0–1023 for a 10-bit window. Open with readback enabled.
The optional crop is in whole window pixels. Pending/unflipped drawing is
not included. Calls wait for GPU rendering, not physical light emission.

Changes:

- The render command buffer blits the final pixels directly into a reusable,
  shared Metal buffer with 256-byte-aligned rows. Previously it copied into a
  texture and GetImage then copied that texture into a CPU scratch vector.
- RGB conversion reads that buffer directly, with a pointer offset for crops.
  ARM SIMD handles the interleaved Python layout. Tiled traversal improves
  locality for MATLAB/Octave's column-major RGB planes.
- Python can reuse an output allocation:

```python
with pm.open_window(readback=True) as (w, rect, ifi):
    pm.fill_rect(w, 128)
    pm.flip(w)
    image = pm.get_image(w)  # allocate once
    # After each subsequent Flip:
    pm.get_image(w, out=image)  # fills and returns this same array
```

For a crop, allocate the matching H×W×3 shape and pass the same rect every
call. `out` must be writable, C-contiguous and native uint8 (8-bit window) or
uint16 (10-bit window). It is never implicitly copied. Do not access it from
another thread during the call. Without `out`, each result owns independent
storage and remains valid after subsequent flips or window closure.

A readback-enabled session still copies every full frame on the GPU, even
when the CPU requests only a crop. It still waits for the latest rendering
before returning data. It is not an asynchronous frame-history API, and no
120 Hz capture guarantee is claimed. The blob inspector now keeps a bounded CPU ring of synchronous captures
and provides pause-and-step inspection. It is not an asynchronous GPU ring;
see `phone/FRAME-TIMING.md` for the controls and timing limitations.

Validation: `tests/test_readback_unpack.py` tests exact pixels, SIMD tails,
crops/padding, Python/MATLAB/reversed/gapped layouts, 8/10-bit channels, and
untouched guard bytes with address/undefined-behavior sanitizers; it also tests
the portable fallback. `--benchmark` compares conversion loops only. The
front-end suite checks reusable output identity and rejects wrong shapes,
dtypes, byte order, read-only and noncontiguous buffers. `test_readback_buffer.mm`
checks the actual GPU texture-to-buffer copy when a Metal device is available.

Benchmarks on the development Mac (CPU conversion only, example run):

| Image | Output layout | Previous loop | New loop |
|---|---|---:|---:|
| 1206×2622 | Python RGB | 3.16 ms | 0.39 ms |
| 1206×2622 | MATLAB planes | 8.01 ms | 2.91 ms |
| 6016×3384 | Python RGB | 17.48 ms | 2.43 ms |
| 6016×3384 | MATLAB planes | 55.80 ms | 31.57 ms |

These exclude the GPU copy/wait, host output allocation and Python/MATLAB
call overhead. They are not iPhone measurements. GPU pixel validation and
end-to-end capture timing still need to run on hardware.
