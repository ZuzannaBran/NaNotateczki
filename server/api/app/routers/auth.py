import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy import select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..database import database_session
from ..models import RefreshSession, User
from ..rate_limit import auth_limiter
from ..schemas import (
    ChangePasswordRequest,
    Credentials,
    RefreshRequest,
    RegistrationCredentials,
)
from ..security import (
    create_access_token,
    create_refresh_session,
    current_user,
    dummy_password_hash,
    hash_password,
    rotate_refresh_session,
    token_digest,
    verify_password,
)
from ..settings import get_settings


router = APIRouter(prefix="/v1/auth", tags=["auth"])


def session_response(user: User, refresh_token: str) -> dict:
    access_token, expires_in = create_access_token(user.id)
    return {
        "accessToken": access_token,
        "refreshToken": refresh_token,
        "expiresIn": expires_in,
        "userId": str(user.id),
        "email": user.email,
    }


async def limit_auth(request: Request, email: str) -> None:
    client = request.client.host if request.client else "unknown"
    await auth_limiter.check(f"ip:{client}")
    await auth_limiter.check(f"account:{email.lower()}")


@router.post("/register", status_code=201)
async def register(
    credentials: RegistrationCredentials,
    request: Request,
    session: AsyncSession = Depends(database_session),
) -> dict:
    settings = get_settings()
    if not settings.allow_registration:
        raise HTTPException(status_code=403, detail="Registration is disabled.")
    email = credentials.email.lower()
    await limit_auth(request, email)
    user = User(
        id=uuid.uuid4(),
        email=email,
        password_hash=hash_password(credentials.password),
    )
    session.add(user)
    refresh_token, _ = await create_refresh_session(session, user.id)
    try:
        await session.commit()
    except IntegrityError as error:
        await session.rollback()
        raise HTTPException(status_code=409, detail="Account already exists.") from error
    return session_response(user, refresh_token)


@router.post("/login")
async def login(
    credentials: Credentials,
    request: Request,
    session: AsyncSession = Depends(database_session),
) -> dict:
    email = credentials.email.lower()
    await limit_auth(request, email)
    result = await session.execute(select(User).where(User.email == email))
    user = result.scalar_one_or_none()
    encoded_hash = user.password_hash if user is not None else dummy_password_hash
    password_valid = verify_password(credentials.password, encoded_hash)
    if user is None or not password_valid:
        raise HTTPException(status_code=401, detail="Invalid e-mail or password.")
    refresh_token, _ = await create_refresh_session(session, user.id)
    await session.commit()
    return session_response(user, refresh_token)


@router.post("/refresh")
async def refresh(
    request: RefreshRequest,
    session: AsyncSession = Depends(database_session),
) -> dict:
    user, refresh_token = await rotate_refresh_session(session, request.refreshToken)
    await session.commit()
    return session_response(user, refresh_token)


@router.post("/logout", status_code=204)
async def logout(
    request: RefreshRequest,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(database_session),
) -> None:
    result = await session.execute(
        select(RefreshSession).where(
            RefreshSession.token_hash == token_digest(request.refreshToken),
            RefreshSession.owner_id == user.id,
        )
    )
    record = result.scalar_one_or_none()
    if record is not None and record.revoked_at is None:
        record.revoked_at = datetime.now(UTC)
        await session.commit()


@router.post("/change-password", status_code=204)
async def change_password(
    request: ChangePasswordRequest,
    user: User = Depends(current_user),
    session: AsyncSession = Depends(database_session),
) -> None:
    if not verify_password(request.currentPassword, user.password_hash):
        raise HTTPException(status_code=400, detail="Current password is incorrect.")
    user.password_hash = hash_password(request.newPassword)
    await session.execute(
        update(RefreshSession)
        .where(RefreshSession.owner_id == user.id)
        .values(revoked_at=datetime.now(UTC))
    )
    await session.commit()


@router.get("/me")
async def me(user: User = Depends(current_user)) -> dict:
    return {"userId": str(user.id), "email": user.email}
