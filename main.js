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

  iina.file.write("@data/bin/profiles.json", JSON.stringify(profilesPayload));
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
