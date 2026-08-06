"use strict";

// ---- constants ------------------------------------------------------

const TOKEN_KEY = "veloshare_token";
const ROLE_KEY = "veloshare_role";

// ---- state ------------------------------------------------------

let currentUser = null; // result of GET /api/riders/auth/me
let tiersData = null; // { unlock_fee_cents, tiers: [{ tier, per_minute_cents }] }
let stationsData = []; // stations for the rider dashboard (station picker + table)
let myTrips = [];
let activeTrip = null;
// Outcome of the ride just ended. Held in state because renderMyRide() clears
// the panel it is shown in, so anything written straight into the DOM there is
// wiped by the re-render that follows.
let lastRideResult = null;

// ---- status bar ------------------------------------------------------

const statusBar = document.getElementById("status-bar");
let statusTimer = null;

function showStatus(message, isError) {
  statusBar.textContent = message;
  statusBar.classList.remove("hidden");
  statusBar.classList.toggle("status-error", Boolean(isError));
  statusBar.classList.toggle("status-ok", !isError);
  if (statusTimer) {
    clearTimeout(statusTimer);
  }
  statusTimer = setTimeout(() => {
    statusBar.classList.add("hidden");
  }, 6000);
}

// ---- auth storage ------------------------------------------------------

function getToken() {
  return localStorage.getItem(TOKEN_KEY);
}

function setAuth(token, role) {
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(ROLE_KEY, role);
}

function clearAuth() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(ROLE_KEY);
}

// ---- view switching ------------------------------------------------------

function showView(viewId) {
  document.querySelectorAll(".view").forEach((el) => el.classList.add("hidden"));
  document.getElementById(viewId).classList.remove("hidden");
}

function showLogin(message) {
  clearAuth();
  currentUser = null;
  document.getElementById("user-info").classList.add("hidden");
  showView("view-login");
  if (message) {
    showStatus(message, true);
  }
}

function renderUserInfo(user) {
  document.getElementById("user-email").textContent = user.email;
  document.getElementById("user-role-badge").textContent = user.role;
  document.getElementById("user-info").classList.remove("hidden");
}

// ---- fetch helper ------------------------------------------------------

async function apiRequest(path, options) {
  const opts = options || {};
  const init = {
    method: opts.method || "GET",
    headers: { "Content-Type": "application/json" },
  };
  const token = getToken();
  if (token) {
    init.headers["Authorization"] = `Bearer ${token}`;
  }
  if (opts.body !== undefined) {
    init.body = JSON.stringify(opts.body);
  }

  let response;
  try {
    response = await fetch(path, init);
  } catch (err) {
    showStatus(`Network error calling ${path}: ${err.message}`, true);
    throw err;
  }

  let data = null;
  const text = await response.text();
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (err) {
      data = null;
    }
  }

  if (response.status === 401) {
    showLogin("Session expired. Please sign in again.");
    throw new Error("unauthorized");
  }

  if (!response.ok) {
    const detail = (data && data.detail) || response.statusText || "request failed";
    showStatus(`${response.status} ${path}: ${JSON.stringify(detail)}`, true);
    throw new Error(typeof detail === "string" ? detail : JSON.stringify(detail));
  }

  return data;
}

// ---- formatting helpers ------------------------------------------------------

function formatCents(cents) {
  if (cents === null || cents === undefined) {
    return "—";
  }
  return `$${(cents / 100).toFixed(2)}`;
}

