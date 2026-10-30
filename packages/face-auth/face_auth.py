"""Webcam face check for PAM.

The daemon owns the camera and the enrolled face models. Clients connect to
its Unix socket. The enroll, verify, delete, and list commands follow
fprintd-enroll, fprintd-verify, fprintd-delete, and fprintd-list. The other
commands start scans, read the scan state, or collect the result of the last
scan during PAM authentication.

A scan has one of these results:

  match      A face is within the match tolerance of the enrolled model.
  uncertain  The closest face is between the match and reject tolerances.
  mismatch   Faces are in at least MIN_FACE_FRAMES frames. All are beyond
             the reject tolerance.
  absent     The camera saw too few faces, saw only dark frames, or failed.

"uncertain" and "absent" give no decision. A doubtful face can neither
replace the fingerprint nor reject the attempt.

The pam-biometrics command decides the biometric factor for pam_biometrics.so.
A fingerprint or a face can satisfy it. A password is always required.
"""

import argparse
import contextlib
import json
import os
import pwd
import re
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time

DEFAULT_SOCKET = "/run/face-auth/socket"

# A mismatch needs faces in this many frames. One bad frame must not reject the
# owner.
MIN_FACE_FRAMES = 3
MIN_ENROLL_SAMPLES = 3
MAX_ENROLL_SAMPLES = 10
# enroll --add keeps at most this many samples and drops the oldest first.
# Matching uses the closest sample, so more conditions lower the distance.
MAX_MODEL_SAMPLES = 30
# pam_fprintd also allows three tries.
MAX_FINGER_TRIES = 3

# Exit codes that pam_biometrics.so understands.
HELPER_MATCH = 0
HELPER_MISMATCH = 10
HELPER_NO_DECISION = 20

STATUS_TEXT = {
    "scanning": "Face: scanning…",
    "match": "Face: recognized",
    "mismatch": "Face: not recognized",
    "uncertain": "Face: not sure",
    "absent": "Face: no face found",
    "no-model": "Face: not enrolled",
}


def log(message):
    print(message, flush=True)


class Camera:
    """Reads RGB frames from a V4L2 device through ffmpeg."""

    def __init__(self, args):
        self.device = args.device
        self.input_format = args.input_format
        self.width = args.width
        self.height = args.height

    def frames(self, seconds):
        import numpy

        command = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error"]
        command += ["-f", "v4l2"]
        if self.input_format:
            command += ["-input_format", self.input_format]
            command += ["-video_size", f"{self.width}x{self.height}"]
        command += ["-i", self.device]
        command += ["-vf", f"scale={self.width}:{self.height}"]
        command += ["-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"]

        size = self.width * self.height * 3
        process = subprocess.Popen(command, stdout=subprocess.PIPE)
        # A stalled device blocks read(). Kill ffmpeg so that read() returns.
        watchdog = threading.Timer(seconds + 5, process.kill)
        watchdog.start()
        deadline = time.monotonic() + seconds
        try:
            while time.monotonic() < deadline:
                data = process.stdout.read(size)
                if len(data) < size:
                    return
                yield numpy.frombuffer(data, numpy.uint8).reshape(
                    self.height, self.width, 3
                )
        finally:
            watchdog.cancel()
            process.kill()
            process.wait()


