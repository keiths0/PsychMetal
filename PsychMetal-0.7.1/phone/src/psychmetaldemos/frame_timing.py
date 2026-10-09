"""Three timing conditions, followed by an in-app HTML/SVG report. No files.

Uses confirmed drawable timestamps, never Flip's projected timestamp. This
first diagnostic does not capture CADisplayLink callbacks or measure photons.
"""
import gc
import time
import html
import math
import sys

import numpy as np
import psychmetal as pm
from blob_array_demo import Drag, frequencies, layout, frame_periods, waveform_samples, measure_interval


CONDITIONS = ('Alternating patch — do not touch', 'Blob array — do not touch',
              'Blob array — drag a blob')


class GCMonitor:
    """Bounded collection timestamps; restores callbacks even if the demo fails."""
    def __init__(self):
        self.rows=np.empty((2048,3))
        self.count=self.lost=0
        self.callback=self.record

    def record(self, phase, info):
        if self.count<len(self.rows):
            self.rows[self.count]=(time.perf_counter(), phase=='stop', info['generation'])
            self.count+=1
        else:
            self.lost+=1

    def __enter__(self):
        gc.callbacks.append(self.callback)
        return self

    def __exit__(self, *exception):
        gc.callbacks.remove(self.callback)

    def spans(self):
        result=[]
        active={}
        for timestamp,stop,generation in self.rows[:self.count]:
            if not stop:
                active[generation]=timestamp
            elif generation in active:
                result.append((active.pop(generation),timestamp,int(generation)))
        return result


def summarize(name, ifi, diagnostic, samples, warmup, touches=0, lost=0, cpu_windows=None, gc_spans=(), gc_lost=0):
    """Align history to submitted frames; exclude warm-up and unconfirmed pairs."""
    submitted = len(samples)
    status = np.asarray(diagnostic['actualStatus'])
    count = len(status)
    if count > submitted:
        raise ValueError('Unexpected diagnostic history: more records than submitted frames.')
    # Engine history can be a retained suffix of the session. Never silently
    # pair it with the beginning of the CPU samples.
    start = submitted - count
    index = np.arange(start, submitted)
    keep = index >= warmup
    index = index[keep]
    status = status[keep]
    times = np.asarray(diagnostic['actualTimestamp'])[keep]
    tokens = np.asarray(diagnostic['flipNumber'])[keep]
    good = (status == 0) & np.isfinite(times) & (times > 0)
    intervals = np.full(len(index), np.nan)
    pairs = good[1:] & good[:-1] & (np.diff(tokens) == 1) & (np.diff(times) > 0)
    intervals[1:][pairs] = np.diff(times)[pairs] * 1000
    valid = intervals[np.isfinite(intervals)]
    nominal = ifi * 1000
    long = np.flatnonzero(intervals > 1.5 * nominal)
    spacing = np.diff(times[long])
    shown = times[good]
    rate = (len(shown)-1)/(shown[-1]-shown[0]) if len(shown)>1 and shown[-1]>shown[0] else math.nan

    def metric(values):
        a = np.asarray(values, dtype=float)
        a = a[np.isfinite(a)]
        return dict(median=float(np.median(a)), p99=float(np.percentile(a,99)), maximum=float(a.max())) if len(a) else dict(median=math.nan,p99=math.nan,maximum=math.nan)

    stage = {}
    for label,key in [('Drawable wait','drawableWaitMs'),('GPU encoding','encodeMs'),('GPU execution','gpuPassMs')]:
        values = np.asarray(diagnostic.get(key, np.full(count,np.nan)))[keep]
        stage[label] = metric(values)
    cpu = np.asarray(samples, dtype=float).reshape(-1, 3)[index]
    for j,label in enumerate(('Input polling','Drawing calls','Flip call')):
        stage[label] = metric(cpu[:,j])
    # Associate each long adjacent interval with CURRENT and PREVIOUS work.
    # A matching collection is a correlation, not a diagnosis of causality.
    events=[]
    origin=shown[0] if len(shown) else math.nan
    def value(key,j):
        return float(np.asarray(diagnostic.get(key,np.full(count,np.nan)))[keep][j])
    windows=np.asarray(cpu_windows) if cpu_windows is not None else None
    for j in long:
        elapsed=float(times[j]-origin)
        collections=[]
        if windows is not None:
            lo=windows[index[j-1],0]; hi=windows[index[j],1]
            collections=[dict(generation=g,ms=1000*(b-a)) for a,b,g in gc_spans if a<=hi and b>=lo]
        events.append(dict(frame=int(index[j]-warmup+1), elapsed=elapsed,
            phase_ms=1000*(elapsed-round(elapsed)), interval_ms=float(intervals[j]),
            work_ms=[float(cpu[q,0]+cpu[q,1]) for q in (j-1,j)],
            flip_ms=[float(cpu[q,2]) for q in (j-1,j)],
            encode_ms=[value('encodeMs',q) for q in (j-1,j)],
            gpu_ms=[value('gpuPassMs',q) for q in (j-1,j)], collections=collections))
    return dict(events=events, gc_count=len(gc_spans), gc_lost=gc_lost,
                name=name, nominal_ms=nominal, submitted=max(0,submitted-warmup),
                retained=len(index), confirmed=int(good.sum()), unconfirmed=int((~good).sum()),
                dropped=int((status==1).sum()), warmup=min(warmup,submitted),
                frames=index-warmup+1, intervals=intervals, interval_stats=metric(valid),
                long_count=len(long), short_count=int(np.sum(intervals<.5*nominal)), rate=rate,
                spacing=metric(spacing), stages=stage, touches=touches, lost=lost,
                missing=max(0,submitted-warmup)-len(index))


