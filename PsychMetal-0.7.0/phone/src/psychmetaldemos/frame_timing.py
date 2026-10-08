"""Three timing conditions, followed by an in-app HTML/SVG report. No files.

Uses confirmed drawable timestamps, never Flip's projected timestamp. This
first diagnostic does not capture CADisplayLink callbacks or measure photons.
"""
import html
import math
import sys

import numpy as np
import psychmetal as pm
from blob_array_demo import Drag, frequencies, layout


CONDITIONS = ('Alternating patch — do not touch', 'Blob array — do not touch',
              'Blob array — drag a blob')


def summarize(name, ifi, diagnostic, samples, warmup, touches=0, lost=0):
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
    return dict(name=name, nominal_ms=nominal, submitted=max(0,submitted-warmup),
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
           '<p>Stopped early; results below are partial.</p>' if stopped else '<p>Three-condition timing check completed.</p>',
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
        out.append(f"</table><p class=note>Touch events (phone) / held-button samples (Mac): {r['touches']}; touch events lost: {r['lost']}. CPU timings include this diagnostic's polling and drawing calls; GPU encoding is part of Flip, not an additional independent cost.</p></section>")
    out.append('<h2>How to read this</h2><p>If the patch is smooth but the array is not, investigate the extra drawing work. If dragging makes it worse, investigate input handling. Irregularities in all three conditions point toward shared presentation pacing or system conditions.</p><p class=note>Long intervals are not automatically dropped frames. These are Metal presentation timestamps, not measured light output. Intervals use only adjacent submitted frames with confirmed, increasing timestamps; unknown frames are not bridged. The displayed delivery rate counts confirmed frames over their elapsed span. This diagnostic does not log display-link callbacks, so it cannot prove whether ProMotion changed cadence. Results stay in memory; take a screenshot before leaving the app if you want to keep them.</p></body></html>')
    return ''.join(out)


def frame_timing(seconds=12):
    """About 40 s: patch, stationary array, then finger/mouse-dragged array."""
    if not math.isfinite(seconds) or not 0 < seconds <= 30:
        raise ValueError('seconds must be in (0, 30].')
    results=[]
    stopped=False
    for condition,name in enumerate(CONDITIONS):
        with pm.open_window(None) as (w,rect,ifi):
            hz=frequencies(ifi)
            centers,half,size=layout(rect[2],rect[3],len(hz))
            drag=Drag(centers,half)
            labels=[f'{f:.3g} Hz' for f in hz]
            widths=[pm.text_bounds(w,label,size)[0][2] for label in labels]
            title=f'{condition+1}/3: '+name
            title_size=max(12,min(rect[2]*.035,rect[3]*.025))
            # Prewarm static text before timing; render one warm-up second too.
            pm.text_bounds(w,title,title_size)
            warmup=max(1,round(1/ifi))
            total=min(15000,warmup+max(1,round(seconds/ifi)))
            samples=[]
            touches=lost=0
            held=False
            escape=pm.kb_name('ESCAPE')
            for k in range(total):
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
                    amplitudes=.5*np.cos(2*np.pi*hz*k*ifi)
                    for i in drag.order:
                        x,y=centers[i]; s=amplitudes[i]; value=255 if s>=0 else 0
                        pm.draw_gabor(w,[value,value,value,510*abs(s)],[x-half,y-half,x+half,y+half],.30)
                        pm.draw_text(w,labels[i],x-widths[i]/2,y+half,0,size)
                pm.draw_text(w,title,None,rect[3]*.015,0,title_size)
                drawn=pm.get_secs()
                pm.flip(w)
                samples.append(((polled-began)*1000,(drawn-polled)*1000,(pm.get_secs()-drawn)*1000))
            d=pm.diagnostic(w)
            results.append(summarize(name,ifi,d,samples,warmup,touches,lost))
        if stopped: break
    for r in results:
        print(f"{r['name']}: {r['confirmed']} confirmed, {r['unconfirmed']} unconfirmed; "
              f"{number(r['rate'])} frames/s; {r['long_count']} long intervals; "
              f"maximum {number(r['interval_stats']['maximum'])} ms.")
    return dict(report_html=render_report(results,stopped),conditions=results,stopped=stopped)
