#!/usr/bin/env python3
import sys,glob,re,collections
rows=collections.defaultdict(list)
for f in glob.glob(sys.argv[1]+'/*.log'):
    for l in open(f):
        if not l.startswith('SIM'): continue
        d=dict(x.split('=') for x in l.split()[1:])
        rows[(d['boss'],d['diff'],int(d['round']),int(d['players']),d['bot'])].append(d)
for k in sorted(rows):
    r=rows[k]
    res=''.join({'win':'W','wipe':'X','dnf':'D'}[x['result']] for x in r)
    tt=[float(x['ttk']) for x in r]; dm=[float(x['dmg']) for x in r]; mh=[float(x['min_hp']) for x in r]
    print("%-16s %-6s r%-2d p%d %-9s %-3s ttk %s dmg %s minhp %s dpsr %s"%(k+(res,'/'.join('%.0f'%t for t in tt),'/'.join('%.0f'%t for t in dm),'/'.join('%.0f'%t for t in mh),'/'.join(x.get('dps_ratio','-') for x in r))))
