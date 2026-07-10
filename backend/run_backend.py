from __future__ import annotations

import multiprocessing

import uvicorn

from app.config import settings
from app.main import app


def main() -> None:
    uvicorn.run(
        app,
        host=settings.host,
        port=settings.port,
        log_level="warning",
        access_log=False,
    )


if __name__ == "__main__":
    multiprocessing.freeze_support()
    main()
