"""Small-file metadata churn, the part of a filesystem most benchmarks skip.

Each round builds DIRS directories of FILES tiny files, then walks the tree
through the operations a build system or package manager hammers: stat,
readdir, rename, chmod, append, unlink, rmdir. Logs ops/s per phase so you can
line it up against the metadata service panels in Grafana.
"""
import os, shutil, socket, time

ROOT = f"/scratch/storm/{socket.gethostname()}"
DIRS = int(os.environ.get("DIRS", 20))
FILES = int(os.environ.get("FILES", 50))
PAUSE = float(os.environ.get("PAUSE", 15))
HOST = socket.gethostname()


def log(msg):
    print(f"[metastorm {HOST}] {msg}", flush=True)


def phase(name, fn, stats):
    t0 = time.monotonic()
    ops = fn()
    secs = time.monotonic() - t0
    stats.append(f"{name} {ops / secs:.0f}/s")


def run(round_no):
    base = f"{ROOT}/round-{round_no:05d}"
    paths = [f"{base}/d{d:03d}/f{f:04d}" for d in range(DIRS) for f in range(FILES)]
    stats = []

    def create():
        for d in range(DIRS):
            os.makedirs(f"{base}/d{d:03d}", exist_ok=True)
        for i, p in enumerate(paths):
            with open(p, "wb") as fh:
                fh.write(b"x" * (i % 4096))
        return DIRS + len(paths)

    def stat():
        for p in paths:
            os.stat(p)
        return len(paths)

    def readdir():
        n = 0
        for _ in range(5):
            for d in range(DIRS):
                n += len(os.listdir(f"{base}/d{d:03d}"))
        return 5 * DIRS

    def rename():
        for i, p in enumerate(paths):
            if i % 2 == 0:
                os.rename(p, p + ".renamed")
                paths[i] = p + ".renamed"
        return len(paths) // 2

    def chmod_append():
        for p in paths:
            os.chmod(p, 0o640)
            with open(p, "ab") as fh:
                fh.write(b"\n")
        return 2 * len(paths)

    def unlink():
        for p in paths:
            os.unlink(p)
        shutil.rmtree(base)
        return len(paths) + DIRS

    for name, fn in [("create", create), ("stat", stat), ("readdir", readdir),
                     ("rename", rename), ("chmod+append", chmod_append), ("unlink", unlink)]:
        phase(name, fn, stats)
    log(f"round {round_no}: {len(paths)} files  " + "  ".join(stats))


def main():
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(ROOT, exist_ok=True)
    n = 0
    while True:
        n += 1
        try:
            run(n)
        except OSError as e:
            log(f"round {n}: ERROR {e}")
        time.sleep(PAUSE)


if __name__ == "__main__":
    main()