function renderTableRows(tbody, rows, cellsFn) {
  tbody.innerHTML = "";
  rows.forEach((row) => {
    const tr = document.createElement("tr");
    cellsFn(row).forEach((value) => {
      const td = document.createElement("td");
      td.textContent = value === null || value === undefined ? "—" : value;
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
}

function fillStationSelect(select, stations) {
  select.innerHTML = "";
  stations.forEach((station) => {
    const opt = document.createElement("option");
    opt.value = station.id;
    opt.textContent = station.name;
    select.appendChild(opt);
  });
}

// ---- login ------------------------------------------------------

const loginForm = document.getElementById("login-form");
const loginError = document.getElementById("login-error");

loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  loginError.classList.add("hidden");
  loginError.textContent = "";

  const email = document.getElementById("login-email").value;
  const password = document.getElementById("login-password").value;

  let response;
  try {
    response = await fetch("/api/riders/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
  } catch (err) {
    loginError.textContent = "Network error. Please try again.";
    loginError.classList.remove("hidden");
    return;
  }

  let data = null;
  const text = await response.text();
  if (text) {
    try {
      data = JSON.parse(text);
    } catch (err) {
      data = null;
    }
  }

  if (!response.ok) {
    const detail = (data && data.detail) || "Invalid email or password";
    loginError.textContent = typeof detail === "string" ? detail : "Invalid email or password";
    loginError.classList.remove("hidden");
    return;
  }

  setAuth(data.access_token, data.role);
  loginForm.reset();
  await bootstrap();
});

document.getElementById("signout-btn").addEventListener("click", () => {
  showLogin();
});

// ---- rider dashboard ------------------------------------------------------

function renderProfile() {
  if (!currentUser || currentUser.role !== "rider") {
    return;
  }
  document.getElementById("profile-name").textContent = currentUser.name;
  document.getElementById("profile-email").textContent = currentUser.email;
  document.getElementById("profile-tier-badge").textContent = currentUser.tier;

  const costEl = document.getElementById("profile-tier-cost");
  const rate = tiersData && tiersData.tiers.find((t) => t.tier === currentUser.tier);
  if (rate) {
    costEl.textContent =
      `Unlock fee ${formatCents(tiersData.unlock_fee_cents)} + ${formatCents(rate.per_minute_cents)} / minute`;
  } else {
    costEl.textContent = "";
  }
}

async function loadTiers() {
  try {
    tiersData = await apiRequest("/api/pricing/tiers");
    renderProfile();
  } catch (err) {
    // status already shown
  }
}

async function loadStationsUser() {
  try {
    stationsData = await apiRequest("/api/stations/stations");
    renderTableRows(document.getElementById("user-stations-body"), stationsData, (s) => [
      s.id,
      s.name,
      s.capacity,
      s.docks_available,
    ]);
    renderMyRide();
  } catch (err) {
    // status already shown
  }
}

function renderMyRide() {
  const container = document.getElementById("my-ride-content");
  container.innerHTML = "";

  if (lastRideResult) {
    const banner = document.createElement("div");
    banner.className = "result";
    banner.id = "last-ride-result";
    banner.textContent = lastRideResult;
    container.appendChild(banner);
  }

  if (activeTrip) {
    const info = document.createElement("p");
    info.textContent = `Active ride: trip #${activeTrip.id}, started ${activeTrip.started_at}`;
    container.appendChild(info);

    const form = document.createElement("form");
    form.id = "end-ride-form";

    const label = document.createElement("label");
    label.textContent = "End station";
    const select = document.createElement("select");
    select.id = "end-ride-station";
    fillStationSelect(select, stationsData);
    label.appendChild(select);
    form.appendChild(label);

    const button = document.createElement("button");
    button.type = "submit";
    button.textContent = "End ride";
    form.appendChild(button);

    container.appendChild(form);

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const end_station_id = Number(select.value);
      try {
        const data = await apiRequest(`/api/trips/trips/${activeTrip.id}/end`, {
          method: "POST",
          body: { end_station_id, surge: 1.0 },
        });
        lastRideResult = `Ride complete — fare ${formatCents(data.fare_cents)} (${data.minutes} min)`;
        showStatus("Ride ended", false);
        activeTrip = null;
        await loadMyTrips();
      } catch (err) {
        // status already shown
      }
    });
  } else {
    const form = document.createElement("form");
    form.id = "start-ride-form";

    const label = document.createElement("label");
    label.textContent = "Station";
    const select = document.createElement("select");
    select.id = "start-ride-station";
    fillStationSelect(select, stationsData);
    label.appendChild(select);
    form.appendChild(label);

    const button = document.createElement("button");
    button.type = "submit";
    button.textContent = "Start ride";
    form.appendChild(button);

    container.appendChild(form);

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const station_id = Number(select.value);
      try {
        await apiRequest("/api/trips/trips/start", {
          method: "POST",
          body: { station_id, tier: currentUser.tier },
        });
        showStatus("Ride started", false);
        lastRideResult = null;
        await loadMyTrips();
      } catch (err) {
        // status already shown
      }
    });
  }
}

function renderMyTrips() {
  const sorted = [...myTrips].sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  renderTableRows(document.getElementById("my-trips-body"), sorted, (t) => [
    t.id,
    t.started_at,
    t.ended_at,
    t.tier,
    formatCents(t.fare_cents),
    t.status,
  ]);
}

async function loadMyTrips() {
  try {
    myTrips = await apiRequest("/api/trips/trips");
    activeTrip = myTrips.find((t) => t.status === "active") || null;
    renderMyTrips();
    renderMyRide();
  } catch (err) {
    // status already shown
  }
}

