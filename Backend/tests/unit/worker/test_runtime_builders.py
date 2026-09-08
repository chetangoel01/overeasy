"""The live builders take a Settings, which is not hashable, so they cannot be
memoised on their arguments; the orchestrator above them is the cached one.

Production found this the hard way: the worker's first import job after the
tag deploy would have died with `unhashable type: 'Settings'`.
"""

from ladle.config import Settings
from ladle.worker import runtime


def test_the_argument_taking_builders_are_not_memoised_on_settings() -> None:
    for builder in (runtime.runtime_acquirer, runtime.runtime_extractor):
        assert not hasattr(builder, "cache_info"), builder.__name__


def test_the_orchestrator_is_the_one_that_is_cached() -> None:
    assert hasattr(runtime.runtime_orchestrator, "cache_info")


def test_a_real_settings_object_is_not_hashable() -> None:
    # If this ever starts passing the other way, the guard above is moot.
    try:
        hash(Settings())
    except TypeError:
        return
    raise AssertionError("Settings became hashable; revisit the caching")
