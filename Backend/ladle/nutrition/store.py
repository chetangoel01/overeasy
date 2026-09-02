"""Local storage for the raw FoodData Central responses the app depends on.

USDA is treated as the source of record, not the lookup path. Every response
that arrives is kept verbatim and consulted first on the next import, so the
common case — the same pantry staples appearing in recipe after recipe — costs
no network at all, and a USDA outage or quota exhaustion only affects
ingredients nobody has looked up before.

Payloads are stored exactly as received. Parsing, validation and ranking all
happen on read, so a correction to any of those reaches the whole store rather
than only what is fetched from then on.
"""

from datetime import datetime
from typing import Protocol

from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session, sessionmaker

from ladle.db.models import USDAFood, USDASearch


class USDAPayloadStore(Protocol):
    def search(self, query: str) -> dict[str, object] | None: ...

    def save_search(self, query: str, payload: dict[str, object]) -> None: ...

    def food(self, fdc_id: int) -> dict[str, object] | None: ...

    def save_food(self, fdc_id: int, payload: dict[str, object]) -> None: ...


class DatabaseUSDAPayloadStore:
    """Reads and writes USDA payloads in their own short transactions.

    Never joins the caller's transaction: a nutrition lookup happens in the
    middle of an import, and a cache write has no business extending — or
    failing — that unit of work.
    """

    def __init__(self, *, session_factory: sessionmaker[Session]) -> None:
        self._sessions = session_factory

    def search(self, query: str) -> dict[str, object] | None:
        with self._sessions() as session:
            row = session.get(USDASearch, query)
            return dict(row.payload) if row is not None else None

    def save_search(self, query: str, payload: dict[str, object]) -> None:
        self._upsert(
            USDASearch,
            {"query": query, "payload": payload},
            index_elements=["query"],
        )

    def food(self, fdc_id: int) -> dict[str, object] | None:
        with self._sessions() as session:
            row = session.get(USDAFood, fdc_id)
            return dict(row.payload) if row is not None else None

    def save_food(self, fdc_id: int, payload: dict[str, object]) -> None:
        self._upsert(
            USDAFood,
            {"fdc_id": fdc_id, "payload": payload},
            index_elements=["fdc_id"],
        )

    def _upsert(
        self,
        table: type[USDAFood] | type[USDASearch],
        values: dict[str, object],
        *,
        index_elements: list[str],
    ) -> None:
        # Workers import concurrently and will race for the same staple.
        # Refreshing the payload on conflict keeps the newest response without
        # either writer failing.
        statement = insert(table).values(**values)
        session: Session
        with self._sessions() as session:
            session.execute(
                statement.on_conflict_do_update(
                    index_elements=index_elements,
                    set_={
                        "payload": statement.excluded.payload,
                        "fetched_at": datetime.now().astimezone(),
                    },
                )
            )
            session.commit()
