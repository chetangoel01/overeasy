import pytest

from scripts.restore_drill import run_restore_drill


@pytest.mark.integration
def test_real_postgres_backup_restores_into_an_empty_server() -> None:
    result = run_restore_drill()

    assert result["rowsRestored"] == 2
    assert result["sourceChecksum"] == result["restoredChecksum"]
    assert result["sourceVersion"] == result["restoredVersion"]
