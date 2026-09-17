from fastapi.testclient import TestClient

from ladle.api.app import create_app
from ladle.config import Settings


def test_development_swagger_describes_the_import_pipeline() -> None:
    application = create_app(
        settings=Settings(environment="development", _env_file=None)
    )

    assert any(getattr(route, "path", None) == "/docs" for route in application.routes)
    schema = application.openapi()
    bearer = schema["components"]["securitySchemes"]["bearerAuth"]
    assert (bearer["type"], bearer["scheme"]) == ("http", "bearer")

    submit = schema["paths"]["/v1/imports"]["post"]
    assert submit["security"] == [{"bearerAuth": []}]
    assert all(
        parameter["name"].casefold() != "authorization"
        for parameter in submit["parameters"]
    )

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


def test_development_swagger_serves_its_browser_assets_locally() -> None:
    application = create_app(
        settings=Settings(environment="development", _env_file=None)
    )

    with TestClient(application) as client:
        docs = client.get("/docs")
        javascript = client.get("/swagger/swagger-ui-bundle.js")
        stylesheet = client.get("/swagger/swagger-ui.css")

    assert docs.status_code == 200
    assert "cdn.jsdelivr.net" not in docs.text
    assert "fastapi.tiangolo.com" not in docs.text
    assert "/swagger/swagger-ui-bundle.js" in docs.text
    assert "/swagger/swagger-ui.css" in docs.text
    assert docs.headers["Content-Security-Policy"] == (
        "default-src 'none'; script-src 'self' 'unsafe-inline'; "
        "style-src 'self'; img-src 'self' data:; connect-src 'self'; "
        "frame-ancestors 'none'; base-uri 'none'"
    )
    assert javascript.status_code == 200
    assert javascript.headers["Content-Type"].startswith("application/javascript")
    assert stylesheet.status_code == 200
    assert stylesheet.headers["Content-Type"].startswith("text/css")


def test_interactive_swagger_is_hidden_outside_development() -> None:
    application = create_app(settings=Settings(environment="test", _env_file=None))

    with TestClient(application) as client:
        docs = client.get("/docs")
        javascript = client.get("/swagger/swagger-ui-bundle.js")

    assert application.docs_url is None
    assert "servers" not in application.openapi()
    assert docs.status_code == 404
    assert javascript.status_code == 404
    # The documentation page's relaxed policy goes away with the page.
    assert "unsafe-inline" not in docs.headers["Content-Security-Policy"]


def test_guarded_development_server_can_hide_interactive_swagger() -> None:
    application = create_app(
        settings=Settings(
            environment="development",
            interactive_docs_enabled=False,
            _env_file=None,
        )
    )

    with TestClient(application) as client:
        schema = client.get("/openapi.json")
        docs = client.get("/docs")
        javascript = client.get("/swagger/swagger-ui-bundle.js")

    assert schema.status_code == 404
    assert docs.status_code == 404
    assert javascript.status_code == 404
