import http from "k6/http";
import { check } from "k6";

const BASE_URL = __ENV.BASE_URL || "http://127.0.0.1:4112";
const EXPECTED_STATUSES = http.expectedStatuses(200, 201, 202, 409, 429);

export const options = {
  scenarios: {
    guest_creation: {
      executor: "constant-arrival-rate",
      exec: "guestCreation",
      duration: "30s",
      rate: 10,
      timeUnit: "1s",
      preAllocatedVUs: 10,
      maxVUs: 40,
    },
    import_bursts: {
      executor: "ramping-arrival-rate",
      exec: "importBursts",
      startRate: 1,
      stages: [
        { duration: "10s", target: 10 },
        { duration: "20s", target: 25 },
        { duration: "10s", target: 0 },
      ],
      preAllocatedVUs: 10,
      maxVUs: 60,
    },
    sync_polling: {
      executor: "constant-vus",
      exec: "syncPolling",
      vus: 25,
      duration: "30s",
    },
    recipe_graph_limits: {
      executor: "per-vu-iterations",
      exec: "recipeGraphLimits",
      vus: 5,
      iterations: 2,
      maxDuration: "1m",
    },
  },
  thresholds: {
    checks: ["rate>0.99"],
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<1000", "p(99)<2000"],
  },
};

export function setup() {
  return {
    graphToken: createLoadUser("graph"),
    importToken: createLoadUser("imports"),
    syncToken: createLoadUser("sync"),
  };
}

export function guestCreation() {
  const response = createGuest(`guest-${__VU}-${__ITER}-${Date.now()}`);
  check(response, { "guest admitted or limited": (value) => [201, 429].includes(value.status) });
}

export function importBursts(data) {
  const id = uuid();
  const response = http.post(
    `${BASE_URL}/v1/imports`,
    JSON.stringify({
      jobID: id,
      sourceURL: `https://youtu.be/${id.slice(0, 11)}`,
    }),
    jsonHeaders(data.importToken),
  );
  check(response, { "import admitted or controlled": (value) => [202, 409, 429].includes(value.status) });
}

export function syncPolling(data) {
  const response = http.get(
    `${BASE_URL}/v1/recipes/sync?cursor=0&limit=100`,
    {
      headers: { Authorization: `Bearer ${data.syncToken}` },
      responseCallback: EXPECTED_STATUSES,
    },
  );
  check(response, { "sync succeeds or is limited": (value) => [200, 429].includes(value.status) });
}

export function recipeGraphLimits(data) {
  const recipe = maximumRecipe();
  const response = http.put(
    `${BASE_URL}/v1/recipes/${recipe.id}`,
    JSON.stringify({ baseRevision: 0, recipe }),
    jsonHeaders(data.graphToken),
  );
  check(response, { "maximum recipe is bounded": (value) => [200, 409, 429].includes(value.status) });
}

function createGuest(suffix) {
  return http.post(
    `${BASE_URL}/v1/auth/guest`,
    JSON.stringify({ installationID: `load-${suffix}`, attestation: null }),
    {
      headers: { "Content-Type": "application/json" },
      responseCallback: EXPECTED_STATUSES,
    },
  );
}

function createLoadUser(suffix) {
  const response = createGuest(`${suffix}-${Date.now()}`);
  check(response, { "load user created": (value) => value.status === 201 });
  return response.json("accessToken");
}

function jsonHeaders(token) {
  return {
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    responseCallback: EXPECTED_STATUSES,
  };
}

function maximumRecipe() {
  const recipeID = uuid();
  const ingredients = Array.from({ length: 200 }, (_, index) => ({
    id: uuid(),
    name: `ingredient ${index}`,
    normalizedQuantity: "1",
    orderIndex: index,
    preparation: null,
    quantityText: "1 unit",
    uncertainty: null,
    unit: "unit",
  }));
  const now = new Date().toISOString();
  return {
    cookingMinutes: 10,
    createdAt: now,
    creatorName: "Load test",
    description: "A maximum-size recipe graph.",
    id: recipeID,
    images: [],
    ingredients,
    isFavorite: false,
    notes: [],
    nutrition: null,
    originalURL: `https://manual.ladle.local/${recipeID}`,
    preparationMinutes: 10,
    reviewStatus: "ready",
    revision: 1,
    servings: "4",
    source: "other",
    steps: [{
      id: uuid(),
      ingredientIDs: ingredients.map((ingredient) => ingredient.id),
      instruction: "Combine every ingredient.",
      orderIndex: 0,
      sourceEndSeconds: null,
      sourceStartSeconds: null,
      timers: [],
      uncertainty: null,
    }],
    title: "Maximum graph",
    totalMinutes: 20,
    uncertainties: [],
    updatedAt: now,
  };
}

function uuid() {
  const value = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx";
  return value.replace(/[xy]/g, (character) => {
    const random = Math.floor(Math.random() * 16);
    const nibble = character === "x" ? random : (random & 0x3) | 0x8;
    return nibble.toString(16);
  });
}
