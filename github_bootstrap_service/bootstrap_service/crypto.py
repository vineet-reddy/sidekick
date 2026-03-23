from __future__ import annotations

import base64
import hashlib
import secrets


def _xor_stream(payload: bytes, secret: str, nonce: bytes) -> bytes:
    key = secret.encode("utf-8")
    output = bytearray()
    counter = 0
    cursor = 0

    while cursor < len(payload):
        digest = hashlib.sha256(key + nonce + counter.to_bytes(8, "big")).digest()
        for byte in digest:
            if cursor >= len(payload):
                break
            output.append(payload[cursor] ^ byte)
            cursor += 1
        counter += 1

    return bytes(output)


def encrypt_text(value: str, secret: str) -> str:
    nonce = secrets.token_bytes(16)
    ciphertext = _xor_stream(value.encode("utf-8"), secret, nonce)
    return base64.urlsafe_b64encode(nonce + ciphertext).decode("ascii")


def decrypt_text(value: str, secret: str) -> str:
    decoded = base64.urlsafe_b64decode(value.encode("ascii"))
    nonce = decoded[:16]
    ciphertext = decoded[16:]
    return _xor_stream(ciphertext, secret, nonce).decode("utf-8")
