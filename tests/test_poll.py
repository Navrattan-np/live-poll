import main
from conftest import HOST, start_poll


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200 and r.json()["status"] == "ok"


def test_waiting_state_before_any_poll(client):
    s = client.get("/api/state").json()
    assert s["id"] == 0 and s["open"] is False and s["total"] == 0


def test_host_endpoints_require_key(client):
    body = {"question": "Q?", "options": ["a", "b"]}
    assert client.post("/api/host/start", json=body).status_code == 401
    assert client.post("/api/host/close", headers={"X-Host-Key": "nope"}).status_code == 401


def test_start_poll_validation(client):
    r = client.post("/api/host/start", json={"question": "Q?", "options": ["only one"]}, headers=HOST)
    assert r.status_code == 422


def test_vote_is_counted_and_tagged_with_server(client):
    start_poll(client)
    assert client.post("/api/vote", json={"client": "c1", "option": 1}).json()["result"] == "ok"
    s = client.get("/api/state").json()
    assert s["counts"] == [0, 1, 0] and s["total"] == 1
    assert s["servers"] == {main.INSTANCE: 1}


def test_one_vote_per_client(client):
    start_poll(client)
    client.post("/api/vote", json={"client": "c1", "option": 0})
    again = client.post("/api/vote", json={"client": "c1", "option": 2}).json()["result"]
    assert again == "already_voted" and client.get("/api/state").json()["total"] == 1


def test_vote_rejected_when_closed_or_invalid(client):
    start_poll(client)
    assert client.post("/api/vote", json={"client": "c1", "option": 9}).json()["result"] == "bad_option"
    client.post("/api/host/close", headers=HOST)
    assert client.post("/api/vote", json={"client": "c2", "option": 0}).json()["result"] == "closed"


def test_new_poll_resets_counts_and_gets_new_id(client):
    first = start_poll(client)
    client.post("/api/vote", json={"client": "c1", "option": 0})
    second = start_poll(client)
    assert second != first and client.get("/api/state").json()["total"] == 0


def test_websocket_receives_live_update(client):
    start_poll(client)
    with client.websocket_connect("/ws") as ws:
        assert ws.receive_json()["type"] == "hello"
        assert ws.receive_json()["type"] == "state"
        client.post("/api/vote", json={"client": "c1", "option": 1})
        for _ in range(5):
            msg = ws.receive_json()
            if msg.get("total") == 1:
                break
        assert msg["total"] == 1 and msg["counts"][1] == 1


def test_websocket_vote_gets_ack(client):
    start_poll(client)
    with client.websocket_connect("/ws") as ws:
        ws.send_json({"type": "vote", "client": "phone-1", "option": 0})
        for _ in range(6):
            msg = ws.receive_json()
            if msg["type"] == "ack":
                break
        assert msg["result"] == "ok"


def test_join_alternates_between_servers(client, monkeypatch):
    monkeypatch.setattr(main, "PEERS", ["https://a.example", "https://b.example"])
    hits = [client.get("/join", follow_redirects=False).headers["location"] for _ in range(4)]
    assert set(hits) == {"https://a.example/", "https://b.example/"} and hits[0] != hits[1]


def test_pages_are_served(client):
    for path in ("/", "/host", "/screen"):
        r = client.get(path)
        assert r.status_code == 200 and "LivePoll" in r.text
