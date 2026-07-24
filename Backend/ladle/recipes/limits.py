from dataclasses import dataclass
from uuid import UUID

from sqlalchemy import exists, func, select
from sqlalchemy.orm import Session

from ladle.db.models import ImportJob, Recipe, RecipeSlotReservation, User

GUEST_RECIPE_LIMIT = 10


class GuestRecipeLimitReached(Exception):
    pass


@dataclass(frozen=True)
class RecipeCapacity:
    user: User
    saved_recipes: int
    active_reservations: int

    @property
    def occupied_slots(self) -> int:
        return self.saved_recipes + self.active_reservations


def lock_recipe_capacity(database: Session, user_id: UUID) -> RecipeCapacity:
    user = database.execute(
        select(User).where(User.id == user_id).with_for_update()
    ).scalar_one()
    saved = database.scalar(
        select(func.count())
        .select_from(Recipe)
        .where(
            Recipe.user_id == user_id,
            Recipe.deleted_at.is_(None),
            ~exists(
                select(ImportJob.id).where(ImportJob.candidate_recipe_id == Recipe.id)
            ),
        )
    )
    reserved = database.scalar(
        select(func.count())
        .select_from(RecipeSlotReservation)
        .where(
            RecipeSlotReservation.user_id == user_id,
            RecipeSlotReservation.state == "reserved",
        )
    )
    return RecipeCapacity(
        user=user,
        saved_recipes=int(saved or 0),
        active_reservations=int(reserved or 0),
    )


def ensure_recipe_capacity(database: Session, user_id: UUID) -> RecipeCapacity:
    capacity = lock_recipe_capacity(database, user_id)
    if capacity.user.kind == "guest" and capacity.occupied_slots >= GUEST_RECIPE_LIMIT:
        raise GuestRecipeLimitReached
    return capacity
