from ladle.api.app import create_app
from ladle.config import Settings


def test_development_swagger_describes_the_import_pipeline() -> None:
    application = create_app(
        settings=Settings(environment="development", _env_file=None)
    )

    assert application.docs_url == "/docs"
    schema = application.openapi()
    assert schema["servers"] == [
        {
            "url": "http://127.0.0.1:4112",
            "description": "Local fake-provider stack",
        }
    ]
    assert schema["components"]["securitySchemes"]["bearerAuth"] == {
        "type": "http",
        "scheme": "bearer",
        "bearerFormat": "JWT",
        "description": "Access token returned by POST /v1/auth/guest or OAuth sign-in.",
    }

    submit = schema["paths"]["/v1/imports"]["post"]
    assert submit["security"] == [{"bearerAuth": []}]
    assert submit["summary"] == "2. Submit Import"
    assert submit["x-ladle-test-step"] == 2
    assert all(
        parameter["name"].casefold() != "authorization"
        for parameter in submit["parameters"]
    )
    example = submit["requestBody"]["content"]["application/json"]["examples"][
        "videoImport"
    ]["value"]
    assert example == {
        "jobID": "00000000-0000-4000-8000-000000000010",
        "sourceURL": "https://www.youtube.com/watch?v=localDemo123",
        "allowDuplicate": False,
        "idempotencyKey": "00000000-0000-4000-8000-000000000010",
        "currentRecipeID": None,
        "correctionNotes": None,
        "pastedText": None,
    }

    attest_headers = {
        parameter["name"]
        for parameter in submit["parameters"]
        if parameter["name"].startswith("X-App-Attest-")
    }
    assert attest_headers == {
        "X-App-Attest-Kind",
        "X-App-Attest-Key-ID",
        "X-App-Attest-Challenge-ID",
        "X-App-Attest-Challenge",
        "X-App-Attest-Assertion",
        "X-App-Attest-Client-Data",
    }


def test_interactive_swagger_is_hidden_outside_development() -> None:
    application = create_app(settings=Settings(environment="test", _env_file=None))

    assert application.docs_url is None
    assert "servers" not in application.openapi()
