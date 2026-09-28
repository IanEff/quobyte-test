"""One namespace, two protocols.

The `lake` PVC's Quobyte volume is also published as the S3 bucket `lake`
(install_play.sh runs `qmgmt volume publish`). This pod mounts the volume
through CSI and talks to the bucket through the S3 gateway, and checks that
each side sees what the other wrote:

  posix->s3   write /lake/posix/<id>.txt, poll GET posix/<id>.txt
  s3->posix   PUT s3/<id>.txt, poll for /lake/s3/<id>.txt
  multipart   every BIG_EVERY rounds, multipart-upload BIG_MB and sha256
              the file through the mount

Logs how long each direction took to become visible. Old files are cleaned
up from both sides so the volume doesn't grow.
"""
import hashlib, io, os, socket, time, uuid

import boto3
from boto3.s3.transfer import TransferConfig
from botocore.config import Config
from botocore.exceptions import ClientError

MOUNT = "/lake"
BUCKET = os.environ.get("BUCKET", "lake")
ENDPOINT = os.environ.get("S3_ENDPOINT", "http://s3.quobyte-test.lab")
INTERVAL = float(os.environ.get("INTERVAL", 10))
BIG_EVERY = int(os.environ.get("BIG_EVERY", 6))
BIG_MB = int(os.environ.get("BIG_MB", 48))
KEEP = int(os.environ.get("KEEP", 20))
TIMEOUT = 30
HOST = socket.gethostname()

s3 = boto3.client(
    "s3",
    endpoint_url=ENDPOINT,
    region_name="us-east-1",
    config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 3}),
)


def log(msg):
    print(f"[crossproto {HOST}] {msg}", flush=True)


def wait_for(fn):
    t0 = time.monotonic()
    while time.monotonic() - t0 < TIMEOUT:
        if fn():
            return time.monotonic() - t0
        time.sleep(0.2)
    return None


def s3_body(key):
    try:
        return s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    except ClientError:
        return None


def file_body(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def posix_to_s3(rid):
    body = f"posix {rid} from {HOST}\n".encode()
    with open(f"{MOUNT}/posix/{rid}.txt", "wb") as f:
        f.write(body)
    secs = wait_for(lambda: s3_body(f"posix/{rid}.txt") == body)
    return secs


def s3_to_posix(rid):
    body = f"s3 {rid} from {HOST}\n".encode()
    s3.put_object(Bucket=BUCKET, Key=f"s3/{rid}.txt", Body=body)
    return wait_for(lambda: file_body(f"{MOUNT}/s3/{rid}.txt") == body)


def multipart(rid):
    data = os.urandom(BIG_MB << 20)
    want = hashlib.sha256(data).hexdigest()
    cfg = TransferConfig(multipart_threshold=8 << 20, multipart_chunksize=8 << 20)
    t0 = time.monotonic()
    s3.upload_fileobj(io.BytesIO(data), BUCKET, f"big/{rid}.bin", Config=cfg)
    up = time.monotonic() - t0
    got = hashlib.sha256(file_body(f"{MOUNT}/big/{rid}.bin") or b"").hexdigest()
    return up, got == want


def prune(sub, key_prefix):
    path = f"{MOUNT}/{sub}"
    names = sorted(os.listdir(path), key=lambda n: os.path.getmtime(f"{path}/{n}"))
    for n in names[:-KEEP]:
        s3.delete_object(Bucket=BUCKET, Key=f"{key_prefix}/{n}")


def main():
    for sub in ("posix", "s3", "big"):
        os.makedirs(f"{MOUNT}/{sub}", exist_ok=True)
    while True:
        try:
            s3.head_bucket(Bucket=BUCKET)
            break
        except ClientError as e:
            log(f"bucket {BUCKET} not ready yet ({e.response['Error']['Code']}), retrying")
            time.sleep(10)
    log(f"bucket {BUCKET} at {ENDPOINT} <-> {MOUNT}")
    n = 0
    while True:
        n += 1
        rid = f"{int(time.time())}-{uuid.uuid4().hex[:6]}"
        try:
            a = posix_to_s3(rid)
            b = s3_to_posix(rid)
            fmt = lambda s: "TIMEOUT" if s is None else f"{s * 1000:.0f}ms"
            line = f"round {n}: posix->s3 {fmt(a)}  s3->posix {fmt(b)}"
            if n % BIG_EVERY == 0:
                up, ok = multipart(rid)
                line += f"  multipart {BIG_MB} MiB {up:.1f}s via S3, sha256 via mount {'OK' if ok else 'MISMATCH'}"
            log(line)
            for sub in ("posix", "s3", "big"):
                prune(sub, sub)
        except Exception as e:  # keep the loop alive through gateway restarts
            log(f"round {n}: ERROR {type(e).__name__}: {e}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
