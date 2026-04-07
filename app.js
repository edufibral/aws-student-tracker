const ENTITIES = [
  {
    key: "user",
    title: "Users",
    singular: "user",
    endpoint: "user",
    sample: {
      name: "Jordan Lee",
      email: "jordan.lee@example.edu"
    }
  },
  {
    key: "program",
    title: "Programs / Degrees",
    singular: "program",
    endpoint: "program",
    sample: {
      code: "CS-BS",
      name: "Computer Science",
      degreeType: "BS"
    }
  },
  {
    key: "course",
    title: "Courses",
    singular: "course",
    endpoint: "course",
    sample: {
      code: "CS101",
      name: "Intro to Programming",
      credits: 3
    }
  },
  {
    key: "grade",
    title: "Grades",
    singular: "grade",
    endpoint: "grade",
    sample: {
      studentId: "stu-001",
      courseCode: "CS101",
      grade: "A",
      userEmail: "jordan.lee@example.edu"
    }
  }
];

const STORAGE_KEY = "student_tracker_api_base";

const apiBaseInput = document.getElementById("api-base-url");
const saveApiBaseBtn = document.getElementById("save-api-base");
const configMessage = document.getElementById("config-message");
const grid = document.getElementById("crud-grid");
const template = document.getElementById("crud-panel-template");

function getApiBase() {
  const fromStorage = localStorage.getItem(STORAGE_KEY);
  return (fromStorage || apiBaseInput.value || "").replace(/\/+$/, "");
}

function setApiBase(baseUrl) {
  const trimmed = baseUrl.replace(/\/+$/, "");
  localStorage.setItem(STORAGE_KEY, trimmed);
  apiBaseInput.value = trimmed;
}

function formatJson(data) {
  if (typeof data === "string") return data;
  try {
    return JSON.stringify(data, null, 2);
  } catch {
    return "(unable to format response)";
  }
}

function buildUrl(entityEndpoint, id = "") {
  const base = getApiBase();
  if (!base) return "";
  const safeId = String(id || "").trim();
  return safeId ? `${base}/${entityEndpoint}/${encodeURIComponent(safeId)}` : `${base}/${entityEndpoint}`;
}

async function request({ method, endpoint, id = "", payload }) {
  const url = buildUrl(endpoint, id);
  if (!url) {
    throw new Error("Please configure an API base URL first.");
  }

  const options = {
    method,
    headers: {
      "Content-Type": "application/json"
    }
  };

  if (payload !== undefined) {
    options.body = JSON.stringify(payload);
  }

  const response = await fetch(url, options);
  const text = await response.text();

  let parsedBody = text;
  if (text) {
    try {
      parsedBody = JSON.parse(text);
    } catch {
      parsedBody = text;
    }
  } else {
    parsedBody = { message: "No response body" };
  }

  if (!response.ok) {
    throw new Error(`${response.status} ${response.statusText}: ${formatJson(parsedBody)}`);
  }

  return parsedBody;
}

function parsePayload(rawPayload, title) {
  const clean = rawPayload.trim();
  if (!clean) {
    throw new Error(`Please provide JSON payload for ${title}.`);
  }

  try {
    return JSON.parse(clean);
  } catch {
    throw new Error("Payload must be valid JSON.");
  }
}

function setPanelState(messageEl, responseEl, message, responseObj) {
  messageEl.textContent = message;
  responseEl.textContent = formatJson(responseObj);
}

function createPanel(entity) {
  const node = template.content.firstElementChild.cloneNode(true);

  const titleEl = node.querySelector(".entity-title");
  const endpointEl = node.querySelector(".entity-endpoint");
  const idInput = node.querySelector('[data-field="id"]');
  const payloadInput = node.querySelector('[data-field="payload"]');
  const messageEl = node.querySelector(".panel-message");
  const responseEl = node.querySelector('[data-field="response"]');

  titleEl.textContent = entity.title;
  endpointEl.textContent = `/${entity.endpoint}`;
  payloadInput.value = JSON.stringify(entity.sample, null, 2);

  node.querySelector('[data-action="list"]').addEventListener("click", async () => {
    setPanelState(messageEl, responseEl, `Loading ${entity.title.toLowerCase()}...`, {});
    try {
      const data = await request({ method: "GET", endpoint: entity.endpoint });
      setPanelState(messageEl, responseEl, `Loaded ${entity.title.toLowerCase()}.`, data);
    } catch (error) {
      setPanelState(messageEl, responseEl, error.message, { error: true });
    }
  });

  node.querySelector('[data-action="create"]').addEventListener("click", async () => {
    try {
      const payload = parsePayload(payloadInput.value, entity.title);
      setPanelState(messageEl, responseEl, `Creating ${entity.singular}...`, payload);
      const data = await request({ method: "POST", endpoint: entity.endpoint, payload });
      setPanelState(messageEl, responseEl, `${entity.singular} created.`, data);
    } catch (error) {
      setPanelState(messageEl, responseEl, error.message, { error: true });
    }
  });

  node.querySelector('[data-action="update"]').addEventListener("click", async () => {
    try {
      const id = idInput.value.trim();
      if (!id) throw new Error("Provide a Record ID for update.");
      const payload = parsePayload(payloadInput.value, entity.title);
      setPanelState(messageEl, responseEl, `Updating ${entity.singular}...`, payload);
      const data = await request({ method: "PUT", endpoint: entity.endpoint, id, payload });
      setPanelState(messageEl, responseEl, `${entity.singular} updated.`, data);
    } catch (error) {
      setPanelState(messageEl, responseEl, error.message, { error: true });
    }
  });

  node.querySelector('[data-action="delete"]').addEventListener("click", async () => {
    try {
      const id = idInput.value.trim();
      if (!id) throw new Error("Provide a Record ID for delete.");
      setPanelState(messageEl, responseEl, `Deleting ${entity.singular}...`, { id });
      const data = await request({ method: "DELETE", endpoint: entity.endpoint, id });
      setPanelState(messageEl, responseEl, `${entity.singular} deleted.`, data);
    } catch (error) {
      setPanelState(messageEl, responseEl, error.message, { error: true });
    }
  });

  return node;
}

function renderCrudPanels() {
  grid.innerHTML = "";
  ENTITIES.forEach((entity) => {
    grid.appendChild(createPanel(entity));
  });
}

saveApiBaseBtn.addEventListener("click", () => {
  const value = apiBaseInput.value.trim();
  if (!value) {
    configMessage.textContent = "Please enter a valid API base URL.";
    return;
  }

  setApiBase(value);
  configMessage.textContent = `Saved API base URL: ${getApiBase()}`;
});

function bootstrap() {
  const saved = localStorage.getItem(STORAGE_KEY);
  if (saved) {
    apiBaseInput.value = saved;
  }

  renderCrudPanels();
  configMessage.textContent = `Current API base URL: ${getApiBase()}`;
}

bootstrap();
