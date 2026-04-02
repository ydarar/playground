from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    google_client_id: str = ""
    google_client_secret: str = ""
    app_secret_key: str = "dev-secret-change-me"
    fernet_key: str = ""
    app_host: str = "127.0.0.1"
    app_port: int = 8000
    app_base_url: str = "http://localhost:8000"
    database_url: str = f"sqlite:///{Path(__file__).parent.parent / 'data' / 'app.db'}"

    # Google OAuth scopes
    google_scopes: list[str] = [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/calendar.events",
    ]

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}


@lru_cache
def get_settings() -> Settings:
    return Settings()
