"""Populate /home with something worth asking questions about.

The File Query Engine (and the MCP server on top of it) answers questions
about file metadata: owner, size, age, type, placement. An empty volume
makes for a dull demo, so this builds a small fake research group's home
volume, seeded so every run produces the same tree:

  - five users with project trees of mixed file types
  - mtimes and atimes spread over three years, so "what's old and unread"
    has an answer
  - a few sparse multi-GiB "checkpoints" (large logical size, almost no
    physical data), a pile of stale scratch, some world-writable files,
    and an orphaned tree left by someone who has since left

Ownership is attempted with chown but, on this rig, Quobyte refuses it with
EPERM even from root (uids 1001+ map to no Quobyte user). So every file also
carries user.owner and user.project xattrs, which the File Query Engine can
query as user-defined metadata. The chown failures are counted, not hidden.

Existing files are left alone, so re-running is cheap.
"""
import os, random, time

ROOT = "/home-vol"
rng = random.Random(1815)
NOW = time.time()
DAY = 86400
USERS = {"alice": 1001, "bob": 1002, "carol": 1003, "dave": 1004, "erin": 1005}
KINDS = [
    # suffix, weight, size range in bytes
    (".parquet", 5, (256 << 10, 4 << 20)),
    (".csv", 4, (4 << 10, 2 << 20)),
    (".log", 6, (1 << 10, 512 << 10)),
    (".py", 4, (200, 20 << 10)),
    (".ipynb", 2, (10 << 10, 1 << 20)),
    (".png", 3, (20 << 10, 900 << 10)),
    (".json", 3, (100, 64 << 10)),
    (".tmp", 2, (0, 128 << 10)),
]
created = skipped = chown_denied = 0


def tag(path, uid):
    owner = next((n for n, u in USERS.items() if u == uid), f"uid{uid}")
    project = path[len(ROOT) + 1:].split("/")[1] if path.count("/") > 3 else "-"
    os.setxattr(path, "user.owner", owner.encode())
    os.setxattr(path, "user.project", project.encode())


def put(path, size, uid, age_days, mode=0o644, sparse=False):
    global created, skipped, chown_denied
    # Draw everything random before the exists check: skipping the draws for
    # files that already exist would shift the seeded sequence and make a
    # re-run generate different paths.
    blob = rng.randbytes(min(size, 64 << 10))
    mtime = NOW - age_days * DAY
    atime = min(NOW, mtime + rng.uniform(0, max(1, age_days)) * DAY * rng.choice([0, 0, 0.1, 1]))
    if os.path.exists(path):
        tag(path, uid)
        skipped += 1
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        if sparse:
            f.truncate(size)
            f.seek(size - 4096)
            f.write(os.urandom(4096))
        elif size:
            f.write(blob * max(1, size // len(blob)))
    try:
        os.chown(path, uid, uid)
    except PermissionError:
        chown_denied += 1
    tag(path, uid)
    os.chmod(path, mode)
    os.utime(path, (atime, mtime))
    created += 1


def main():
    names, weights = zip(*[(k, w) for k, w, _ in KINDS])
    sizes = {k: r for k, _, r in KINDS}
    for user, uid in USERS.items():
        for p in range(rng.randint(2, 5)):
            project = rng.choice(["genomics", "vision", "llm-eval", "climate", "robotics", "survey"])
            base = f"{ROOT}/{user}/{project}-{p}"
            for i in range(rng.randint(30, 120)):
                kind = rng.choices(names, weights)[0]
                lo, hi = sizes[kind]
                sub = rng.choice(["", "data/", "out/", "notebooks/", "runs/"])
                put(f"{base}/{sub}{kind[1:]}-{i:04d}{kind}", rng.randint(lo, hi), uid,
                    age_days=rng.betavariate(1.2, 3) * 1100)
        # One user leaves huge (sparse) checkpoints behind.
        if user in ("bob", "dave"):
            for c in range(3):
                put(f"{ROOT}/{user}/checkpoints/model-epoch{c:02d}.ckpt",
                    rng.randint(1, 4) << 30, uid, age_days=rng.uniform(200, 800), sparse=True)
        # Stale scratch nobody cleaned up.
        for i in range(rng.randint(10, 40)):
            put(f"{ROOT}/{user}/scratch/tmp-{i:03d}.tmp", rng.randint(0, 64 << 10), uid,
                age_days=rng.uniform(400, 1000))
    # Shared area with sloppy permissions.
    for i in range(15):
        put(f"{ROOT}/shared/drop/upload-{i:03d}.csv", rng.randint(1 << 10, 1 << 20),
            rng.choice(list(USERS.values())), age_days=rng.uniform(1, 300), mode=0o666)
    # Someone who left: uid 1099 maps to no user.
    for i in range(25):
        put(f"{ROOT}/former-staff/mallory/archive-{i:03d}.parquet", rng.randint(1 << 20, 6 << 20),
            1099, age_days=rng.uniform(700, 1100))
    print(f"[datagen] created {created}, already present {skipped}, "
          f"chown refused {chown_denied} (ownership is in user.owner xattrs)", flush=True)


if __name__ == "__main__":
    main()
