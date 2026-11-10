"""Which certificate-URL shapes does trustd fetch on this macOS?

Temporary diagnostic for frostney/lwpt#411. For each URL shape it issues a
leaf (test PKI from packages/httpclient/source/fixtures) whose caIssuers URL
has that shape, evaluates it with Security.framework the way the client's
system-plus-anchors pass does (network fetch allowed), and reports whether a
local listener saw the request. A second evaluation with network fetch
disabled must never be seen.

Usage: python3 trustd-probe.py <fixtures-dir> <work-dir>
"""

import ctypes
import ctypes.util
import os
import socket
import subprocess
import sys
import threading
import time

FIXTURES, WORK = sys.argv[1], sys.argv[2]
os.makedirs(WORK, exist_ok=True)

VARIANTS = [
    ("A", "http://127.0.0.1:6741/A.crt"),  # current fixture shape
    ("B", "http://localhost:6741/B.crt"),
    ("C", "http://127.0.0.1/C.crt"),
    ("D", "http://localhost/D.crt"),
    ("E", "http://[::1]:6741/E.crt"),
    ("F", "http://localtest.me:6741/F.crt"),  # public name resolving to 127.0.0.1
]

seen = []
seen_lock = threading.Lock()


def serve(family, host, port):
    s = socket.socket(family, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    try:
        s.bind((host, port))
    except OSError as e:
        print(f"listener {host}:{port} unavailable: {e}")
        return
    s.listen(16)
    print(f"listening {host}:{port}")

    def loop():
        while True:
            c, peer = s.accept()
            c.settimeout(2)
            data = b""
            try:
                while b"\r\n\r\n" not in data:
                    chunk = c.recv(4096)
                    if not chunk:
                        break
                    data += chunk
            except OSError:
                pass
            line = data.split(b"\r\n", 1)[0].decode("latin-1")
            with seen_lock:
                seen.append((port, peer[0], line))
            c.sendall(b"HTTP/1.1 404 Not Found\r\nCache-Control: no-store\r\n"
                      b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            c.close()

    threading.Thread(target=loop, daemon=True).start()


for port in (6741, 80):
    serve(socket.AF_INET, "0.0.0.0", port)
    serve(socket.AF_INET6, "::", port)


def run(*args):
    subprocess.run(args, check=True, capture_output=True)


CNF = """[req]
distinguished_name = leaf_name
prompt = no
[leaf_name]
CN = localhost
[leaf_extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
authorityInfoAccess = caIssuers;URI:{url}
"""

leaves = {}
for name, url in VARIANTS:
    cnf = os.path.join(WORK, f"{name}.cnf")
    with open(cnf, "w") as f:
        f.write(CNF.format(url=url))
    csr = os.path.join(WORK, f"{name}.csr")
    der = os.path.join(WORK, f"{name}.der")
    run("openssl", "req", "-new", "-key",
        os.path.join(FIXTURES, "localhost-test-leaf-key.pem"),
        "-config", cnf, "-out", csr)
    run("openssl", "x509", "-req", "-in", csr,
        "-CA", os.path.join(FIXTURES, "unreachable-aia-intermediate-cert.pem"),
        "-CAkey", os.path.join(FIXTURES, "unreachable-aia-intermediate-key.pem"),
        "-set_serial", "0x7f%02x" % ord(name), "-days", "30", "-sha256",
        "-extfile", cnf, "-extensions", "leaf_extensions",
        "-outform", "DER", "-out", der)
    leaves[name] = open(der, "rb").read()

root_der = os.path.join(WORK, "root.der")
run("openssl", "x509", "-in", os.path.join(FIXTURES, "test-root-cert.pem"),
    "-outform", "DER", "-out", root_der)
root = open(root_der, "rb").read()

cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
sec = ctypes.CDLL(ctypes.util.find_library("Security"))
vp = ctypes.c_void_p
cf.CFDataCreate.restype = vp
cf.CFDataCreate.argtypes = [vp, ctypes.c_char_p, ctypes.c_long]
cf.CFArrayCreate.restype = vp
cf.CFArrayCreate.argtypes = [vp, ctypes.POINTER(vp), ctypes.c_long, vp]
cf.CFStringCreateWithCString.restype = vp
cf.CFStringCreateWithCString.argtypes = [vp, ctypes.c_char_p, ctypes.c_uint32]
cf.CFErrorGetCode.restype = ctypes.c_long
cf.CFErrorGetCode.argtypes = [vp]
callbacks = vp.in_dll(cf, "kCFTypeArrayCallBacks")
sec.SecCertificateCreateWithData.restype = vp
sec.SecCertificateCreateWithData.argtypes = [vp, vp]
sec.SecPolicyCreateSSL.restype = vp
sec.SecPolicyCreateSSL.argtypes = [ctypes.c_bool, vp]
sec.SecTrustCreateWithCertificates.argtypes = [vp, vp, ctypes.POINTER(vp)]
sec.SecTrustSetAnchorCertificates.argtypes = [vp, vp]
sec.SecTrustSetAnchorCertificatesOnly.argtypes = [vp, ctypes.c_bool]
sec.SecTrustSetNetworkFetchAllowed.argtypes = [vp, ctypes.c_bool]
sec.SecTrustEvaluateWithError.restype = ctypes.c_bool
sec.SecTrustEvaluateWithError.argtypes = [vp, ctypes.POINTER(vp)]


def certificate(der):
    data = cf.CFDataCreate(None, der, len(der))
    return sec.SecCertificateCreateWithData(None, data)


def array(items):
    arr = (vp * len(items))(*items)
    return cf.CFArrayCreate(None, arr, len(items),
                            ctypes.addressof(callbacks))


anchors = array([certificate(root)])
host = cf.CFStringCreateWithCString(None, b"localhost", 0x08000100)


def evaluate(der, fetch):
    trust = vp()
    policy = sec.SecPolicyCreateSSL(True, host)
    assert sec.SecTrustCreateWithCertificates(
        array([certificate(der)]), policy, ctypes.byref(trust)) == 0
    sec.SecTrustSetAnchorCertificates(trust, anchors)
    sec.SecTrustSetAnchorCertificatesOnly(trust, not fetch)
    sec.SecTrustSetNetworkFetchAllowed(trust, fetch)
    err = vp()
    started = time.monotonic()
    ok = sec.SecTrustEvaluateWithError(trust, ctypes.byref(err))
    elapsed = int((time.monotonic() - started) * 1000)
    code = cf.CFErrorGetCode(err) if err.value else 0
    return ok, code, elapsed


def requests_for(name):
    with seen_lock:
        return [s for s in seen if f"/{name}.crt" in s[2]]


print("variant url fetch ok code ms requests")
for name, url in VARIANTS:
    for fetch in (False, True):
        before = len(requests_for(name))
        ok, code, ms = evaluate(leaves[name], fetch)
        time.sleep(0.5)
        got = requests_for(name)[before:]
        print(f"{name} {url} fetch={fetch} ok={ok} code={code} {ms}ms "
              f"requests={len(got)} {got}")
with seen_lock:
    print("all requests:", seen)