async function loadUserDashboard() {
  await loadTiers();
  await loadStationsUser();
  await loadMyTrips();
}

document.getElementById("user-stations-refresh").addEventListener("click", loadStationsUser);

// ---- admin dashboard ------------------------------------------------------

async function refreshAdminRiders() {
  try {
    const riders = await apiRequest("/api/riders/riders");
    renderTableRows(document.getElementById("admin-riders-body"), riders, (r) => [
      r.id,
      r.name,
      r.email,
      r.tier,
    ]);
  } catch (err) {
    // status already shown
  }
}

async function refreshAdminStations() {
  try {
    const stations = await apiRequest("/api/stations/stations");
    renderTableRows(document.getElementById("admin-stations-body"), stations, (s) => [
      s.id,
      s.name,
      s.capacity,
      s.docks_available,
    ]);
  } catch (err) {
    // status already shown
  }
}

async function refreshAdminTrips() {
  try {
    const trips = await apiRequest("/api/trips/trips");
    const sorted = [...trips].sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
    renderTableRows(document.getElementById("admin-trips-body"), sorted, (t) => [
      t.id,
      t.rider_id,
      t.started_at,
      t.ended_at,
      t.tier,
      formatCents(t.fare_cents),
      t.status,
    ]);
  } catch (err) {
    // status already shown
  }
}

async function loadAdminDashboard() {
  await Promise.all([refreshAdminRiders(), refreshAdminStations(), refreshAdminTrips()]);
}

document.getElementById("admin-rider-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const name = document.getElementById("admin-rider-name").value;
  const email = document.getElementById("admin-rider-email").value;
  const tier = document.getElementById("admin-rider-tier").value;
  const password = document.getElementById("admin-rider-password").value;

  try {
    await apiRequest("/api/riders/riders", {
      method: "POST",
      body: { name, email, tier, password },
    });
    showStatus("Rider created", false);
    document.getElementById("admin-rider-form").reset();
    await refreshAdminRiders();
  } catch (err) {
    // status already shown
  }
});

document.getElementById("admin-riders-refresh").addEventListener("click", refreshAdminRiders);

document.getElementById("admin-station-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const name = document.getElementById("admin-station-name").value;
  const capacity = Number(document.getElementById("admin-station-capacity").value);

  try {
    await apiRequest("/api/stations/stations", {
      method: "POST",
      body: { name, capacity },
    });
    showStatus("Station created", false);
    document.getElementById("admin-station-form").reset();
    await refreshAdminStations();
  } catch (err) {
    // status already shown
  }
});

document.getElementById("admin-docks-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const stationId = Number(document.getElementById("admin-docks-station-id").value);
  const docks_available = Number(document.getElementById("admin-docks-value").value);

  try {
    await apiRequest(`/api/stations/stations/${stationId}/docks`, {
      method: "PATCH",
      body: { docks_available },
    });
    showStatus("Docks updated", false);
    document.getElementById("admin-docks-form").reset();
    await refreshAdminStations();
  } catch (err) {
    // status already shown
  }
});

document.getElementById("admin-stations-refresh").addEventListener("click", refreshAdminStations);

document.getElementById("admin-trips-refresh").addEventListener("click", refreshAdminTrips);

const fareForm = document.getElementById("fare-form");
const fareResult = document.getElementById("fare-result");

fareForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const minutes = Number(document.getElementById("fare-minutes").value);
  const tier = document.getElementById("fare-tier").value;
  const surge = Number(document.getElementById("fare-surge").value);

  try {
    const data = await apiRequest("/api/pricing/fare", {
      method: "POST",
      body: { minutes, tier, surge },
    });
    fareResult.textContent = `Fare: ${formatCents(data.cents)}`;
    showStatus("Fare calculated", false);
  } catch (err) {
    fareResult.textContent = "";
  }
});

// ---- bootstrap ------------------------------------------------------

async function bootstrap() {
  const token = getToken();
  if (!token) {
    showView("view-login");
    return;
  }

  try {
    const me = await apiRequest("/api/riders/auth/me");
    currentUser = me;
    renderUserInfo(me);

    if (me.role === "admin") {
      showView("view-admin");
      await loadAdminDashboard();
    } else {
      showView("view-user");
      await loadUserDashboard();
    }
  } catch (err) {
    // apiRequest already bounced to the login view on 401
  }
}

bootstrap();
