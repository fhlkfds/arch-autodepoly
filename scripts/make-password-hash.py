#!/usr/bin/env python3
"""Print a crypt(3) hash of a prompted password for group_vars/vault.yml.

Ansible's password_hash filter cannot emit yescrypt here: Python 3.13 dropped
the crypt module, so the filter falls back to passlib, which only offers
md5, blowfish, sha256 and sha512. libxcrypt does support yescrypt, so call it
directly and let it pick the salt.
"""

import argparse
import ctypes
import ctypes.util
import getpass
import os
import sys

PREFIXES = {"yescrypt": b"$y$", "sha512": b"$6$", "bcrypt": b"$2b$"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--method", choices=sorted(PREFIXES), default="yescrypt")
    return parser.parse_args()


def load_libcrypt() -> ctypes.CDLL:
    lib = ctypes.CDLL(ctypes.util.find_library("crypt") or "libcrypt.so.2")
    lib.crypt_gensalt.restype = ctypes.c_char_p
    lib.crypt_gensalt.argtypes = [
        ctypes.c_char_p,
        ctypes.c_ulong,
        ctypes.c_char_p,
        ctypes.c_int,
    ]
    lib.crypt.restype = ctypes.c_char_p
    lib.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    return lib


def hash_password(lib: ctypes.CDLL, password: str, method: str) -> str:
    entropy = os.urandom(32)
    salt = lib.crypt_gensalt(PREFIXES[method], 0, entropy, len(entropy))
    if not salt:
        sys.exit(f"libxcrypt does not support {method} on this host.")
    digest = lib.crypt(password.encode(), salt)
    if not digest or not digest.startswith(salt):
        sys.exit(f"libxcrypt refused to hash with {method}.")
    return digest.decode()


def main() -> None:
    args = parse_args()
    password = getpass.getpass("Password for liam: ")
    if password != getpass.getpass("Repeat: "):
        sys.exit("Passwords did not match.")
    if not password:
        sys.exit("Refusing to hash an empty password.")

    lib = load_libcrypt()
    digest = hash_password(lib, password, args.method)

    # Re-hashing against the returned digest must reproduce it exactly.
    if lib.crypt(password.encode(), digest.encode()).decode() != digest:
        sys.exit("Verification failed; the hash does not round-trip.")

    print(f"vault_liam_password_hash: '{digest}'")


if __name__ == "__main__":
    main()
