"""Generate a Web Push VAPID key pair for the backend environment."""

import base64

from cryptography.hazmat.primitives.asymmetric import ec


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def main() -> None:
    private_key = ec.generate_private_key(ec.SECP256R1())
    numbers = private_key.private_numbers()
    private_bytes = numbers.private_value.to_bytes(32, "big")
    public_bytes = b"\x04" + numbers.public_numbers.x.to_bytes(32, "big")
    public_bytes += numbers.public_numbers.y.to_bytes(32, "big")

    print("PUSH_VAPID_PUBLIC_KEY=" + _base64url(public_bytes))
    print("PUSH_VAPID_PRIVATE_KEY=" + _base64url(private_bytes))
    print("PUSH_VAPID_SUBJECT=mailto:replace-with-your-contact-email@example.com")


if __name__ == "__main__":
    main()
