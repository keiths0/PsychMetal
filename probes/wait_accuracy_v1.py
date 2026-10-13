#!/usr/bin/env python3
"""Wake-up accuracy and CPU cost of wait_secs: 0.9.0 against 0.8.1.

    cd ~/Developer/PsychMetal && python3 probes/wait_accuracy_v1.py

0.8.1 sleeps, then spins at least 4 ms. 0.9.0 sleeps as a time-constraint
(real-time) thread, then spins an adaptive margin from 0.5 ms. This measures
what that changed: how late each wait returns, and how much CPU it burns.

Each version runs in its own process, in alternating blocks, idle and then with
every core but one kept busy by other processes. Waits are 1 to 20 ms, at
random, after a short random pause, as in a trial loop. No window is opened.

Late = return time minus the deadline asked for, on the engine clock (the clock
of every PsychMetal timestamp). CPU = process CPU time during the waits divided
by their wall time: 100 % means the core spun throughout.
"""
import multiprocessing as mp
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSIONS = {'0.8.1': ROOT / 'PsychMetal-0.8.1' / 'python', '0.9.0': ROOT / 'PsychMetal-0.9.0' / 'python'}
WAITS = 300            # per block
BLOCKS = 3             # per version and condition, alternating

ONE = r'''
import json, random, sys, time
import psychmetal as pm
random.seed(int(sys.argv[1]))
late, cpu, wall = [], 0.0, 0.0
for _ in range(int(sys.argv[2])):
    time.sleep(random.uniform(0.002, 0.010))            # the rest of a trial
    duration = random.uniform(0.001, 0.020)
    deadline = pm.get_secs() + duration
    c0, w0 = time.process_time(), time.perf_counter()
    returned = pm.wait_secs('UntilTime', deadline)
    cpu += time.process_time() - c0; wall += time.perf_counter() - w0
    late.append(returned - deadline)
print(json.dumps({'version': pm.version(), 'late': late, 'cpu': cpu / wall}))
'''


def burn(stop):
    x = 0
    while not stop.is_set():
        x += 1


def block(version, seed):
    env = dict(os.environ, PYTHONPATH=str(VERSIONS[version]))
    out = subprocess.run([sys.executable, '-c', ONE, str(seed), str(WAITS)], env=env,
                         capture_output=True, text=True, cwd=str(VERSIONS[version]))
    if out.returncode:
        sys.exit(f'{version} failed:\n{out.stderr}')
    import json
    result = json.loads(out.stdout.strip().splitlines()[-1])
    if result['version'] != version:
        sys.exit(f'Asked for {version}, loaded {result["version"]}: check {VERSIONS[version]}.')
    return result


def summary(results):
    late = sorted(us * 1e6 for r in results for us in r['late'])
    n = len(late)
    q = lambda p: late[min(n - 1, int(p * n))]
    cpu = sum(r['cpu'] for r in results) / len(results)
    return (f'median {q(0.5):7.1f}  95% {q(0.95):7.1f}  99% {q(0.99):7.1f}  max {late[-1]:8.1f} µs late;'
            f'  CPU {100 * cpu:5.1f} %  (n={n})')


def main():
    for v, path in VERSIONS.items():
        if not (path / 'psychmetal').is_dir():
            sys.exit(f'No psychmetal package for {v} at {path}.')
    for condition in ('idle', 'loaded'):
        stop = mp.Event()
        burners = []
        if condition == 'loaded':
            burners = [mp.Process(target=burn, args=(stop,), daemon=True) for _ in range(max(1, os.cpu_count() - 1))]
            for b in burners:
                b.start()
        results = {v: [] for v in VERSIONS}
        try:
            for i in range(BLOCKS):
                for v in VERSIONS:
                    results[v].append(block(v, 1000 * i + 7))
        finally:
            stop.set()
            for b in burners:
                b.join()
        print(f'\n{condition}' + (f' ({len(burners)} cores busy)' if burners else ''))
        for v in VERSIONS:
            print(f'  {v}: {summary(results[v])}')


if __name__ == '__main__':
    main()
