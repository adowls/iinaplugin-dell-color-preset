// One global instance owns one watcher/session, even when IINA has several player windows.
const helperPayload = require("./helperPayload.js");
const profilesPayload = require("./profilesPayload.js");
const helperPath = iina.utils.resolvePath("@data/bin/display-helper");
const heartbeatPath = "@data/watcher.heartbeat";
const helperTempPath = `${helperPath}.new`;

iina.console.log(`[Dell Color Preset] Plugin data directory: ${iina.utils.resolvePath("@data")}`);

async function installBundledHelper() {
  const dataBin = iina.utils.resolvePath("@data/bin");
  const mkdir = await iina.utils.exec("/bin/mkdir", ["-p", dataBin]);
  if (mkdir.status !== 0) throw new Error(`Cannot create plugin data bin directory: ${mkdir.stderr}`);
  const removeStaleTemp = await iina.utils.exec("/bin/rm", ["-f", helperTempPath]);
  if (removeStaleTemp.status !== 0) throw new Error(`Cannot clear temporary helper file: ${removeStaleTemp.stderr}`);

  const handle = iina.file.handle(helperTempPath, "write");
  try {
    handle.write(helperPayload);
  } finally {
    handle.close();
  }

  const chmod = await iina.utils.exec("/bin/chmod", ["700", helperTempPath]);
  if (chmod.status !== 0) throw new Error(`Cannot mark bundled helper executable: ${chmod.stderr}`);
  const move = await iina.utils.exec("/bin/mv", ["-f", helperTempPath, helperPath]);
  if (move.status !== 0) throw new Error(`Cannot install bundled helper: ${move.stderr}`);

  iina.file.write("@data/bin/profiles.json", JSON.stringify(profilesPayload));
}

async function startWatcher() {
  try {
    await installBundledHelper();
  } catch (error) {
    iina.console.error(`[Dell Color Preset] Native helper installation failed: ${error}`);
    return;
  }

  const heartbeat = () => iina.file.write(heartbeatPath, String(Date.now()));
  heartbeat();
  setInterval(heartbeat, 500);
  iina.console.log("[Dell Color Preset] Starting native display watcher.");
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
