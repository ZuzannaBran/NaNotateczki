import uuid

import pytest
from fastapi import HTTPException

from app.security import (
    create_access_token,
    decode_access_token,
    hash_password,
    token_digest,
    verify_password,
)


def test_password_is_argon2_and_plaintext_is_not_stored() -> None:
    encoded = hash_password("correct horse battery staple")

    assert encoded.startswith("$argon2")
    assert "correct horse battery staple" not in encoded
    assert verify_password("correct horse battery staple", encoded)
    assert not verify_password("wrong password", encoded)


def test_access_token_is_bound_to_user_and_type() -> None:
    user_id = uuid.uuid4()
    token, expires_in = create_access_token(user_id)

    assert expires_in == 600
    assert decode_access_token(token) == user_id

    with pytest.raises(HTTPException):
        decode_access_token(token + "tampered")


def test_refresh_token_digest_is_one_way_and_deterministic() -> None:
    token = "opaque-refresh-token"
    assert token_digest(token) == token_digest(token)
    assert token not in token_digest(token)
    assert len(token_digest(token)) == 64