class Engine:
    """Detects, encodes, and compares faces."""

    def __init__(self, args):
        import face_recognition
        import numpy

        self.recognition = face_recognition
        self.numpy = numpy
        self.camera = Camera(args)
        self.scan_seconds = args.scan_seconds
        self.enroll_seconds = args.enroll_seconds
        self.match_tolerance = args.match_tolerance
        self.reject_tolerance = args.reject_tolerance
        self.dark_threshold = args.dark_threshold

    def encodings(self, frame):
        if frame.mean() < self.dark_threshold:
            return []
        locations = self.recognition.face_locations(
            frame, number_of_times_to_upsample=0, model="hog"
        )
        if not locations:
            return []
        return self.recognition.face_encodings(frame, locations)

    def scan(self, model):
        known = self.numpy.array(model)
        face_frames = 0
        best = None
        # closing() stops ffmpeg as soon as a frame matches.
        with contextlib.closing(self.camera.frames(self.scan_seconds)) as frames:
            for frame in frames:
                encodings = self.encodings(frame)
                if not encodings:
                    continue
                face_frames += 1
                distance = float(
                    min(
                        self.recognition.face_distance(known, e).min()
                        for e in encodings
                    )
                )
                best = distance if best is None else min(best, distance)
                if distance <= self.match_tolerance:
                    return {"state": "match", "best": best, "faces": face_frames}
        if best is not None and best <= self.reject_tolerance:
            state = "uncertain"
        elif face_frames >= MIN_FACE_FRAMES:
            state = "mismatch"
        else:
            state = "absent"
        return {"state": state, "best": best, "faces": face_frames}

    def enroll(self):
        samples = []
        for frame in self.camera.frames(self.enroll_seconds):
            encodings = self.encodings(frame)
            if len(encodings) == 1:
                samples.append(encodings[0])
        if len(samples) < MIN_ENROLL_SAMPLES:
            raise RuntimeError(
                f"saw exactly one face in {len(samples)} frames; "
                f"need {MIN_ENROLL_SAMPLES}"
            )
        step = len(samples) / min(len(samples), MAX_ENROLL_SAMPLES)
        picked = [
            samples[int(i * step)] for i in range(min(len(samples), MAX_ENROLL_SAMPLES))
        ]
        return [sample.tolist() for sample in picked]


