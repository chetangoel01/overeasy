from typing import cast

from fastapi import Request
from sqlalchemy.orm import Session

from ladle.clock import Clock


def database(request: Request) -> Session:
    return cast(Session, request.app.state.session_factory())


def clock(request: Request) -> Clock:
    return cast(Clock, request.app.state.clock)
