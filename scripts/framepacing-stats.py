#!/usr/bin/env python3
"""Frame-pacing statistics for a device log (hilog capture or the shell's status mirror).

The self-drawn compositor exposes pacing through two channels, both ending up in the
device-test log:

  * host aggregates - the native host folds presents into one line every 5 s:
        [openharmony-host] canvas presented (2090x1324) n=301 avg=16ms max=23ms
    (the first present / a size change still logs the bare "canvas presented (WxH)").
  * the opt-in managed probe (`-p:FramepacingProbe=true`, test/hello-maui-app/
    FramePacingProbe.cs) - one FPF line per platform frame callback and one FPP line per
    present, carrying the callback-to-callback gap (us) and the callback-to-present
    latency (ms).
  * the opt-in phase probe (`-p:FramePhaseProbe=true`, test/hello-maui-app/
    FramePhaseProbe.cs) - one aggregated FPH line per ~5 s breaking a rendered frame into
    pre/measure+arrange/surface/draw/chrome/a11y/present/wait averages (and window maxes).

The script accepts any mix, dedupes the lines the shell's 3-second tail poll repeats, and
reports fps plus the gap/latency distribution. With --min-fps/--max-gap-ms it exits 1 when
the measured pacing is out of budget, so it can gate a device run:

    python3 scripts/framepacing-stats.py capture.txt --min-fps 55 --max-gap-ms 34

DO NOT count "canvas presented" lines for fps: the shell poll re-logs the status file's
60-line tail, which made a 60 fps compositor read as 17.7 fps (2026-10-03 investigation,
docs/plans/2026-10-03-ohos-framepacing.md).
"""
import re
import sys

HOST_LINE = re.compile(r'canvas presented \((\d+)x(\d+)\)(?: n=(\d+) avg=(\d+)ms max=(\d+)ms)?')
FPF = re.compile(r'FPF t=(\d+) ts=(\d+) gap=(\d+) tgt=(\d+) idle=(\d+) n=(\d+) p=(\d+)')
FPP = re.compile(r'FPP t=(\d+) lat=(\d+) p=(\d+)')
FPH = re.compile(
    r'FPH n=(\d+) inc=(\d+) fps=([\d.]+)'
    r' pre=([\d.]+)/([\d.]+) meas=([\d.]+)/([\d.]+) surf=([\d.]+)/([\d.]+)'
    r' draw=([\d.]+)/([\d.]+) chr=([\d.]+)/([\d.]+) a11y=([\d.]+)/([\d.]+)'
    r' pres=([\d.]+)/([\d.]+) wait=([\d.]+)/([\d.]+)')
PHASES = ['pre', 'meas', 'surf', 'draw', 'chr', 'a11y', 'pres', 'wait']


def percentile(values, q):
    if not values:
        return 0
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(q * (len(ordered) - 1) + 0.5))
    return ordered[index]


def histogram(values, edges, names):
    counts = [0] * len(names)
    for value in values:
        for index, edge in enumerate(edges):
            if value <= edge:
                counts[index] += 1
                break
        else:
            counts[-1] += 1
    return {name: count for name, count in zip(names, counts) if count}


def parse(path):
    host = []       # (width, height, n, avg_ms, max_ms) windows with n
    first = []      # bare first-frame / size-change lines
    frames = []     # FPF dicts, deduped by timestamp
    presents = []   # FPP dicts
    phases = []     # FPH dicts (n, inc, fps, per-phase (avg, max))
    seen = set()
    for raw in open(path, encoding='utf-8', errors='replace'):
        m = FPH.search(raw)
        if m:
            line = m.group(0)
            if line in seen:
                continue
            seen.add(line)
            g = m.groups()
            phases.append(dict(
                n=int(g[0]), inc=int(g[1]), fps=float(g[2]),
                vals={p: (float(g[3 + 2 * i]), float(g[4 + 2 * i])) for i, p in enumerate(PHASES)}))
            continue
        m = FPF.search(raw)
        if m:
            line = m.group(0)
            if line in seen:
                continue
            seen.add(line)
            t, ts, gap, tgt, idle, n, p = map(int, m.groups())
            frames.append(dict(t=t, ts=ts, gap=gap, tgt=tgt, idle=idle, n=n, p=p))
            continue
        m = FPP.search(raw)
        if m:
            line = m.group(0)
            if line in seen:
                continue
            seen.add(line)
            t, lat, p = map(int, m.groups())
            presents.append(dict(t=t, lat=lat, p=p))
            continue
        m = HOST_LINE.search(raw)
        if m:
            line = m.group(0)
            if line in seen:
                continue
            seen.add(line)
            width, height, n, avg, mx = m.groups()
            if n is None:
                first.append((int(width), int(height)))
            else:
                host.append((int(width), int(height), int(n), int(avg), int(mx)))
    frames.sort(key=lambda f: f['ts'])
    return host, first, frames, presents, phases


