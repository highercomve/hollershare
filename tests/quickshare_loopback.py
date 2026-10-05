#!/usr/bin/env python3
"""Exercise the real encrypted Quick Share protocol in two isolated processes."""
import ctypes
import json
import multiprocessing as mp
import os
from pathlib import Path
import socket
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]

def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]

def worker(connection, directory, bind_port):
    os.environ["HOLLERSHARE_PORT"] = str(bind_port)
    os.environ["XDG_STATE_HOME"] = str(directory.parent / "state")
    library = ctypes.CDLL(str(ROOT / "target/release/libhollershare_quickshare.so"))
    for name in ("hollershare_start", "hollershare_request"):
        fn = getattr(library, name)
        fn.argtypes = [ctypes.c_char_p]
        fn.restype = ctypes.c_void_p
    library.hollershare_free.argtypes = [ctypes.c_void_p]
    def invoke(fn, value):
        pointer = fn(value)
        assert pointer
        try:
            result = json.loads(ctypes.string_at(pointer))
        finally:
            library.hollershare_free(pointer)
        return result
    connection.send(invoke(library.hollershare_start, os.fsencode(directory)))
    try:
        while True:
            value = connection.recv()
            if value is None:
                break
            connection.send(invoke(library.hollershare_request, json.dumps(value).encode()))
    finally:
        library.hollershare_stop()
        connection.close()

def request(connection, command, **args):
    connection.send(dict(command=command, **args))
    assert connection.poll(12), "engine did not answer"
    result = connection.recv()
    assert result["ok"], result
    return result["data"]

def wait(connection, predicate):
    deadline = time.monotonic() + 20
    last = None
    while time.monotonic() < deadline:
        last = request(connection, "snapshot")
        match = next((t for t in last["transfers"] if predicate(t)), None)
        if match:
            return match
        time.sleep(0.1)
    raise AssertionError(last)

def delayed_completion_proxy(receiver_port):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0)); listener.listen(1)
    proxy_port = listener.getsockname()[1]
    paused, release = threading.Event(), threading.Event()
    def read_exact(source, length):
        value = bytearray()
        while len(value) < length:
            part = source.recv(length - len(value))
            if not part: return None
            value.extend(part)
        return bytes(value)
    def relay(source, destination, delay):
        consent_frames = 2
        try:
            while True:
                if delay:
                    header = read_exact(source, 4)
                    if header is None: break
                    body = read_exact(source, int.from_bytes(header, "big"))
                    if body is None: break
                    data = header + body
                    if paused.is_set():
                        if consent_frames: consent_frames -= 1
                        else: assert release.wait(10), "completion gate timed out"
                else:
                    data = source.recv(65536)
                    if not data: break
                destination.sendall(data)
        except OSError:
            pass
        finally:
            try: destination.shutdown(socket.SHUT_WR)
            except OSError: pass
    def run():
        client, _ = listener.accept()
        with client, socket.create_connection(("127.0.0.1", receiver_port)) as receiver:
            forward = threading.Thread(target=relay, args=(client, receiver, False), daemon=True)
            forward.start()
            relay(receiver, client, True)
            forward.join(10)
        listener.close()
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return proxy_port, paused, release, thread

