#!/usr/bin/env python3
"""Copia nell'app tutte le librerie dinamiche non di sistema usate dall'eseguibile.

Usa le funzioni di TOOLS/dylib_unhell.py di mpv (le stesse del bundle ufficiale
di mpv per macOS): le librerie finiscono in Contents/MacOS/lib e i riferimenti
vengono riscritti in @executable_path/lib/...

Uso: bundle_dylibs.py <cartella TOOLS di mpv> <eseguibile> [dylib caricate a runtime...]
"""
import os
import subprocess
import sys

tools_dir, binary, *runtime_libs = sys.argv[1:]
sys.path.insert(0, tools_dir)
import dylib_unhell as d  # noqa: E402

binary = os.path.abspath(binary)
os.makedirs(d.lib_path(binary), exist_ok=True)

print(">> librerie collegate all'eseguibile")
libs, libs_rel = d.libraries(binary)
d.process_libraries(libs, libs_rel, binary)
d.remove_dev_tools_rapths(binary)

# Le dylib del motore (liborender, bridge) sono caricate con dlopen:
# devono dipendere solo da librerie di sistema.
bad = []
for lib in runtime_libs:
    out = subprocess.check_output(["otool", "-L", lib], text=True)
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" ")[0]
        if dep.startswith("/opt/homebrew") or dep.startswith("/usr/local"):
            bad.append(f"{os.path.basename(lib)} -> {dep}")
if bad:
    print("!! dipendenze non di sistema nel motore:")
    print("\n".join(bad))
    sys.exit(1)

# Nessun riferimento assoluto a Homebrew deve restare.
leaks = set()
lib_dir = d.lib_path(binary)
for f in [binary] + [os.path.join(lib_dir, x) for x in os.listdir(lib_dir)]:
    out = subprocess.check_output(["otool", "-L", f], text=True)
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" ")[0]
        if dep.startswith("/opt/homebrew") or dep.startswith("/usr/local"):
            leaks.add(f"{os.path.basename(f)} -> {dep}")
if leaks:
    print("!! riferimenti assoluti rimasti:")
    print("\n".join(sorted(leaks)))
    sys.exit(1)
print(f">> {len(os.listdir(lib_dir))} librerie copiate in {lib_dir}")
