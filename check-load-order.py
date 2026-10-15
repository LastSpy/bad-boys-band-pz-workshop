#!/usr/bin/env python3
"""Checks the server mod list against each mod's own mod.info, using the version folder
the game actually loads (highest numeric folder <= GAME that has mod.info, else common/, else the mod root).
Usage: check-load-order.py [ini] [workshop_dir]"""
import os, re, sys
GAME = (42, 21)
ini = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\Administrator\Zomboid\Server\3dpz.ini'
W = sys.argv[2] if len(sys.argv) > 2 else r'D:\SteamLibrary\steamapps\workshop\content\108600'
text = open(ini, encoding='utf-8', errors='replace').read()
mods = [m.strip() for m in re.search(r'^Mods=(.*?)\r?$', text, re.M).group(1).split(';') if m.strip()]
items = [i for i in re.search(r'^WorkshopItems=(.*?)\r?$', text, re.M).group(1).split(';') if i]

def ver(name):
    m = re.fullmatch(r'(\d+)(?:\.(\d+))?(?:\.\d+)?', name)
    return (int(m.group(1)), int(m.group(2) or 0)) if m else None

def ids(v):
    return [x.strip().lstrip(chr(92)) for x in re.split(r'[;,]', v or '') if x.strip()]

info = {}
for wid in items:
    root = os.path.join(W, wid, 'mods')
    if not os.path.isdir(root): print('NOT DOWNLOADED', wid); continue
    for mod in os.listdir(root):
        d = os.path.join(root, mod)
        vers = sorted((ver(n), n) for n in os.listdir(d) if ver(n) and ver(n) <= GAME and os.path.isfile(os.path.join(d, n, 'mod.info')))
        cands = ([os.path.join(d, vers[-1][1], 'mod.info')] if vers else []) +                 [os.path.join(d, 'common', 'mod.info'), os.path.join(d, 'mod.info')]
        f = next((c for c in cands if os.path.isfile(c)), None)
        if not f: continue
        t = open(f, encoding='utf-8-sig', errors='replace').read()
        g = lambda k: (re.search(rf'^{k}\s*=\s*(.*?)\s*$', t, re.M | re.I) or [None, ''])[1]
        mid = g('id').lstrip(chr(92))
        info[mid] = dict(wid=wid, folder=os.path.relpath(f, W), require=ids(g('require')),
                         after=ids(g('loadModAfter')), before=ids(g('loadModBefore')), incompatible=ids(g('incompatible')))
pos = {m: i for i, m in enumerate(mods)}
problems = 0
for m in mods:
    d = info.get(m)
    if not d: print(f'NO MOD.INFO for {m}'); problems += 1; continue
    for r in d['require']:
        if r not in pos: print(f'MISSING   {m} requires {r}  ({d["folder"]})'); problems += 1
        elif pos[r] > pos[m]: print(f'ORDER     {m} (#{pos[m]}) before required {r} (#{pos[r]})'); problems += 1
    for r in d['after']:
        if r in pos and pos[r] > pos[m]: print(f'ORDER     {m} (#{pos[m]}) should load after {r} (#{pos[r]})'); problems += 1
    for b in d['before']:
        if b in pos and pos[b] < pos[m]: print(f'ORDER     {m} (#{pos[m]}) should load before {b} (#{pos[b]})'); problems += 1
    for x in d['incompatible']:
        if x in pos: print(f'CONFLICT  {m} is incompatible with {x}'); problems += 1
print(f'{len(mods)} mods, {len(items)} items, {problems} problem(s)')
