// One global instance owns one watcher/session, even when IINA has several player windows.
const helperPath = iina.utils.resolvePath("@data/bin/display-helper");
const helperTempPath = `${helperPath}.new`;
const heartbeatToken = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
const heartbeatPorts = Array.from({ length: 32 }, (_, index) => 43120 + index);
let heartbeatPortIndex = 0;
let watcherStarted = false;

function validateProfilesDocument(document) {
  if (!document || document.schemaVersion !== 1 || !Array.isArray(document.profiles) || document.profiles.length === 0) {
    throw new Error("Expected schemaVersion 1 and a non-empty profiles array");
  }
  const seen = new Set();
  for (const profile of document.profiles) {
    if (!profile || typeof profile.model !== "string" || !profile.model.trim() ||
        !Number.isInteger(profile.vendorID) || profile.vendorID < 0 || profile.vendorID > 65535 ||
        !Number.isInteger(profile.productID) || profile.productID < 0 || profile.productID > 65535 ||
        !Number.isInteger(profile.featureCode) || profile.featureCode < 0 || profile.featureCode > 255 ||
        !Number.isInteger(profile.movieValue) || profile.movieValue < 0 || profile.movieValue > 65535 ||
        typeof profile.verified !== "boolean") {
      throw new Error("Each profile needs model, valid numeric IDs, movieValue, and a boolean verified flag");
    }
    const key = `${profile.vendorID}:${profile.productID}:${profile.model.trim().toUpperCase()}`;
    if (seen.has(key)) throw new Error(`Duplicate profile: ${key}`);
    seen.add(key);
  }
}

iina.console.log(`[Dell Color Preset] Global entry loaded; data directory: ${iina.utils.resolvePath("@data/")}`);

let helperPayload;
let profilesPayload;
try {
  helperPayload = require("./helperPayload.js");
  profilesPayload = require("./profilesPayload.js");
} catch (error) {
  iina.console.error(`[Dell Color Preset] Cannot load bundled resources: ${error}`);
  throw error;
}

const bundledProfilesJSON = JSON.stringify(profilesPayload, null, 2);
iina.preferences.set("bundled_profiles_json", bundledProfilesJSON);
iina.preferences.sync();
let profilesJSON = iina.preferences.get("profiles_json");
if (typeof profilesJSON !== "string" || profilesJSON.trim().length === 0) {
  try {
    if (iina.file.exists("@data/bin/profiles.json")) {
      profilesJSON = iina.file.read("@data/bin/profiles.json");
    }
  } catch (_) {
    profilesJSON = undefined;
  }
  if (typeof profilesJSON !== "string" || profilesJSON.trim().length === 0) {
    profilesJSON = bundledProfilesJSON;
  }
  iina.preferences.set("profiles_json", profilesJSON);
  iina.preferences.sync();
}
try {
  validateProfilesDocument(JSON.parse(profilesJSON));
} catch (error) {
  iina.console.error(`[Dell Color Preset] Invalid saved profiles; using bundled defaults: ${error}`);
  profilesJSON = bundledProfilesJSON;
  iina.preferences.set("profiles_json", profilesJSON);
  iina.preferences.sync();
}

async function installBundledHelper() {
  const dataBin = iina.utils.resolvePath("@data/bin");
  const mkdir = await iina.utils.exec("/bin/mkdir", ["-p", dataBin]);
  if (mkdir.status !== 0) throw new Error(`Cannot create plugin data bin directory: ${mkdir.stderr}`);
  const removeLegacyHeartbeat = await iina.utils.exec("/bin/rm", ["-f", iina.utils.resolvePath("@data/watcher.heartbeat")]);
  if (removeLegacyHeartbeat.status !== 0) throw new Error(`Cannot remove legacy heartbeat file: ${removeLegacyHeartbeat.stderr}`);
  const removeStaleTemp = await iina.utils.exec("/bin/rm", ["-f", helperTempPath]);
  if (removeStaleTemp.status !== 0) throw new Error(`Cannot clear temporary helper file: ${removeStaleTemp.stderr}`);
  const createTemp = await iina.utils.exec("/usr/bin/touch", [helperTempPath]);
  if (createTemp.status !== 0) throw new Error(`Cannot create temporary helper file: ${createTemp.stderr}`);

  const handle = iina.file.handle(helperTempPath, "write");
  try {
    for (const chunk of helperPayload) handle.write(chunk);
  } finally {
    handle.close();
  }

  const chmod = await iina.utils.exec("/bin/chmod", ["700", helperTempPath]);
  if (chmod.status !== 0) throw new Error(`Cannot mark bundled helper executable: ${chmod.stderr}`);
  const move = await iina.utils.exec("/bin/mv", ["-f", helperTempPath, helperPath]);
  if (move.status !== 0) throw new Error(`Cannot install bundled helper: ${move.stderr}`);

  iina.file.write("@data/bin/profiles.json", profilesJSON);
}

function launchNativeWatcher(port) {
  watcherStarted = true;
  iina.console.log(`[Dell Color Preset] Starting native display watcher on heartbeat socket port ${port}.`);
  iina.utils.exec(helperPath, ["watch", String(port), heartbeatToken], undefined, undefined, (data) => {
    if (data) iina.console.error(`[Dell Color Preset] ${data.trim()}`);
  }).then(({ status, stderr }) => {
    if (status !== 0) {
      iina.console.error(`[Dell Color Preset] Watcher exited (${status}): ${stderr.trim()}`);
    } else {
      iina.console.log("[Dell Color Preset] Display watcher stopped.");
    }
  }).catch((error) => {
    iina.console.error(`[Dell Color Preset] Unable to start watcher: ${error}`);
  });
}

function startHeartbeatServer() {
  const port = heartbeatPorts[heartbeatPortIndex];
  if (port === undefined) {
    iina.console.error("[Dell Color Preset] Cannot start heartbeat socket server: no available local port.");
    return;
  }
  try {
    iina.ws.createServer({ port });
    iina.ws.startServer();
  } catch (error) {
    iina.console.error(`[Dell Color Preset] Cannot create heartbeat socket on port ${port}: ${error}`);
    heartbeatPortIndex += 1;
    startHeartbeatServer();
  }
}

iina.ws.onStateUpdate((state, error) => {
  if (state === "ready" && !watcherStarted) {
    launchNativeWatcher(heartbeatPorts[heartbeatPortIndex]);
  } else if (state === "failed" && !watcherStarted) {
    iina.console.error(`[Dell Color Preset] Heartbeat socket port ${heartbeatPorts[heartbeatPortIndex]} unavailable: ${error?.message || "unknown error"}`);
    heartbeatPortIndex += 1;
    startHeartbeatServer();
  }
});

iina.ws.onMessage((connection, message) => {
  let ping;
  try {
    ping = JSON.parse(message.text());
  } catch (_) {
    return;
  }
  if (!ping || ping.type !== "PING" || ping.token !== heartbeatToken || !Number.isInteger(ping.sequence)) return;
  iina.ws.sendText(connection, JSON.stringify({ type: "PONG", token: heartbeatToken, sequence: ping.sequence }))
    .catch((error) => iina.console.error(`[Dell Color Preset] Heartbeat socket response failed: ${error}`));
});

async function initializePlugin() {
  try {
    await installBundledHelper();
  } catch (error) {
    iina.console.error(`[Dell Color Preset] Native helper installation failed: ${error}`);
    return;
  }
  startHeartbeatServer();
}

initializePlugin();
