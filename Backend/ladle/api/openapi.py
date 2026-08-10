from collections.abc import Callable
from typing import Any, cast

from fastapi import FastAPI

OpenAPISchema = dict[str, Any]
Operation = dict[str, Any]

_PROTECTED_OPERATIONS = {
    ("/v1/auth/apple", "post"),
    ("/v1/auth/google", "post"),
    ("/v1/auth/session", "delete"),
    ("/v1/auth/account", "delete"),
    ("/v1/imports", "post"),
    ("/v1/imports/{job_id}", "get"),
    ("/v1/imports/{job_id}/retry", "post"),
    ("/v1/recipes/sync", "get"),
    ("/v1/recipes/{recipe_id}", "get"),
    ("/v1/recipes/{recipe_id}", "put"),
    ("/v1/recipes/{recipe_id}", "delete"),
}

_PIPELINE_OPERATIONS = {
    ("/v1/auth/guest", "post"): (
        1,
        "Create a local guest session first. Copy `accessToken`, open the "
        "Swagger **Authorize** dialog, and paste only the token value.",
    ),
    ("/v1/imports", "post"): (
        2,
        "Submit a fresh client-generated `jobID`. The local Compose stack uses "
        "a deterministic fake provider, so this exercises the real queue, worker, "
        "database, object storage, and sync path without paid API calls.",
    ),
    ("/v1/imports/{job_id}", "get"): (
        3,
        "Poll the submitted job until `status` is `ready`, `needsReview`, or "
        "`failed`. Copy `recipeID` from a successful terminal response.",
    ),
    ("/v1/recipes/{recipe_id}", "get"): (
        4,
        "Fetch the imported recipe using the terminal job's `recipeID`.",
    ),
    ("/v1/recipes/sync", "get"): (
        5,
        "Start with `cursor=0`. Save `nextCursor` and use it for the next poll.",
    ),
}

_REQUEST_EXAMPLES: dict[tuple[str, str], dict[str, dict[str, object]]] = {
    ("/v1/auth/guest", "post"): {
        "localGuest": {
            "summary": "Create a local Swagger test session",
            "value": {
                "installationID": "swagger-local-installation",
                "attestation": None,
            },
        }
    },
    ("/v1/auth/refresh", "post"): {
        "rotateSession": {
            "summary": "Rotate the guest or account refresh token",
            "value": {
                "refreshToken": "paste-current-refresh-token",
                "deviceID": "00000000-0000-4000-8000-000000000002",
            },
        }
    },
    ("/v1/auth/apple", "post"): {
        "appleSignIn": {
            "summary": "Merge the authorized guest into an Apple account",
            "value": {
                "identityToken": "paste-apple-identity-token",
                "authorizationCode": "paste-single-use-authorization-code",
                "nonce": "paste-the-original-raw-nonce",
                "idempotencyKey": "swagger-apple-merge-attempt",
            },
        }
    },
    ("/v1/auth/google", "post"): {
        "googleSignIn": {
            "summary": "Merge the authorized guest into a Google account",
            "value": {
                "identityToken": "paste-google-identity-token",
                "idempotencyKey": "swagger-google-merge-attempt",
            },
        }
    },
    ("/v1/imports", "post"): {
        "videoImport": {
            "summary": "Run the local fake-provider pipeline",
            "value": {
                "jobID": "00000000-0000-4000-8000-000000000010",
                "sourceURL": "https://www.youtube.com/watch?v=localDemo123",
                "allowDuplicate": False,
                "idempotencyKey": "00000000-0000-4000-8000-000000000010",
                "currentRecipeID": None,
                "correctionNotes": None,
                "pastedText": None,
            },
        },
        "pastedText": {
            "summary": "Exercise extraction with private pasted evidence",
            "value": {
                "jobID": "00000000-0000-4000-8000-000000000011",
                "sourceURL": "https://www.youtube.com/watch?v=pastedTextDemo",
                "allowDuplicate": False,
                "idempotencyKey": "00000000-0000-4000-8000-000000000011",
                "currentRecipeID": None,
                "correctionNotes": None,
                "pastedText": "Tomato pasta. Boil 200 g pasta. Add two tomatoes.",
            },
        },
    },
    ("/v1/imports/{job_id}/retry", "post"): {
        "correctAndRetry": {
            "summary": "Retry a terminal import with a correction",
            "value": {
                "correctionNotes": (
                    "The spoken quantity is two cups, not two tablespoons."
                ),
                "pastedText": None,
            },
        }
    },
}

