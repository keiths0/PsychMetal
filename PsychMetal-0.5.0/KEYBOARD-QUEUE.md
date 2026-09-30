# Keyboard queue in PsychMetal 0.4.3

The main PsychMetalCore MEX now retains keyboard press/release transitions
while MATLAB/Octave is busy. No separate helper is needed. KbCheck is unchanged:
it still reports the current state. All keyboards are merged; HID indices and
left/right modifiers match KbCheck/KbName. No device selection is provided.

```matlab
mask = zeros(1,256);
mask(PsychMetal('KbName','T')) = 1;
PsychMetal('KbQueueCreate', mask);  % omit mask to monitor all supported keys
cleanup = onCleanup(@() PsychMetal('KbQueueRelease'));
PsychMetal('KbQueueStart');
% ...work, texture uploads, or blocking waits...
[events, dropped] = PsychMetal('KbQueueGetEvents');
% Each row: [detectionTime, HIDkeyCode, pressed]; pressed=1 down, 0 up.
pressTimes = events(events(:,2)==23 & events(:,3)==1, 1);
```

- `KbQueueCreate([mask] [,pollInterval])`: one queue per loaded MEX. A 256-entry
  logical/numeric mask selects keys. Default interval .002 seconds; allowed
  .001–.1 seconds. Recreating stops/discards the old queue.
- `KbQueueStart`: establish the current held-key baseline, clear events and
  summaries, and start the worker. A key already held is not a new press.
  Start while running is a no-op. Stop followed by Start begins a new interval.
- `KbQueueStop`: stop sampling; retain events/summaries for retrieval.
- `[events,dropped]=KbQueueGetEvents`: drain FIFO events in sampling order.
  Keys changing in the same scan share a timestamp and are ordered by HID code.
  `dropped` is cumulative overflow loss since Create, Start or Flush. Capacity
  is 4096 transitions; on overflow the oldest event is discarded.
- `[pressed,firstPress,firstRelease,lastPress,lastRelease]=KbQueueCheck`: return
  logical pressed and four 1-by-256 vectors, zero where no transition occurred.
  Clears these summary vectors only; it does not drain the FIFO. GetEvents
  does not clear the summaries. Choose whichever interface suits your program.
- `KbQueueFlush`: discard FIFO events, summaries and overflow count, without
  stopping sampling. A scan overlapping Flush is discarded and establishes the next held-key baseline.
- `KbQueueRelease`: stop and free queue state; safe to repeat. Also called by
  `PsychMetal('Close',w)` and MEX cleanup. Use an onCleanup guard for scripts
  that use a queue without a window. Queue-only use locks the MEX until release; after any graphics session the MEX remains pinned until the host exits.

This queue samples CoreGraphics on a native worker. No event tap, typed-text
logging, or additional library is introduced. It is not a complete clone of
Psychtoolbox's KbQueue API: there is no deviceNumber argument, hardware HID
response-box support, OS event timestamp, or key-repeat stream.

Timestamps are **detection times**, in the same CACurrentMediaTime clock as
PsychMetal GetSecs/Flip. Sampling usually retains taps missed by the host's
render loop, but a pulse shorter than the worker's actual sampling interval
can still be missed. Scheduling delays can increase that interval. These are
not validated reaction-time measurements. Secure Input can suppress keyboard state. KbQueueStatus exposes secureInputPID, requested interval, lastScanInterval, maxScanInterval, scan count and overflow. These reveal polling delays but cannot establish hardware event timing.

Run `PsychMetalKbQueueDemo(15)` and tap T quickly during its half-second waits.
This manually checks real keyboard transitions independently of display
capture. Escape exits. tests/test_keyboard_queue.cpp exercises the production
queue/worker with synthetic state callbacks; it does not inject OS input.

In 0.4.3, KbCheck checks Secure Input state directly without looking up the owner PID. Its warning no longer promises an owner PID. KbQueueStatus retains the explicit owner lookup; keep that diagnostic outside timing-critical loops.
