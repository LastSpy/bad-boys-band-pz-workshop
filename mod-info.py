#!/usr/bin/env python3
"""Shows, for given Workshop items, every mod inside and the mod.info the game would load on 42.21.
Usage: mod-info.py ID [ID...]"""
import os, re, sys
GAME = (42, 21)
W = r'D:\SteamLibrary\steamapps\workshop\content\108600'
def ver(n):
    m = re.fullmatch(r'(\d+)(?:\.(\d+))?(?:\.\d+)?', n)
    return (int(m.group(1)), int(m.group(2) or 0)) if m else None
for wid in sys.argv[1:]:
    root = os.path.join(W, wid, 'mods')
    print(f'### {wid}')
    for mod in sorted(os.listdir(root)):
        d = os.path.join(root, mod)
        if not os.path.isdir(d): continue
        allv = sorted(n for n in os.listdir(d) if ver(n))
        vers = sorted((ver(n), n) for n in allv if ver(n) <= GAME and os.path.isfile(os.path.join(d, n, 'mod.info')))
        cands = ([os.path.join(d, vers[-1][1], 'mod.info')] if vers else []) + [os.path.join(d, 'common', 'mod.info'), os.path.join(d, 'mod.info')]
        f = next((c for c in cands if os.path.isfile(c)), None)
        if not f: print(f'  {mod}: no mod.info'); continue
        t = open(f, encoding='utf-8-sig', errors='replace').read()
        g = lambda k: (re.search(rf'^{k}\s*=\s*(.*?)\s*$', t, re.M | re.I) or [None, ''])[1]
        b42 = 'B42-ready' if vers or os.path.isdir(os.path.join(d, 'common')) or any(ver(n) and ver(n) >= (42, 0) for n in allv) else 'B41-only?'
        extra = ' '.join(f'{k}={g(k)}' for k in ('require', 'loadModAfter', 'loadModBefore', 'incompatible', 'versionMin', 'versionMax') if g(k))
        print(f'  [{mod}] id={g("id")} | {g("name")} | folders={allv or "-"} | {b42} {extra}')