def number(value, digits=2):
    return f'{value:.{digits}f}' if math.isfinite(value) else 'n/a'


def interval_graph(r):
    """Inline SVG: every valid interval, breaks at unknown timestamps, no files."""
    xvals, values = r['frames'], r['intervals']
    finite = values[np.isfinite(values)]
    ymax = max(r['nominal_ms']*2.25, float(finite.max())*1.1 if len(finite) else 0)
    xmax = max(1, r['submitted'])
    left, top, width, height = 48, 20, 334, 180
    xy = lambda x,y: (left + (x-1)/max(1,xmax-1)*width, top+height-y/ymax*height)
    out = ['<svg viewBox="0 0 400 245" role="img" aria-label="Presentation interval by submitted frame">',
           '<rect width="400" height="245" fill="white"/>']
    for y in sorted(set([0, r['nominal_ms'], 2*r['nominal_ms'], ymax])):
        _, py = xy(1,y)
        out.append(f'<path d="M48 {py:.2f}H382" stroke="#ddd"/><text x="43" y="{py+4:.2f}" text-anchor="end">{y:.1f}</text>')
    _, py = xy(1,r['nominal_ms'])
    out.append(f'<path d="M48 {py:.2f}H382" stroke="#27854c" stroke-dasharray="5 4"/>')
    segment = []
    def flush():
        if segment:
            out.append('<polyline fill="none" stroke="#2064ac" stroke-width="1.3" points="'+' '.join(segment)+'"/>')
            segment.clear()
    for x,y in zip(xvals,values):
        if not math.isfinite(y):
            flush()
            continue
        px,py=xy(x,y)
        segment.append(f'{px:.2f},{py:.2f}')
        if y>1.5*r['nominal_ms'] or y<.5*r['nominal_ms']:
            out.append(f'<circle cx="{px:.2f}" cy="{py:.2f}" r="2.5" fill="#bc302d"/>')
    flush()
    out.extend([f'<text x="48" y="219">1</text><text x="382" y="219" text-anchor="end">{xmax}</text>',
                '<text x="215" y="239" text-anchor="middle">Frame after warm-up</text>',
                '<text x="6" y="13">ms</text></svg>'])
    return ''.join(out)