_APP_ATTEST_PARAMETERS = [
    {
        "name": "X-App-Attest-Kind",
        "in": "header",
        "required": False,
        "description": "Use `assertion` for an authenticated import request.",
        "schema": {"type": "string", "enum": ["assertion"]},
    },
    {
        "name": "X-App-Attest-Key-ID",
        "in": "header",
        "required": False,
        "description": "Apple App Attest key identifier for the authenticated device.",
        "schema": {"type": "string"},
    },
    {
        "name": "X-App-Attest-Challenge-ID",
        "in": "header",
        "required": False,
        "description": "Challenge UUID issued for this import operation.",
        "schema": {"type": "string", "format": "uuid"},
    },
    {
        "name": "X-App-Attest-Challenge",
        "in": "header",
        "required": False,
        "description": "Opaque challenge value returned with the challenge ID.",
        "schema": {"type": "string"},
    },
    {
        "name": "X-App-Attest-Assertion",
        "in": "header",
        "required": False,
        "description": "Base64 App Attest assertion over the exact request binding.",
        "schema": {"type": "string"},
    },
    {
        "name": "X-App-Attest-Client-Data",
        "in": "header",
        "required": False,
        "description": "Base64 client-data bytes used to construct the assertion.",
        "schema": {"type": "string"},
    },
]


def install_pipeline_openapi(application: FastAPI) -> None:
    """Enrich FastAPI's generated schema without creating a second API contract."""

    generated_openapi: Callable[[], OpenAPISchema] = application.openapi

    def pipeline_openapi() -> OpenAPISchema:
        if application.openapi_schema is None:
            schema = generated_openapi()
            _enrich(schema)
            application.openapi_schema = schema
        return application.openapi_schema

    application.openapi = pipeline_openapi  # type: ignore[method-assign]


def _enrich(schema: OpenAPISchema) -> None:
    schema["servers"] = [
        {
            "url": "http://127.0.0.1:4112",
            "description": "Local fake-provider stack",
        }
    ]
    info = cast(dict[str, Any], schema["info"])
    info["description"] = (
        "Interactive contract for testing Ladle's authentication, import worker, "
        "recipe persistence, and sync pipeline. Start with the numbered operations. "
        "The local Compose stack disables App Attest and paid providers; production "
        "assertions must be generated by a signed physical-device client."
    )
    components = cast(dict[str, Any], schema.setdefault("components", {}))
    security_schemes = cast(
        dict[str, Any], components.setdefault("securitySchemes", {})
    )
    security_schemes["bearerAuth"] = {
        "type": "http",
        "scheme": "bearer",
        "bearerFormat": "JWT",
        "description": (
            "Access token returned by POST /v1/auth/guest or OAuth sign-in."
        ),
    }
    schema["tags"] = [
        {"name": "auth", "description": "Guest sessions and Apple/Google OAuth."},
        {
            "name": "attestation",
            "description": "Apple App Attest challenges for signed clients.",
        },
        {"name": "imports", "description": "Submit, poll, and retry recipe imports."},
        {"name": "recipes", "description": "Recipe reads, mutations, and sync."},
        {"name": "operations", "description": "Health and internal observability."},
    ]

    for path, method in _PROTECTED_OPERATIONS:
        operation = _operation(schema, path, method)
        operation["security"] = [{"bearerAuth": []}]
        parameters = cast(list[dict[str, Any]], operation.get("parameters", []))
        operation["parameters"] = [
            parameter
            for parameter in parameters
            if not (
                parameter.get("in") == "header"
                and str(parameter.get("name", "")).casefold() == "authorization"
            )
        ]

    for (path, method), (step, description) in _PIPELINE_OPERATIONS.items():
        operation = _operation(schema, path, method)
        operation["summary"] = f"{step}. {operation['summary']}"
        operation["description"] = description
        operation["x-ladle-test-step"] = step

    for (path, method), examples in _REQUEST_EXAMPLES.items():
        operation = _operation(schema, path, method)
        request_body = cast(dict[str, Any], operation["requestBody"])
        content = cast(dict[str, Any], request_body["content"])
        application_json = cast(dict[str, Any], content["application/json"])
        application_json["examples"] = examples

    for path in ("/v1/imports", "/v1/imports/{job_id}/retry"):
        operation = _operation(schema, path, "post")
        parameters = cast(list[dict[str, Any]], operation["parameters"])
        parameters.extend(_APP_ATTEST_PARAMETERS)


def _operation(schema: OpenAPISchema, path: str, method: str) -> Operation:
    paths = cast(dict[str, Any], schema["paths"])
    path_item = cast(dict[str, Any], paths[path])
    return cast(Operation, path_item[method])