class Service:
    """Scan state shared by the socket handlers."""

    def __init__(self, args):
        self.engine = Engine(args)
        self.state_dir = args.state_dir
        self.device = args.device
        self.result_ttl = args.result_ttl
        self.greeter_uid = None
        if args.greeter_user:
            self.greeter_uid = pwd.getpwnam(args.greeter_user).pw_uid
        self.camera_lock = threading.Lock()
        self.changed = threading.Condition()
        # User name -> {"state", "finished", ...}.
        self.results = {}

    def model_path(self, user):
        return os.path.join(self.state_dir, f"{user}.json")

    def load_model(self, user):
        try:
            with open(self.model_path(user)) as file:
                return json.load(file)["encodings"]
        except FileNotFoundError:
            return None

    def authorized(self, uid, user, greeter_allowed):
        if uid == 0 or pwd.getpwnam(user).pw_uid == uid:
            return True
        return greeter_allowed and uid == self.greeter_uid

    def current(self, user):
        result = self.results.get(user)
        if result is None:
            return None
        if (
            result["state"] != "scanning"
            and time.monotonic() - result["finished"] > self.result_ttl
        ):
            del self.results[user]
            return None
        return result

    def finish(self, user, result):
        result["finished"] = time.monotonic()
        with self.changed:
            self.results[user] = result
            self.changed.notify_all()

    def start_scan(self, user):
        with self.changed:
            result = self.current(user)
            if result is not None and result["state"] == "scanning":
                return {"started": False}
            model = self.load_model(user)
            if model is None:
                self.results[user] = {"state": "no-model", "finished": time.monotonic()}
                return {"started": False, "error": "no-model"}
            self.results[user] = {"state": "scanning"}
        threading.Thread(target=self.run_scan, args=(user, model), daemon=True).start()
        return {"started": True}

    def run_scan(self, user, model):
        try:
            with self.camera_lock:
                result = self.engine.scan(model)
        except Exception as error:  # A failed scan counts as "no face".
            log(f"scan for {user} failed: {error}")
            result = {"state": "absent", "best": None, "faces": 0}
        log(
            f"scan for {user}: {result['state']} best={result['best']} faces={result['faces']}"
        )
        self.finish(user, result)

    def settled(self, user):
        """Wait for a running scan to end. Call with self.changed held."""
        deadline = time.monotonic() + self.engine.scan_seconds + 10
        while True:
            result = self.current(user)
            remaining = deadline - time.monotonic()
            if result is None or result["state"] != "scanning" or remaining <= 0:
                return result
            self.changed.wait(remaining)

    def take_verdict(self, user, expected):
        """Consume the last scan result if it is in the expected state.

        A scan that started after the caller read the state keeps its result.
        """
        with self.changed:
            result = self.settled(user)
            if result is None or result["state"] != expected:
                return False
            del self.results[user]
            return True

    def status(self, user, wait):
        with self.changed:
            result = self.settled(user) if wait else self.current(user)
        return "idle" if result is None else result["state"]

    def verify(self, user):
        model = self.load_model(user)
        if model is None:
            return {"state": "no-model"}
        with self.camera_lock:
            return self.engine.scan(model)

    def enroll(self, user, add):
        with self.camera_lock:
            encodings = self.engine.enroll()
        if add:
            existing = self.load_model(user) or []
            encodings = (existing + encodings)[-MAX_MODEL_SAMPLES:]
        path = self.model_path(user)
        temporary = f"{path}.tmp"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as file:
            json.dump({"version": 1, "encodings": encodings}, file)
        os.replace(temporary, path)
        log(f"enrolled {user} with {len(encodings)} samples")
        return {"samples": len(encodings)}

    def delete(self, user):
        try:
            os.remove(self.model_path(user))
        except FileNotFoundError:
            return {"deleted": False}
        return {"deleted": True}

    def list(self, user):
        model = self.load_model(user)
        return {"samples": 0 if model is None else len(model)}

    def handle(self, uid, request):
        operation = request.get("op")
        user = request.get("user")
        if not isinstance(user, str):
            return {"error": "missing user"}
        try:
            user = pwd.getpwnam(user).pw_name
        except KeyError:
            return {"error": "unknown user"}

        handlers = {
            "scan": (True, self.start_scan),
            "status": (False, lambda u: {"state": self.status(u, wait=False)}),
            "wait": (False, lambda u: {"state": self.status(u, wait=True)}),
            "verdict": (
                False,
                lambda u: {"verdict": self.take_verdict(u, request.get("expected"))},
            ),
            "verify": (False, self.verify),
            "enroll": (False, lambda u: self.enroll(u, add=request.get("add") is True)),
            "delete": (False, self.delete),
            "list": (False, self.list),
        }
        if operation not in handlers:
            return {"error": "unknown operation"}
        greeter_allowed, handler = handlers[operation]
        if not self.authorized(uid, user, greeter_allowed):
            return {"error": "permission denied"}
        try:
            reply = handler(user)
        except RuntimeError as error:
            return {"error": str(error)}
        return {**reply, "device": self.device}


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        credentials = self.request.getsockopt(
            socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
        )
        _, uid, _ = struct.unpack("3i", credentials)
        line = self.rfile.readline(4096)
        try:
            request = json.loads(line)
        except ValueError:
            reply = {"error": "bad request"}
        else:
            reply = self.server.service.handle(uid, request)
        self.wfile.write(json.dumps(reply).encode() + b"\n")


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def run_daemon(args):
    os.umask(0o077)
    service = Service(args)
    try:
        os.unlink(args.socket)
    except FileNotFoundError:
        pass
    server = Server(args.socket, Handler)
    # Every user must reach the socket: the greeter, PAM in hyprlock, and the
    # lock-screen key binding. The handlers check the peer credentials.
    os.chmod(args.socket, 0o666)
    server.service = service
    log(f"listening on {args.socket}")
    server.serve_forever()


def request(args, operation, user, timeout, **fields):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(timeout)
        client.connect(args.socket)
        message = {"op": operation, "user": user, **fields}
        client.sendall(json.dumps(message).encode() + b"\n")
        with client.makefile("rb") as reply:
            return json.loads(reply.readline())


def own_user():
    return pwd.getpwuid(os.getuid()).pw_name