def render_report(results, stopped=False):
    out = ['<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">',
           '<style>body{font:16px -apple-system,sans-serif;color:#172532;background:#f5f7fa;margin:16px}h1{font-size:25px}h2{font-size:20px}section{background:white;border-radius:12px;padding:14px;margin:18px 0}svg{width:100%;height:auto}svg text{font:16px sans-serif;fill:#444}table{width:100%;font-size:13px;border-collapse:collapse}td,th{padding:6px 3px;text-align:right;border-bottom:1px solid #ddd}td:first-child,th:first-child{text-align:left}p{line-height:1.45}.note{color:#52616e;font-size:14px}</style></head><body>',
           '<h1>Frame timing report</h1>',
           '<p>Stopped early; results below are partial.</p>' if stopped else '<p>Timing check completed.</p>',
           '<p>Blue: actual intervals. Green dashed line: nominal refresh interval. Red dots: intervals above 1.5× or below 0.5× nominal. Gaps in the line mean an interval could not be established.</p>']
    if not results:
        out.append('<p>No frames were collected.</p>')
    for r in results:
        s=r['interval_stats']
        out.extend(['<section><h2>'+html.escape(r['name'])+'</h2>',
                    f"<p>Nominal {number(1000/r['nominal_ms'])} Hz ({number(r['nominal_ms'])} ms). Confirmed delivery: {number(r['rate'])} frames/s.</p>",
                    f"<p>{r['confirmed']} confirmed; {r['unconfirmed']} unconfirmed (including {r['dropped']} reported without a presentation timestamp). {r['warmup']} warm-up frames excluded; {r['missing']} measured records missing from history.</p>",
                    f"<p><b>{r['long_count']} long intervals</b>; {r['short_count']} unusually short intervals.<br>Median {number(s['median'])} ms · 99th percentile {number(s['p99'])} ms · maximum {number(s['maximum'])} ms.</p>",
                    interval_graph(r)])
        if r['long_count']>=3:
            out.append(f"<p>Spacing between long intervals: median {number(r['spacing']['median'])} s; maximum {number(r['spacing']['maximum'])} s. This alone does not establish periodicity.</p>")
        else:
            out.append('<p>Too few long intervals to assess recurrence.</p>')
        out.append('<table><tr><th>Work / wait (ms)</th><th>Median</th><th>99th %</th><th>Max</th></tr>')
        for label, stats in r['stages'].items():
            out.append('<tr><td>'+label+'</td>'+''.join('<td>'+number(stats[k])+'</td>' for k in ('median','p99','maximum'))+'</tr>')
        out.append('</table><h3>Each long interval</h3>')
        out.append('<p class=note>Elapsed time starts at the first confirmed measured frame. Phase is the signed distance from its nearest whole second. Timing pairs show previous / current frame; work includes input and drawing. A GC match means collection overlapped either CPU frame, not that it caused the delay.</p>')
        if r.get('events'):
            out.append('<div style="overflow-x:auto"><table><tr><th>Elapsed s</th><th>Phase ms</th><th>Interval ms</th><th>Work ms</th><th>Flip ms</th><th>Encode ms</th><th>GPU ms</th><th>GC</th></tr>')
            for event in r['events']:
                pair=lambda key: ' / '.join(number(v) for v in event[key])
                collections=', '.join(f"gen {g['generation']}: {number(g['ms'])} ms" for g in event['collections']) or 'none'
                cells=[number(event['elapsed'],3),number(event['phase_ms']),number(event['interval_ms']),
                       pair('work_ms'),pair('flip_ms'),pair('encode_ms'),pair('gpu_ms'),collections]
                out.append('<tr>'+''.join('<td>'+html.escape(cell)+'</td>' for cell in cells)+'</tr>')
            out.append('</table></div>')
        else:
            out.append('<p>No confirmed long intervals.</p>')
        out.append(f"<p class=note>Observed Python collections: {r.get('gc_count',0)}; GC records lost: {r.get('gc_lost',0)}. Collection logging and CPU timestamp measurements add some overhead.</p>")
        out.append(f"<p class=note>Touch events (phone) / held-button samples (Mac): {r['touches']}; touch events lost: {r['lost']}. CPU timings include this diagnostic's polling and drawing calls; GPU encoding is part of Flip, not an additional independent cost.</p></section>")
    out.append('<h2>How to read this</h2><p>If the patch is smooth but the array is not, investigate the extra drawing work. If dragging makes it worse, investigate input handling. Irregularities in all three conditions point toward shared presentation pacing or system conditions.</p><p class=note>Long intervals are not automatically dropped frames. These are Metal presentation timestamps, not measured light output. Intervals use only adjacent submitted frames with confirmed, increasing timestamps; unknown frames are not bridged. The displayed delivery rate counts confirmed frames over their elapsed span. This diagnostic does not log display-link callbacks, so it cannot prove whether ProMotion changed cadence. Results stay in memory; take a screenshot before leaving the app if you want to keep them.</p></body></html>')
    return ''.join(out)


