from fastapi import FastAPI


def create_app() -> FastAPI:
    """Build the HTTP application without eagerly contacting infrastructure."""

    return FastAPI(
        title="Ladle API",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
    )


app = create_app()
