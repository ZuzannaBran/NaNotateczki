import asyncio
import json
from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect

from ..database import session_factory
from ..models import User
from ..realtime_hub import hub
from ..security import decode_access_token_claims
from ..settings import get_settings


router = APIRouter(tags=["realtime"])


@router.websocket("/v1/realtime")
async def realtime(websocket: WebSocket) -> None:
    settings = get_settings()
    if websocket.headers.get("origin") != str(settings.app_origin).rstrip("/"):
        await websocket.close(code=4403)
        return
    await websocket.accept()
    try:
        raw = await asyncio.wait_for(websocket.receive_text(), timeout=5)
        message = json.loads(raw)
        if message.get("type") != "authenticate" or not isinstance(
            message.get("token"), str
        ):
            await websocket.close(code=4401)
            return
        user_id, expires_at = decode_access_token_claims(message["token"])
        async with session_factory() as session:
            if await session.get(User, user_id) is None:
                await websocket.close(code=4401)
                return
        queue = await hub.subscribe(user_id)
        await websocket.send_json({"type": "authenticated"})
        try:
            while True:
                if datetime.now(UTC) >= expires_at:
                    await websocket.close(code=4401)
                    return
                event = await asyncio.wait_for(queue.get(), timeout=25)
                await websocket.send_json(event)
        except TimeoutError:
            await websocket.send_json({"type": "ping"})
            while True:
                if datetime.now(UTC) >= expires_at:
                    await websocket.close(code=4401)
                    return
                try:
                    event = await asyncio.wait_for(queue.get(), timeout=25)
                    await websocket.send_json(event)
                except TimeoutError:
                    await websocket.send_json({"type": "ping"})
        finally:
            await hub.unsubscribe(user_id, queue)
    except (
        WebSocketDisconnect,
        asyncio.TimeoutError,
        json.JSONDecodeError,
        HTTPException,
    ):
        await websocket.close(code=4401)