def run_client(args):
    user = getattr(args, "user", None) or own_user()

    if args.command == "pam-biometrics":
        return pam_biometrics(args)

    if args.command in ("status", "wait"):
        try:
            state = request(args, args.command, user, 30).get("state")
        except (OSError, ValueError):
            return 0
        print(STATUS_TEXT.get(state, ""))
        return 0

    if args.command == "scan":
        reply = request(args, "scan", user, 5)
        print(json.dumps(reply))
        return 1 if "error" in reply else 0
    if args.command == "verify":
        return verify(args, user)
    if args.command == "enroll":
        return enroll(args, user)

    # delete and list take one or more user names, like fprintd-delete and
    # fprintd-list.
    status = 0
    for user in args.users:
        reply = request(args, args.command, user, 5)
        if "error" in reply:
            print(f"Failed for user {user}: {reply['error']}")
            status = 1
        elif args.command == "delete":
            if reply["deleted"]:
                print(f"Face of user {user} deleted on {reply['device']}")
            else:
                print(f"No face to delete on {reply['device']}")
        elif reply["samples"]:
            print(f"Face for user {user} on {reply['device']}:")
            print(f" - #0: face ({reply['samples']} samples)")
        else:
            print(f"User {user} has no face enrolled for {reply['device']}.")
    return status


# fprintd result names. A scan without a usable or a clear face asks for
# another scan.
VERIFY_RESULTS = {
    "match": "verify-match",
    "mismatch": "verify-no-match",
    "uncertain": "verify-retry-scan",
    "absent": "verify-retry-scan",
}


def verify(args, user):
    reply = request(args, "verify", user, 60)
    if args.json:
        print(json.dumps(reply))
    elif "error" in reply:
        print(f"Impossible to verify: {reply['error']}")
    elif reply["state"] == "no-model":
        print("No face enrolled for this device.")
    else:
        print(f"Using device {reply['device']}")
        print("Verifying: face")
        print(f"Verify result: {VERIFY_RESULTS[reply['state']]} (done)")
    return 0 if reply.get("state") == "match" else 1


def enroll(args, user):
    print("Enrolling face. Look at the camera.", flush=True)
    reply = request(args, "enroll", user, 60, add=args.add)
    if "error" in reply:
        print(f"Enroll result: enroll-failed ({reply['error']})")
        return 1
    print(f"Using device {reply['device']}")
    print(f"Enroll result: enroll-completed ({reply['samples']} samples)")
    return 0


class Fingerprint:
    """Runs fprintd-verify in the background until a finger is decided."""

    def __init__(self, command, user):
        self.command = command
        self.user = user
        # waiting, match, mismatch, or unavailable.
        self.result = "waiting"
        self.lock = threading.Lock()
        self.process = None
        self.stopped = False
        threading.Thread(target=self.run, daemon=True).start()

    def run(self):
        for attempt in range(MAX_FINGER_TRIES):
            with self.lock:
                if self.stopped:
                    return
                self.process = subprocess.Popen(
                    # Without -f, fprintd-verify accepts only the first
                    # enrolled finger. pam_fprintd accepts any of them.
                    [self.command, "-f", "any", self.user],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                )
            output, _ = self.process.communicate()
            results = re.findall(r"^Verify result: (\S+)", output, re.MULTILINE)
            last = results[-1] if results else None
            if last == "verify-match":
                self.result = "match"
                return
            if last != "verify-no-match":
                # No reader, no enrolled finger, or a stopped scan.
                self.result = "unavailable"
                return
            if attempt + 1 < MAX_FINGER_TRIES:
                print("Fingerprint not recognized. Try again.", flush=True)
        self.result = "mismatch"

    def stop(self):
        with self.lock:
            self.stopped = True
            if self.process is not None:
                self.process.kill()


