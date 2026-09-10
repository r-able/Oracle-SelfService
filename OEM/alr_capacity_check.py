#!/usr/bin/env python3
"""
Sums the MAXSIZE ceiling of every datafile/tempfile (across every SID in
/etc/oratab on the target host) that resides on the same physical mount as
the tablespace being extended, adds the proposed new datafile's ceiling,
and checks the total against 75% of that mount's TOTAL size (not free
space - see playbook header note on this interpretation).
"""
import sys, json

inventory_path, df_path, target_dir, new_file_bytes, safety_pct = (
    sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), float(sys.argv[5])
)

mounts = []
with open(df_path) as f:
    lines = [l.strip() for l in f if l.strip()]
for line in lines[1:]:
    parts = line.split()
    if len(parts) >= 3:
        mounts.append((parts[0], int(parts[1]), int(parts[2])))

def find_mount(path):
    best = None
    for tgt, size, avail in mounts:
        if path.startswith(tgt) and (best is None or len(tgt) > len(best[0])):
            best = (tgt, size, avail)
    return best

target_mount = find_mount(target_dir)
if not target_mount:
    print(json.dumps({"result": "ERROR", "reason": f"could not match {target_dir} to any mount"}))
    sys.exit(0)

committed = new_file_bytes
with open(inventory_path) as f:
    for line in f:
        parts = line.strip().split("|")
        if len(parts) != 3:
            continue
        _, fn, cb = parts
        try:
            cb = int(cb)
        except ValueError:
            continue
        m = find_mount(fn)
        if m and m[0] == target_mount[0]:
            committed += cb

threshold = target_mount[1] * safety_pct
result = "PASS" if committed <= threshold else "FAIL"
print(json.dumps({
    "result": result,
    "mount": target_mount[0],
    "mount_total_bytes": target_mount[1],
    "committed_bytes": committed,
    "threshold_bytes": int(threshold),
    "pct_of_total": round(committed / target_mount[1] * 100, 1)
}))
