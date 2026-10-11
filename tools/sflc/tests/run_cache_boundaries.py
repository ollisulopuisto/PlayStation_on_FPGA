#!/usr/bin/env python3
"""Compile the actual cache sources with assertions and run boundary fixtures."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/sflc'))
import sflc

for tool in ('iverilog', 'vvp'):
    if not shutil.which(tool):
        raise SystemExit('required tool missing: ' + tool)
with tempfile.TemporaryDirectory(prefix='psx-cache-boundaries-') as temp:
    build = Path(temp)
    paths = []
    for name in ('Cache_IR', 'Cache_Texture'):
        generated = sflc.translate(ROOT / (name + '.sflp'), assertions=True)
        path = build / (name + '.sv')
        path.write_text(generated)
        paths.append(str(path))
    output = build / 'tb_cache_boundaries.vvp'
    bench = ROOT / 'tools/sflc/tests/tb_cache_boundaries.sv'
    subprocess.run(['iverilog', '-g2012', '-s', 'tb_cache_boundaries', '-o', str(output), *paths, str(bench)], check=True, timeout=30)
    result = subprocess.run(['vvp', str(output)], capture_output=True, text=True, timeout=30)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        raise SystemExit(result.returncode)
    if 'PASS cache boundaries checks=11' not in result.stdout:
        raise SystemExit('boundary bench did not report all expected checks')
