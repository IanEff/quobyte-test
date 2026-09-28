"""Checkpoint reader. Runs on other nodes than the trainer.

Polls LATEST. On each new step, reads manifest.json and every shard,
re-hashes, and compares. Three outcomes get logged:
  OK        every shard matches
  MISMATCH  a shard's bytes differ from the manifest (stale or torn read)
  ORDERING  LATEST names a step whose manifest or shard isn't visible yet,
            i.e. this node saw the rename before the data it publishes
A step pruned mid-read (the trainer keeps only a few) is noted, not counted
as a failure.
"""
import hashlib, json, os, socket, time

ROOT = "/data/ckpt"
POLL = float(os.environ.get("POLL", 5))
HOST = socket.gethostname()
counts = {"OK": 0, "MISMATCH": 0, "ORDERING": 0, "PRUNED": 0}


def log(msg):
    print(f"[evaluator {HOST}] {msg}", flush=True)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(4 << 20):
            h.update(chunk)
    return h.hexdigest(), os.path.getsize(path)


def check(step):
    d = os.path.join(ROOT, f"step-{step:06d}")
    try:
        with open(os.path.join(d, "manifest.json")) as f:
            manifest = json.load(f)
    except FileNotFoundError:
        return "ORDERING", f"LATEST={step} but {d}/manifest.json is not visible"
    t0 = time.monotonic()
    total = 0
    for name, want in manifest["shards"].items():
        try:
            got, size = sha256_file(os.path.join(d, name))
        except FileNotFoundError:
            if not os.path.isdir(d):
                return "PRUNED", f"step {step} pruned while reading"
            return "ORDERING", f"step {step}: {name} listed in manifest but missing"
        total += size
        if got != want:
            return "MISMATCH", f"step {step}: {name} sha256 {got[:12]} != manifest {want[:12]}"
    secs = time.monotonic() - t0
    mb = total / (1 << 20)
    return "OK", f"step {step} from {manifest['writer']}: {mb:.0f} MiB verified in {secs:.1f}s ({mb / secs:.1f} MiB/s)"


def main():
    seen = None
    log(f"watching {ROOT}/LATEST every {POLL}s")
    while True:
        try:
            with open(os.path.join(ROOT, "LATEST")) as f:
                step = int(f.read())
        except (FileNotFoundError, ValueError):
            time.sleep(POLL)
            continue
        if step != seen:
            verdict, detail = check(step)
            counts[verdict] += 1
            log(f"{verdict:8} {detail}  totals={counts}")
            seen = step
        time.sleep(POLL)


if __name__ == "__main__":
    main()
