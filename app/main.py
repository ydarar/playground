from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from app.auth.router import router as auth_router
from app.config import get_settings
from app.database import init_db
from app.routes.accounts import router as accounts_router
from app.routes.calendar import router as calendar_router
from app.routes.compose import router as compose_router
from app.routes.inbox import router as inbox_router


def create_app() -> FastAPI:
    settings = get_settings()

    app = FastAPI(
        title="Workspace Hub",
        description="Multi-account Google Workspace integration",
        version="0.1.0",
    )

    # Session middleware for OAuth state
    app.add_middleware(SessionMiddleware, secret_key=settings.app_secret_key)

    # Static files
    static_dir = Path(__file__).parent / "static"
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")

    # Routers
    app.include_router(auth_router)
    app.include_router(accounts_router)
    app.include_router(inbox_router)
    app.include_router(compose_router)
    app.include_router(calendar_router)

    @app.on_event("startup")
    async def startup():
        init_db()

    return app


app = create_app()

if __name__ == "__main__":
    import uvicorn

    settings = get_settings()
    uvicorn.run("app.main:app", host=settings.app_host, port=settings.app_port, reload=True)
