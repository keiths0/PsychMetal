# Keyboard queue in PsychMetal 0.6.0

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
% Each row: [time, HIDkeyCode, pressed]; pressed=1 down, 0 up.
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

## Where the times come from

There are two sources, and `KbQueueStatus` says which is in use.

**Key events (0.6.0).** Where the application (MATLAB, Octave, or the Terminal
that runs Python) is allowed Input Monitoring in System Settings, Privacy &
Security, the queue listens to key events through a listen-only event tap on a
thread of its own, and each transition takes the time its event carries: when
the system received it, not when the queue noticed. `eventTimestamps` is then
1. The tap only listens; it logs no text and cannot alter or block a key.

**Polling.** Without the permission, the queue samples the keyboard state every
poll interval, as it did before 0.6.0, and a transition takes the time of the
scan that found it: late by up to the interval. A warning
(`PsychMetal:InputMonitoring`) says so once. The system is asked for the
permission only if `KbQueueStart` is called with no window open, since its
dialog would otherwise be hidden behind the window; after allowing it, restart
the application.

Polling keeps running beside the events as a safety net: a transition that no
event has reported within 20 ms is recorded with the scan's time. Status
fields: `eventStamped` and `pollStamped` count transitions by source, and
`maxEventDelayMs` is the longest any event took to arrive, which is roughly
what polling alone would have cost.

All times are on the clock of GetSecs and Flip. **None of this is validated.**
An event's time is when the system received it, after the keyboard's own scan
and USB or Bluetooth delay (up to 8 ms for a USB keyboard polled at 125 Hz, and
more and less regular over Bluetooth), which no software sees. The clock and
unit of the event timestamp are inferred at run time by finding the reading
that falls just before now; that inference has not been checked against a known
signal. For reaction times that matter, use a response box with its own clock
or measure this path against one. Secure Input (a password field somewhere)
suppresses keyboard state and events alike; `secureInputPID` reports it.

It is not a complete clone of Psychtoolbox's KbQueue API: there is no
deviceNumber argument, hardware HID response-box support or key-repeat stream.
With polling alone, a pulse shorter than the actual sampling interval can be
missed; `lastScanInterval`, `maxScanInterval`, scan count and overflow reveal
polling delays.

Run `PsychMetalKbQueueDemo(15)` and tap T quickly during its half-second waits.
This manually checks real keyboard transitions independently of display
capture. Escape exits. tests/test_keyboard_queue.cpp exercises the production
queue/worker with synthetic state callbacks and posted events; it does not
inject OS input, so the event tap itself is tested only by using it.

In 0.4.3, KbCheck checks Secure Input state directly without looking up the owner PID. Its warning no longer promises an owner PID. KbQueueStatus retains the explicit owner lookup; keep that diagnostic outside timing-critical loops.