def timing_layout(width, height, count, summary):
    """Convert UIKit safe-area points to drawable pixels, leaving text margins."""
    scale = float(summary.get('backingScaleFactor', 1))
    if not math.isfinite(scale) or scale <= 0:
        scale = 1
    insets = np.asarray(summary.get('screenSafeAreaInsets', [0,0,0,0]), dtype=float)
    if insets.shape != (4,) or not np.all(np.isfinite(insets)) or np.any(insets < 0):
        insets = np.zeros(4)
    top,left,bottom,right = insets*scale
    margin = 16*scale
    safe = [left+margin, top+margin, width-right-margin, height-bottom-margin]
    if safe[2] <= safe[0] or safe[3] <= safe[1]:
        raise ValueError('The display safe area is too small for the timing test.')
    title_size = min(18*scale, (safe[2]-safe[0])/24)
    header = 3*title_size
    centers,half,size = layout(safe[2]-safe[0], safe[3]-safe[1]-header, count)
    centers += [safe[0],safe[1]+header]
    return centers,half,size,safe,title_size


def frame_timing(seconds=12, presentation="auto", condition_indices=(0,1,2)):
    """About 40 s: patch, stationary array, then finger/mouse-dragged array."""
    if not math.isfinite(seconds) or not 0 < seconds <= 30:
        raise ValueError('seconds must be in (0, 30].')
    results=[]
    stopped=False
    for position,condition in enumerate(condition_indices):
        with pm.open_window(None, presentation=presentation) as (w,rect,ifi):
            ifi=measure_interval(w,ifi)
            tables=waveform_samples(frame_periods(ifi))
            hz=frequencies(ifi)
            # Query once before warm-up; never drain diagnostics in a measured frame.
            geometry = pm.diagnostic(w)['summary']
            name=geometry['presentation'] + ': ' + CONDITIONS[condition]
            centers,half,size,safe,title_size = timing_layout(rect[2],rect[3],len(hz),geometry)
            drag=Drag(centers,half)
            labels=[f'{f:.2f} Hz' for f in hz]
            widths=[pm.text_bounds(w,label,size)[0][2] for label in labels]
            title=f'{position+1}/{len(condition_indices)}: '+name
            # Prewarm static text before timing; render one warm-up second too.
            title_width = pm.text_bounds(w,title,title_size)[0][2]
            if title_width > safe[2]-safe[0]:
                title_size *= (safe[2]-safe[0])/title_width
                title_width = pm.text_bounds(w,title,title_size)[0][2]
            title_x = safe[0]+(safe[2]-safe[0]-title_width)/2
            warmup=max(1,round(1/ifi))
            total=min(15000,warmup+max(1,round(seconds/ifi)))
            samples=np.empty((total,3))
            cpu_windows=np.empty((total,2))
            sample_count=0
            touches=lost=0
            held=False
            escape=pm.kb_name('ESCAPE')
            with GCMonitor() as gc_monitor:
                for k in range(total):
                    cpu_windows[sample_count,0]=time.perf_counter()
                    began=pm.get_secs()
                    if pm.kb_check()[2][escape]:
                        stopped=True
                        break
                    measured=k>=warmup
                    if condition==2:
                        if sys.platform=='ios':
                            events,dropped=pm.touch_events(w)
                            if measured:
                                touches+=len(events); lost+=dropped
                            if dropped: drag.up(drag.pointer)
                            for _,finger,phase,x,y in events:
                                if phase==0: drag.down(finger,x,y)
                                elif phase==1: drag.move(finger,x,y)
                                elif phase in (2,3):
                                    if phase==2: drag.move(finger,x,y)
                                    drag.up(finger)
                        else:
                            x,y,b=pm.get_mouse(w); pressed=bool(b[0])
                            if pressed and not held: drag.down(0,x,y)
                            if pressed or held: drag.move(0,x,y)
                            if not pressed: drag.up(0)
                            if measured: touches+=int(pressed)
                            held=pressed
                    polled=pm.get_secs()
                    pm.fill_rect(w,127.5)
                    if condition==0:
                        cx,cy=rect[2]/2,rect[3]/2
                        pm.fill_rect(w,255 if k%2==0 else 0,[cx-half,cy-half,cx+half,cy+half])
                    else:
                        amplitudes=.5*np.array([table[k % len(table)] for table in tables])
                        for i in drag.order:
                            x,y=centers[i]; s=amplitudes[i]; value=255 if s>=0 else 0
                            pm.draw_gabor(w,[value,value,value,510*abs(s)],[x-half,y-half,x+half,y+half],.30)
                            pm.draw_text(w,labels[i],
                                         min(max(x-widths[i]/2,safe[0]),safe[2]-widths[i]),
                                         min(max(y+half,safe[1]+3*title_size),safe[3]-2*size),0,size)
                    pm.draw_text(w,title,title_x,safe[1],0,title_size)
                    drawn=pm.get_secs()
                    pm.flip(w)
                    samples[sample_count]=((polled-began)*1000,(drawn-polled)*1000,(pm.get_secs()-drawn)*1000)
                    cpu_windows[sample_count,1]=time.perf_counter()
                    sample_count+=1
            samples=samples[:sample_count]
            cpu_windows=cpu_windows[:sample_count]
            d=pm.diagnostic(w)
            # Calibration precedes the samples; retain only this test's suffix.
            for key in ('actualStatus','actualTimestamp','flipNumber','drawableWaitMs','encodeMs','gpuPassMs'):
                d[key]=np.asarray(d[key])[-len(samples):] if len(samples) else np.asarray(d[key])[:0]
            results.append(summarize(name,ifi,d,samples,warmup,touches,lost,cpu_windows,gc_monitor.spans(),gc_monitor.lost))
        if stopped: break
    for r in results:
        print(f"{r['name']}: {r['confirmed']} confirmed, {r['unconfirmed']} unconfirmed; "
              f"{number(r['rate'])} frames/s; {r['long_count']} long intervals; "
              f"maximum {number(r['interval_stats']['maximum'])} ms.")
        for event in r['events']:
            gc_text=', '.join(f"gen {g['generation']} {g['ms']:.3f} ms" for g in event['collections']) or 'none'
            print(f"  Long interval at {event['elapsed']:.3f} s; phase {event['phase_ms']:+.2f} ms; "
                  f"previous/current work {event['work_ms']}; GPU {event['gpu_ms']}; GC {gc_text}")
    return dict(report_html=render_report(results,stopped),conditions=results,stopped=stopped)
