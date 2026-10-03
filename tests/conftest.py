import os

os.environ["REDIS_URL"] = "fakeredis://"  # in-memory Redis for unit tests

import pytest
from fastapi.testclient import TestClient

import main

HOST = {"X-Host-Key": "host"}


@pytest.fixture
def client():
    with TestClient(main.app) as c:
        c.post("/api/host/reset", headers=HOST)
        yield c


def start_poll(c, options=("a", "b", "c")):
    r = c.post("/api/host/start", json={"question": "Best?", "options": list(options)}, headers=HOST)
    assert r.status_code == 200
    return r.json()["id"]
