"""Checkpoint writer, shaped like a training job.

Every INTERVAL seconds: write SHARDS shards of SHARD_MB random bytes under
/data/ckpt/step-NNNNNN/, fsync each, write manifest.json with every shard's
sha256, then publish the step by renaming LATEST.tmp over LATEST. Keeps the
newest KEEP steps and deletes the rest.

The evaluators on other nodes trust that ordering: if they can read LATEST,
the manifest and shards it names must already be complete. That's the
close-to-open contract Quobyte's docs promise, tested across nodes.
"""
import hashlib, json, os, shutil, socket, time

ROOT = "/data/ckpt"
SHARDS = int(os.environ.get("SHARDS", 4))
SHARD_MB = int(os.environ.get("SHARD_MB", 32))
INTERVAL = int(os.environ.get("INTERVAL", 60))
KEEP = int(os.environ.get("KEEP", 3))
HOST = socket.gethostname()


def log(msg):
    print(f"[trainer {HOST}] {msg}", flush=True)


def write_shard(path):
    data = os.urandom(SHARD_MB << 20)
    with open(path, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    return hashlib.sha256(data).hexdigest()


def publish(step):
    tmp = os.path.join(ROOT, "LATEST.tmp")
    with open(tmp, "w") as f:
        f.write(f"{step}\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, os.path.join(ROOT, "LATEST"))


def prune():
    steps = sorted(d for d in os.listdir(ROOT) if d.startswith("step-"))
    for old in steps[:-KEEP]:
        shutil.rmtree(os.path.join(ROOT, old), ignore_errors=True)


def resume_step():
    try:
        with open(os.path.join(ROOT, "LATEST")) as f:
            return int(f.read()) + 1
    except (FileNotFoundError, ValueError):
        return 0


def main():
    os.makedirs(ROOT, exist_ok=True)
    step = resume_step()
    log(f"resuming at step {step}: {SHARDS}x{SHARD_MB} MiB every {INTERVAL}s, keep {KEEP}")
    while True:
        t0 = time.monotonic()
        d = os.path.join(ROOT, f"step-{step:06d}")
        os.makedirs(d, exist_ok=True)
        manifest = {"step": step, "writer": HOST, "shards": {}}
        for i in range(SHARDS):
            name = f"shard-{i}.bin"
            manifest["shards"][name] = write_shard(os.path.join(d, name))
        with open(os.path.join(d, "manifest.json"), "w") as f:
            json.dump(manifest, f)
            f.flush()
            os.fsync(f.fileno())
        publish(step)
        secs = time.monotonic() - t0
        mb = SHARDS * SHARD_MB
        log(f"step {step}: wrote {mb} MiB in {secs:.1f}s ({mb / secs:.1f} MiB/s)")
        prune()
        step += 1
        time.sleep(max(0, INTERVAL - secs))


if __name__ == "__main__":
    main()