def pam_biometrics(args):
    """Accept the first fingerprint or face that matches.

    The command waits while the fingerprint reader waits for a finger or the
    camera scans, up to the timeout. A match from either factor wins at once.
    Without a match, a wrong finger or another face rejects the attempt. No
    finger and no face leave the decision to the password.
    """
    if os.environ.get("PAM_TYPE") != "auth" or not os.environ.get("PAM_USER"):
        return HELPER_NO_DECISION
    user = os.environ["PAM_USER"]

    def face_state():
        try:
            return request(args, "status", user, 2).get("state", "idle")
        except (OSError, ValueError):
            return "idle"

    def consume(state):
        # A scan result counts for one attempt only.
        if state in ("match", "mismatch", "uncertain", "absent"):
            with contextlib.suppress(OSError, ValueError):
                request(args, "verdict", user, 2, expected=state)

    finger = None
    if args.fingerprint_command:
        finger = Fingerprint(args.fingerprint_command, user)
        print("Touch the fingerprint reader or press Super+Alt+F.", flush=True)
    deadline = time.monotonic() + args.timeout
    try:
        while True:
            face = face_state()
            fingerprint = finger.result if finger else "unavailable"
            if face == "match" or fingerprint == "match":
                consume(face)
                print(
                    "Face recognized." if face == "match" else "Fingerprint recognized."
                )
                return HELPER_MATCH
            undecided = fingerprint == "waiting" or face == "scanning"
            if not undecided or time.monotonic() >= deadline:
                consume(face)
                if "mismatch" in (face, fingerprint):
                    print("Not recognized.")
                    return HELPER_MISMATCH
                return HELPER_NO_DECISION
            time.sleep(0.2)
    finally:
        if finger is not None:
            finger.stop()


def main():
    parser = argparse.ArgumentParser(
        prog="face-auth", description=__doc__.split("\n")[0]
    )
    parser.add_argument("--socket", default=DEFAULT_SOCKET)
    commands = parser.add_subparsers(dest="command", required=True)

    daemon = commands.add_parser("daemon", help="run the camera daemon")
    daemon.add_argument("--device", required=True)
    daemon.add_argument("--input-format", help="V4L2 input format, for example mjpeg")
    daemon.add_argument("--width", type=int, default=640)
    daemon.add_argument("--height", type=int, default=360)
    daemon.add_argument("--scan-seconds", type=float, default=4)
    daemon.add_argument("--enroll-seconds", type=float, default=6)
    # The face_recognition default is 0.6. A face at or below the match
    # tolerance replaces the fingerprint. Faces only beyond the reject
    # tolerance reject the attempt. Anything between gives no decision, so a
    # strict match tolerance cannot lock the owner out in poor light.
    daemon.add_argument("--match-tolerance", type=float, default=0.45)
    daemon.add_argument("--reject-tolerance", type=float, default=0.6)
    daemon.add_argument("--dark-threshold", type=float, default=10)
    daemon.add_argument("--result-ttl", type=float, default=120)
    daemon.add_argument("--greeter-user")
    daemon.add_argument("--state-dir", required=True)

    scan = commands.add_parser(
        "scan", help="start a background scan for USER (default: you)"
    )
    scan.add_argument("user", nargs="?")
    enroll_command = commands.add_parser(
        "enroll", help="enroll a face for USER (default: you)"
    )
    enroll_command.add_argument("user", nargs="?")
    enroll_command.add_argument(
        "--add",
        action="store_true",
        help=f"keep the enrolled samples and add new ones (at most {MAX_MODEL_SAMPLES})",
    )
    verify_command = commands.add_parser(
        "verify", help="scan now and compare with the face of USER (default: you)"
    )
    verify_command.add_argument("user", nargs="?")
    verify_command.add_argument(
        "--json", action="store_true", help="print the raw scan result as JSON"
    )
    for name, help_text in [
        ("delete", "delete the enrolled faces of the users"),
        ("list", "list the enrolled faces of the users"),
    ]:
        command = commands.add_parser(name, help=help_text)
        command.add_argument("users", nargs="+", metavar="user")
    commands.add_parser("status", help="print the state of your last scan")
    commands.add_parser("wait", help="wait for your running scan, then print its state")
    pam = commands.add_parser(
        "pam-biometrics", help="decide the biometric factor for pam_biometrics.so"
    )
    pam.add_argument("--timeout", type=float, default=15)
    pam.add_argument("--fingerprint-command", help="path of fprintd-verify")

    args = parser.parse_args()
    if args.command == "daemon":
        run_daemon(args)
        return 0
    return run_client(args)


if __name__ == "__main__":
    sys.exit(main())
