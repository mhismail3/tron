"""Tests for model warmup and readiness endpoints."""
from __future__ import annotations

import threading
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def mock_config():
    """Mock configuration for tests."""
    with patch("services.transcribe.app.get_config") as mock:
        config = MagicMock()
        config.backend = "parakeet-mlx"
        config.model_name = "mlx-community/parakeet-tdt-0.6b-v3"
        config.device = "mlx"
        config.compute_type = "mlx"
        config.host = "127.0.0.1"
        config.port = 8787
        config.tmp_dir = "/tmp/transcribe"
        config.models_dir = "/tmp/models"
        config.logs_dir = "/tmp/logs"
        mock.return_value = config
        yield config


@pytest.fixture
def app(mock_config):
    """Create app instance for testing."""
    # Reset warmup state before each test
    from services.transcribe import app as app_module

    app_module.reset_warmup_state()

    # Return the FastAPI app
    return app_module.app


@pytest.fixture
def client(app):
    """TestClient with default app state."""
    return TestClient(app)


class TestHealthEndpoint:
    """Tests for /health endpoint with warmup status."""

    def test_health_returns_warmup_state(self, client):
        """Health endpoint should include warmup state."""
        response = client.get("/health")
        assert response.status_code == 200
        data = response.json()
        assert "warmup" in data
        assert "started" in data["warmup"]
        assert "completed" in data["warmup"]
        assert "error" in data["warmup"]

    def test_health_always_returns_200(self, client):
        """Health should return 200 even during warmup (liveness check)."""
        response = client.get("/health")
        assert response.status_code == 200


class TestReadyEndpoint:
    """Tests for /ready endpoint (readiness check)."""

    def test_ready_returns_503_before_warmup_completes(self, app):
        """Ready should return 503 if model not yet loaded."""
        from services.transcribe import app as app_module

        app_module.reset_warmup_state()
        client = TestClient(app, raise_server_exceptions=False)

        response = client.get("/ready")
        assert response.status_code == 503
        assert "not yet loaded" in response.json()["detail"]

    def test_ready_returns_200_after_warmup_completes(self, app):
        """Ready should return 200 after model loaded."""
        from services.transcribe import app as app_module

        app_module.set_warmup_completed()
        client = TestClient(app)

        response = client.get("/ready")
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "ready"
        assert data["model_loaded"] is True

    def test_ready_returns_503_on_warmup_error(self, app):
        """Ready should return 503 with error details if warmup failed."""
        from services.transcribe import app as app_module

        app_module.set_warmup_error("Model download failed")
        client = TestClient(app, raise_server_exceptions=False)

        response = client.get("/ready")
        assert response.status_code == 503
        assert "failed" in response.json()["detail"].lower()


class TestWarmupEndpoint:
    """Tests for /warmup endpoint (manual warmup trigger)."""

    def test_warmup_triggers_model_load(self, client):
        """POST /warmup should trigger model loading."""
        with patch("services.transcribe.engine._load_model") as mock_load:
            mock_load.return_value = MagicMock()
            response = client.post("/warmup")
            assert response.status_code == 200
            mock_load.assert_called_once()

    def test_warmup_returns_already_loaded_if_cached(self, app):
        """Warmup should return quickly if model already loaded."""
        from services.transcribe import app as app_module
        from services.transcribe import engine

        # Add a model to the cache
        key = ("parakeet-mlx", "mlx-community/parakeet-tdt-0.6b-v3", "mlx", "mlx")
        engine._MODEL_CACHE[key] = MagicMock()

        try:
            app_module.set_warmup_completed()
            client = TestClient(app)

            response = client.post("/warmup")
            assert response.status_code == 200
            assert response.json()["already_loaded"] is True
        finally:
            # Clean up
            engine._MODEL_CACHE.pop(key, None)

    def test_warmup_accepts_custom_backend(self, client):
        """Warmup should accept backend parameter."""
        with patch("services.transcribe.engine._load_model") as mock_load:
            mock_load.return_value = MagicMock()
            response = client.post("/warmup", json={"backend": "parakeet-mlx"})
            assert response.status_code == 200


class TestWarmupState:
    """Tests for warmup state management."""

    def test_warmup_state_thread_safety(self):
        """Warmup state access should be thread-safe."""
        from services.transcribe.app import get_warmup_state

        results = []

        def read_state():
            for _ in range(100):
                state = get_warmup_state()
                results.append(state)

        threads = [threading.Thread(target=read_state) for _ in range(10)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert len(results) == 1000  # All reads completed

    def test_reset_warmup_state(self):
        """reset_warmup_state should clear all state."""
        from services.transcribe.app import (
            get_warmup_state,
            reset_warmup_state,
            set_warmup_completed,
        )

        set_warmup_completed()
        state = get_warmup_state()
        assert state["completed"] is True

        reset_warmup_state()
        state = get_warmup_state()
        assert state["started"] is False
        assert state["completed"] is False
        assert state["error"] is None

    def test_set_warmup_error_preserves_started(self):
        """set_warmup_error should keep started=True."""
        from services.transcribe.app import (
            get_warmup_state,
            reset_warmup_state,
            set_warmup_error,
        )

        reset_warmup_state()
        set_warmup_error("Test error")

        state = get_warmup_state()
        assert state["started"] is True
        assert state["completed"] is False
        assert state["error"] == "Test error"


class TestStatusEndpoint:
    """Tests for /status endpoint (detailed debugging info)."""

    def test_status_returns_detailed_info(self, app):
        """Status should return warmup state, config, and loaded models."""
        from services.transcribe import app as app_module

        app_module.set_warmup_completed()
        client = TestClient(app)

        response = client.get("/status")
        assert response.status_code == 200
        data = response.json()

        assert "warmup" in data
        assert "config" in data
        assert "models_loaded" in data
        assert "uptime_seconds" in data
        assert "timestamp" in data
