from typing import Protocol
from uuid import UUID

from ladle.acquisition.models import AcquiredVideoContext
from ladle.recipes.template_clone import RecipeTemplate


class RecipeExtractor(Protocol):
    @property
    def contract_version(self) -> str: ...

    @property
    def prompt_version(self) -> str: ...

    @property
    def model_id(self) -> str: ...

    def extract(
        self,
        context: AcquiredVideoContext,
        *,
        job_id: UUID,
    ) -> RecipeTemplate: ...