def report(path, min_fps, max_gap_ms):
    host, first, frames, presents, phases = parse(path)
    ok = True
    print(f"== {path}")
    if host:
        for width, height, n, avg, mx in host:
            # The host emits one line per ~5 s window; n is that window's present count.
            fps = n / 5.0
            print(f"host window {width}x{height}: n={n} avg={avg}ms max={mx}ms -> {fps:.1f} fps")
            if fps < min_fps:
                print(f"  FAIL: {fps:.1f} fps < {min_fps}")
                ok = False
            if mx > max_gap_ms:
                print(f"  FAIL: max gap {mx}ms > {max_gap_ms}ms")
                ok = False
    if frames:
        span_s = (frames[-1]['ts'] - frames[0]['ts']) / 1e9
        frame_count = frames[-1]['n'] - frames[0]['n']
        present_count = frames[-1]['p'] - frames[0]['p']
        fps = frame_count / span_s if span_s > 0 else 0.0
        gaps = [f['gap'] for f in frames]
        lats = [p['lat'] for p in presents]
        print(f"probe: span={span_s:.2f}s frames={frame_count} presents={present_count} -> {fps:.2f} fps")
        print(f"gap us: p50={percentile(gaps, .5)} p95={percentile(gaps, .95)} "
              f"p99={percentile(gaps, .99)} max={max(gaps)}")
        print(f"lat ms: p50={percentile(lats, .5)} p95={percentile(lats, .95)} "
              f"p99={percentile(lats, .99)} max={max(lats) if lats else 0}")
        print("gap ms histogram:", histogram(gaps,
              [10_000, 15_000, 16_600, 16_700, 17_500, 20_000, 25_000, 33_000, 50_000, 100_000],
              ['<=10', '10-15', '15-16.6', '16.6-16.7', '16.7-17.5', '17.5-20',
               '20-25', '25-33', '33-50', '50-100', '>100']))
        if fps < min_fps:
            print(f"  FAIL: {fps:.2f} fps < {min_fps}")
            ok = False
        if max(gaps) / 1000.0 > max_gap_ms:
            print(f"  FAIL: max gap {max(gaps) / 1000.0:.1f}ms > {max_gap_ms}ms")
            ok = False
    if phases:
        window_frames = sum(p['n'] for p in phases)
        fps = sum(p['fps'] * p['n'] for p in phases) / window_frames if window_frames else 0.0
        print(f"phase probe: windows={len(phases)} frames={window_frames} -> {fps:.2f} fps"
              f" incomplete={sum(p['inc'] for p in phases)}")
        for phase in PHASES:
            avg = sum(p['vals'][phase][0] * p['n'] for p in phases) / window_frames if window_frames else 0.0
            mx = max(p['vals'][phase][1] for p in phases)
            print(f"  {phase:>5}: avg={avg:.1f}ms max={mx:.1f}ms")
        if fps < min_fps:
            print(f"  FAIL: {fps:.2f} fps < {min_fps}")
            ok = False
    if not host and not frames and not phases:
        print("no frame-pacing lines found (host aggregate, FPF/FPP or FPH)")
        ok = False
    return ok


def main(argv):
    min_fps = 0.0
    max_gap_ms = float('inf')
    paths = []
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == '--min-fps':
            i += 1
            min_fps = float(argv[i])
        elif arg == '--max-gap-ms':
            i += 1
            max_gap_ms = float(argv[i])
        else:
            paths.append(arg)
        i += 1
    if not paths:
        print(__doc__)
        return 2
    ok = True
    for path in paths:
        ok = report(path, min_fps, max_gap_ms) and ok
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
