from dataclasses import dataclass, field

from ladle.acquisition.models import AcquiredVideoContext
from ladle.recipes.template_clone import RecipeTemplate


@dataclass
class FakeExtractor:
    template: RecipeTemplate
    calls: list[AcquiredVideoContext] = field(default_factory=list)

    @property
    def contract_version(self) -> str:
        return "v1"

    @property
    def prompt_version(self) -> str:
        return "fake-recipe-v1"

    @property
    def model_id(self) -> str:
        return "fake-extractor"

    def extract(self, context: AcquiredVideoContext) -> RecipeTemplate:
        self.calls.append(context)
        return self.template
