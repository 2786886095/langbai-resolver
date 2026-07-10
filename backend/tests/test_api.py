from fastapi.testclient import TestClient

from app.main import app


client = TestClient(app)


def test_health() -> None:
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_rejects_localhost() -> None:
    response = client.post(
        "/api/v1/resolve", json={"url": "http://127.0.0.1/private"}
    )
    assert response.status_code == 400


def test_update_manifest_has_all_primary_clients() -> None:
    response = client.get("/api/v1/update")
    assert response.status_code == 200
    payload = response.json()
    assert payload["version"] == "1.0.0"
    assert {"windows", "android", "ios", "web"}.issubset(payload["platforms"])
