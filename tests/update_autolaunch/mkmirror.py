#!/usr/bin/env python3
"""Build a tiny two-release mirror (GitHub API shape) for the installer tests.

usage: mkmirror.py ROOT BASE_URL publish v0.1.0|v0.1.1
Release v0.1.0 has parts core,c1..c5; v0.1.1 changes core,c1,c2,c4,c5 (c3 is reused from v0.1.0).
Parts are random (incompressible) so a throttled server makes the download take a while.
The game is a stub: run.sh writes a marker file and lists its open file descriptors.
"""
import hashlib, json, os, subprocess, sys, tempfile

root, base, _, tag = sys.argv[1:5]
PART_BYTES = int(os.environ.get("PART_BYTES", 1_200_000))
os.makedirs(f"{root}/assets", exist_ok=True)
rel_no = {"v0.1.0": 0, "v0.1.1": 1}[tag]
# rel_no 0 = first release; each chunk's content depends on the release that last changed it.
changed = {"v0.1.0": ["core", "c1", "c2", "c3", "c4", "c5"], "v0.1.1": ["core", "c1", "c2", "c4", "c5"]}
last = {"core": 1, "c1": 1, "c2": 1, "c3": 0, "c4": 1, "c5": 1}
RUN = """#!/usr/bin/env bash
# stub game %s
{ echo "started %s args=$* cwd=$PWD"; ls /proc/$$/fd | tr '\\n' ' '; echo; } >> "$HOME/game-started.marker"
exit 0
"""
PREP = """#!/usr/bin/env bash
if [ "$1" = --prepare ]; then
  for i in 1 2 3; do echo '{"event":"progress","done":'$i',"total":3}'; sleep 1; done
fi
exit 0
"""

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

def build_chunk(name, ver):
    d = tempfile.mkdtemp()
    files = []
    if name == "core":
        for fn, body, mode in (("run.sh", RUN % (tag, tag), 0o755), ("do27_launcher", PREP, 0o755)):
            with open(f"{d}/{fn}", "w") as f: f.write(body)
            os.chmod(f"{d}/{fn}", mode); files.append(fn)
        with open(f"{d}/build-info.toml", "w") as f: f.write(f'tag = "{tag}"\n')
        files.append("build-info.toml")
    else:
        os.makedirs(f"{d}/data", exist_ok=True)
        # deterministic per (chunk, release that last changed it)
        seed = hashlib.sha256(f"{name}-{ver}".encode()).digest()
        data = b"".join(hashlib.sha256(seed + i.to_bytes(4, "big")).digest() for i in range(PART_BYTES // 32))
        with open(f"{d}/data/{name}.bin", "wb") as f: f.write(data)
        files.append(f"data/{name}.bin")
    tmp = f"{root}/assets/.tmp.tar.zst"
    subprocess.check_call(f"tar -C {d} --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - {' '.join(files)} | zstd -q -1 -f -o {tmp}", shell=True)
    s = sha(tmp)
    asset = f"{name}-{s[:8]}.tar.zst"
    os.replace(tmp, f"{root}/assets/{asset}")
    unpacked = sum(os.path.getsize(f"{d}/{x}") for x in files)
    return asset, s, os.path.getsize(f"{root}/assets/{asset}"), unpacked, files

def asset_json(name):
    p = f"{root}/assets/{name}"
    return {"name": name, "digest": "sha256:" + sha(p), "url": f"{base}/api/{name}", "browser_download_url": f"{base}/assets/{name}"}

# manifest for this release: every chunk (reused ones keep their old content)
lines, assets = ["glibc_required\t2.35"], []
for name in ["core", "c1", "c2", "c3", "c4", "c5"]:
    ver = last[name] if tag == "v0.1.1" else 0
    asset, s, size, unpacked, files = build_chunk(name, ver if name != "core" else rel_no)
    lines.append("\t".join(["chunk", name, asset, s, str(size), str(unpacked)]))
    lines += ["\t".join(["file", name, f]) for f in files]
    if name in changed[tag]:
        assets.append(asset)
man = f"manifest-linux-low.tsv"
with open(f"{root}/assets/{man}", "w") as f: f.write("\n".join(lines) + "\n")
with open(f"{root}/assets/manifest-linux-low.json.sha256", "w") as f: f.write(f"{sha(f'{root}/assets/{man}')}  {man}\n")
with open(f"{root}/assets/LICENSE-ALPHA.txt", "w") as f: f.write("test license\n")
names = assets + [man, "manifest-linux-low.json.sha256", "LICENSE-ALPHA.txt"]
release = {"tag_name": tag, "draft": False, "prerelease": False, "assets": [asset_json(n) for n in names]}
prev = []
if os.path.exists(f"{root}/releases.json"):
    prev = [r for r in json.load(open(f"{root}/releases.json")) if r["tag_name"] != tag]
with open(f"{root}/releases.json", "w") as f: json.dump([release] + prev, f, indent=2)
with open(f"{root}/latest.json", "w") as f: json.dump(release, f, indent=2)
print("published", tag, "parts:", len(names) - 3, "total part bytes:", sum(os.path.getsize(f"{root}/assets/{a}") for a in assets))
