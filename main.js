// One global instance owns one watcher/session, even when IINA has several player windows.
function startupTrace(stage) {
  try {
    iina.file.write("@data/startup-debug.txt", `${new Date().toISOString()} ${stage}\n`);
  } catch (_) {
    // Keep diagnostics from affecting playback or plugin initialization.
  }
}

startupTrace("global entry began");
const helperPath = iina.utils.resolvePath("@data/bin/display-helper");
const heartbeatPath = "@data/watcher.heartbeat";
const helperTempPath = `${helperPath}.new`;

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
startupTrace("global entry APIs initialized");

let helperPayload;
let profilesPayload;
try {
  helperPayload = require("./helperPayload.js");
  profilesPayload = require("./profilesPayload.js");
  startupTrace(`resources loaded: ${helperPayload.length} helper chunks`);
} catch (error) {
  startupTrace(`resource load failed: ${error}`);
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
  startupTrace(`invalid saved profiles; using bundled defaults: ${error}`);
  profilesJSON = bundledProfilesJSON;
  iina.preferences.set("profiles_json", profilesJSON);
  iina.preferences.sync();
}

async function installBundledHelper() {
  const dataBin = iina.utils.resolvePath("@data/bin");
  const mkdir = await iina.utils.exec("/bin/mkdir", ["-p", dataBin]);
  if (mkdir.status !== 0) throw new Error(`Cannot create plugin data bin directory: ${mkdir.stderr}`);
  startupTrace("data bin directory created");
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
  startupTrace("helper bytes written");

  const chmod = await iina.utils.exec("/bin/chmod", ["700", helperTempPath]);
  if (chmod.status !== 0) throw new Error(`Cannot mark bundled helper executable: ${chmod.stderr}`);
  const move = await iina.utils.exec("/bin/mv", ["-f", helperTempPath, helperPath]);
  if (move.status !== 0) throw new Error(`Cannot install bundled helper: ${move.stderr}`);
  startupTrace("helper installed");

  iina.file.write("@data/bin/profiles.json", profilesJSON);
  startupTrace("profile file installed");
}

async function startWatcher() {
  try {
    await installBundledHelper();
  } catch (error) {
    startupTrace(`helper installation failed: ${error}`);
    iina.console.error(`[Dell Color Preset] Native helper installation failed: ${error}`);
    return;
  }

  const heartbeat = () => iina.file.write(heartbeatPath, String(Date.now()));
  heartbeat();
  setInterval(heartbeat, 500);
  iina.console.log("[Dell Color Preset] Starting native display watcher.");
  startupTrace("starting native display watcher");
  iina.utils.exec(helperPath, ["watch", iina.utils.resolvePath(heartbeatPath)], undefined, undefined, (data) => {
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

startWatcher();