def main():
    mp.set_start_method("spawn")
    with tempfile.TemporaryDirectory(prefix="hollershare-test-") as temporary:
        directory = Path(temporary)
        destination = directory / "received"
        destination.mkdir()
        sender_port, receiver_port = port(), port()
        processes, connections = [], []
        for folder, bind_port in ((directory / "sender", sender_port), (destination, receiver_port)):
            parent, child = mp.Pipe()
            process = mp.Process(target=worker, args=(child, folder, bind_port))
            process.start()
            child.close()
            processes.append(process)
            connections.append(parent)
        try:
            for connection in connections:
                assert connection.poll(15), "startup timed out"
                ready = connection.recv()
                assert ready["ok"], ready
            sender, receiver = connections
            files = []
            for name, data in (("hello.txt", b"Hello from HollerShare!\n"), ("binary.dat", os.urandom(2_000_000)), ("empty.txt", b"")):
                path = directory / name
                path.write_bytes(data)
                files.append(str(path))
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=files)
            incoming = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            assert not list(destination.iterdir()), "files created without approval"
            outgoing = wait(sender, lambda t: t.get("meta", {}).get("pin_code") is not None)
            assert incoming["meta"]["pin_code"] == outgoing["meta"]["pin_code"], "PIN mismatch"
            request(receiver, "decide", id=incoming["id"], accept=True)
            wait(receiver, lambda t: t["id"] == incoming["id"] and t["state"] == "Finished")
            wait(sender, lambda t: t["id"] == outgoing["id"] and t["state"] == "Finished")
            for path in map(Path, files):
                assert (destination / path.name).read_bytes() == path.read_bytes()
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=[files[0]])
            incoming2 = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            request(receiver, "decide", id=incoming2["id"], accept=False)
            wait(receiver, lambda t: t["id"] == incoming2["id"] and t["state"] == "Rejected")
            assert sorted(p.name for p in destination.iterdir()) == ["binary.dat", "empty.txt", "hello.txt"]
            assert request(receiver, "visibility", visible=False) is True
            assert request(receiver, "snapshot")["visible"] is False
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=[files[0]])
            incoming3 = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            request(receiver, "decide", id=incoming3["id"], accept=True)
            wait(receiver, lambda t: t["id"] == incoming3["id"] and t["state"] == "Finished")
            assert (destination / "1_hello.txt").read_bytes() == Path(files[0]).read_bytes()
            # A per-transfer folder must not change the default for later transfers.
            chosen = directory / "chosen folder"
            chosen.mkdir()
            (chosen / "hello.txt").write_bytes(b"keep existing")
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=[files[0]])
            incoming_chosen = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            request(receiver, "decide", id=incoming_chosen["id"], accept=True, directory=str(chosen))
            completed = wait(receiver, lambda t: t["id"] == incoming_chosen["id"] and t["state"] == "Finished")
            assert completed["meta"]["saved_files"] == [str(chosen / "1_hello.txt")]
            assert (chosen / "hello.txt").read_bytes() == b"keep existing"
            assert request(receiver, "resolve_path", id=incoming_chosen["id"], index=0, folder=False) == str(chosen / "1_hello.txt")
            assert request(receiver, "resolve_path", id=incoming_chosen["id"], index=0, folder=True) == str(chosen)
            assert request(receiver, "snapshot")["download_dir"] == str(destination)
            # Cancel before consent; neither endpoint may write another file.
            known_ids = {t["id"] for t in request(sender, "snapshot")["transfers"]}
            request(sender, "send", address=f"127.0.0.1:{receiver_port}", name="Receiver", paths=[files[0]])
            incoming4 = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            outbound4 = wait(sender, lambda t: t["id"] not in known_ids and t.get("meta") is not None)
            request(sender, "cancel", id=outbound4["id"])
            wait(sender, lambda t: t["id"] == outbound4["id"] and t["state"] == "Cancelled")
            wait(receiver, lambda t: t["id"] == incoming4["id"] and t["state"] == "Disconnected")
            assert not (destination / "2_hello.txt").exists()
            # Connection failures must be visible under the correct outgoing ID.
            known_ids = {t["id"] for t in request(sender, "snapshot")["transfers"]}
            request(sender, "send", address=f"127.0.0.1:{port()}", name="Offline", paths=[files[0]])
            wait(sender, lambda t: t["id"] not in known_ids and t["state"] == "Disconnected" and t["rtype"] == "Outbound")
            # Android-like delayed receiver completion: writing all bytes is not success.
            image = directory / "large-image.png"
            image.write_bytes(os.urandom(14 * 1024 * 1024))
            proxy_port, paused, release, proxy = delayed_completion_proxy(receiver_port)
            request(sender, "send", address=f"127.0.0.1:{proxy_port}", name="Receiver", paths=[str(image)])
            delayed_incoming = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            delayed_outgoing = wait(sender, lambda t: (t.get("meta") or {}).get("files") == [str(image)])
            paused.set()
            request(receiver, "decide", id=delayed_incoming["id"], accept=True)
            try:
                wait(receiver, lambda t: t["id"] == delayed_incoming["id"] and t["state"] == "Finished")
                sent = wait(sender, lambda t: t["id"] == delayed_outgoing["id"] and t["meta"]["ack_bytes"] == image.stat().st_size)
                assert sent["state"] == "SendingFiles", "sender closed before receiver confirmation"
                assert (destination / image.name).read_bytes() == image.read_bytes()
            finally:
                release.set()
            wait(sender, lambda t: t["id"] == delayed_outgoing["id"] and t["state"] == "Finished")
            proxy.join(10)
            assert not proxy.is_alive()
            # Real BYTE payloads for clipboard text and URLs, never temporary text files.
            for text in ("Hello 👻\nClipboard\x10 stays intact", "https://example.com/share?q=ghost", "é" * 300000):
                request(sender, "send_text", address=f"127.0.0.1:{receiver_port}", name="Receiver", text=text)
                incoming_text = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
                assert incoming_text["meta"]["files"] is None
                assert incoming_text["meta"]["total_bytes"] == len(text.encode())
                sender_text = wait(sender, lambda t: t["state"] == "SentIntroduction" and t["meta"].get("text_payload") == text)
                assert sender_text["meta"]["pin_code"] == incoming_text["meta"]["pin_code"]
                assert incoming_text["meta"]["text_payload"] is None, "text exposed before approval"
                request(receiver, "decide", id=incoming_text["id"], accept=True)
                received_text = wait(receiver, lambda t: t["id"] == incoming_text["id"] and t["state"] == "Finished")
                assert received_text["meta"]["text_payload"] == text
                assert request(receiver, "resolve_text", id=incoming_text["id"]) == text
                assert received_text["meta"]["text_type"] == ("Url" if text.startswith("https://") else "Text")
            request(sender, "send_text", address=f"127.0.0.1:{receiver_port}", name="Receiver", text="decline this clipboard")
            declined_text = wait(receiver, lambda t: t["state"] == "WaitingForUserConsent")
            request(receiver, "decide", id=declined_text["id"], accept=False)
            wait(receiver, lambda t: t["id"] == declined_text["id"] and t["state"] == "Rejected")
            for invalid in ("", "x" * (1024 * 1024 + 1), "bad\0text"):
                sender.send(dict(command="send_text", address=f"127.0.0.1:{receiver_port}", name="Receiver", text=invalid))
                assert sender.poll(12) and not sender.recv()["ok"]
            print("PASS: encrypted batches, empty files, matching PINs, consent, decline, cancellation, visibility, duplicate preservation, connection failures, clipboard text/URLs, Unicode, text consent and limits, 14 MB file with delayed receiver completion")
        finally:
            for connection in connections:
                connection.send(None)
            for process in processes:
                process.join(8)
                if process.is_alive():
                    process.terminate()
                    process.join()
                    raise AssertionError("engine failed to stop")
                assert process.exitcode == 0, process.exitcode

if __name__ == "__main__":
    main()
