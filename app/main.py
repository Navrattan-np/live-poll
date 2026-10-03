"""Live polling: WebSocket servers kept in sync through Redis pub/sub.

Any number of identical instances can run. A vote received by one instance is stored in
Redis and published on a channel; every instance relays it to its own connected browsers.
"""
import asyncio
import itertools
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated

from fastapi import FastAPI, Header, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, RedirectResponse
from pydantic import BaseModel, Field, StringConstraints

from store import make_redis

INSTANCE = os.environ.get("INSTANCE_NAME", "local")
HOST_KEY = os.environ.get("HOST_KEY", "host")
PEERS = [p.strip().rstrip("/") for p in os.environ.get("PEERS", "").split(",") if p.strip()]
CHANNEL = "poll:events"
BASE = Path(__file__).parent
QUESTIONS = json.loads((BASE / "questions.json").read_text())
_rr = itertools.count()


# ---------- local websocket fan-out ----------
class Hub:
    def __init__(self):
        self.clients = set()

    async def broadcast(self, text):
        for ws in list(self.clients):
            try:
                await ws.send_text(text)
            except Exception:
                self.clients.discard(ws)


hub = Hub()


# ---------- redis state ----------
EMPTY = {"type": "state", "id": 0, "question": "Waiting for the host…", "options": [],
         "counts": [], "total": 0, "open": False, "servers": {}}


async def snapshot(r):
    raw = await r.get("poll:current")
    if not raw:
        return EMPTY
    poll = json.loads(raw)
    votes = await r.hgetall(f"poll:votes:{poll['id']}")
    counts = [int(votes.get(str(i), 0)) for i in range(len(poll["options"]))]
    servers = {k: int(v) for k, v in (await r.hgetall(f"poll:servers:{poll['id']}")).items()}
    return {"type": "state", **poll, "counts": counts, "total": sum(counts), "servers": servers}


async def publish(r):
    await r.publish(CHANNEL, json.dumps(await snapshot(r)))


async def cast_vote(r, client_id, option):
    raw = await r.get("poll:current")
    if not raw:
        return "no_poll"
    poll = json.loads(raw)
    if not poll["open"]:
        return "closed"
    if not client_id:
        return "bad_client"
    if not 0 <= option < len(poll["options"]):
        return "bad_option"
    if not await r.sadd(f"poll:voters:{poll['id']}", client_id):  # atomic: one vote per client
        return "already_voted"
    await r.hincrby(f"poll:votes:{poll['id']}", str(option), 1)
    await r.hincrby(f"poll:servers:{poll['id']}", INSTANCE, 1)  # which server took the vote
    await publish(r)
    return "ok"


async def listen(app):
    """Relay every published snapshot to this instance's websocket clients (auto-reconnects)."""
    while True:
        try:
            pubsub = app.state.redis.pubsub()
            await pubsub.subscribe(CHANNEL)
            async for msg in pubsub.listen():
                if msg["type"] == "message":
                    await hub.broadcast(msg["data"])
        except asyncio.CancelledError:
            raise
        except Exception:
            await asyncio.sleep(1)


@asynccontextmanager
async def lifespan(app):
    app.state.redis = make_redis()
    task = asyncio.create_task(listen(app))
    yield
    task.cancel()
    await app.state.redis.aclose()


app = FastAPI(title="LivePoll", lifespan=lifespan)


# ---------- pages ----------
def page():
    return FileResponse(BASE / "static" / "index.html")


for route in ("/", "/host", "/screen"):
    app.add_api_route(route, page, methods=["GET"], include_in_schema=False)


@app.get("/join", include_in_schema=False)
def join():
    """Entry link for the QR code: round-robin phones across all instances."""
    if not PEERS:
        return RedirectResponse("/")
    return RedirectResponse(PEERS[next(_rr) % len(PEERS)] + "/")


# ---------- api ----------
@app.get("/health")
def health():
    return {"status": "ok", "server": INSTANCE}


@app.get("/api/state")
async def state():
    return await snapshot(app.state.redis)


@app.get("/api/questions")
def questions():
    return QUESTIONS


class Vote(BaseModel):
    client: str = Field(min_length=1, max_length=64)
    option: int


@app.post("/api/vote")
async def vote(v: Vote):
    return {"result": await cast_vote(app.state.redis, v.client, v.option)}


Text = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=140)]


class NewPoll(BaseModel):
    question: Text
    options: list[Text] = Field(min_length=2, max_length=4)


def check_key(key):
    if key != HOST_KEY:
        raise HTTPException(401, "bad host key")


@app.post("/api/host/start")
async def host_start(p: NewPoll, x_host_key: str = Header(default="")):
    check_key(x_host_key)
    r = app.state.redis
    pid = await r.incr("poll:seq")
    await r.set("poll:current", json.dumps(
        {"id": pid, "question": p.question, "options": p.options, "open": True}))
    await publish(r)
    return {"id": pid}


@app.post("/api/host/close")
async def host_close(x_host_key: str = Header(default="")):
    check_key(x_host_key)
    r = app.state.redis
    raw = await r.get("poll:current")
    if raw:
        await r.set("poll:current", json.dumps({**json.loads(raw), "open": False}))
        await publish(r)
    return {"ok": True}


@app.post("/api/host/reset")
async def host_reset(x_host_key: str = Header(default="")):
    check_key(x_host_key)
    r = app.state.redis
    async for key in r.scan_iter(match="poll:*"):
        if key != "poll:seq":  # keep the counter so poll ids never repeat
            await r.delete(key)
    await publish(r)
    return {"ok": True}


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    r = ws.app.state.redis
    hub.clients.add(ws)
    try:
        await ws.send_json({"type": "hello", "server": INSTANCE})
        await ws.send_json(await snapshot(r))
        while True:
            msg = await ws.receive_json()
            if isinstance(msg, dict) and msg.get("type") == "vote":
                try:
                    result = await cast_vote(r, str(msg.get("client", ""))[:64], int(msg.get("option", -1)))
                except (TypeError, ValueError):
                    result = "bad_option"
                await ws.send_json({"type": "ack", "result": result})
    except WebSocketDisconnect:
        pass
    finally:
        hub.clients.discard(ws)
