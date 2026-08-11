(function(){
  "use strict";
  const CHECK_INTERVAL_MS = 6 * 60 * 60 * 1000;
  const SNOOZE_MS = 24 * 60 * 60 * 1000;
  const LAST_CHECK_KEY = "lavida_update_last_check_v1";
  const SNOOZE_KEY = "lavida_update_snooze_until_v1";
  const DISMISSED_VERSION_KEY = "lavida_update_dismissed_version_v1";
  let currentUpdate = null;
  let progressListener = null;

  const $ = (id) => document.getElementById(id);
  const updater = () => window.Capacitor?.Plugins?.LavidaUpdater || null;
  const appPlugin = () => window.Capacitor?.Plugins?.App || null;
  const esc = (value) => String(value ?? "").replace(/[&<>"']/g,(c)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));

  function installStyles(){
    if($("lavidaUpdaterStyles")) return;
    const style = document.createElement("style");
    style.id = "lavidaUpdaterStyles";
    style.textContent = `
      .update-backdrop{position:fixed;inset:0;z-index:2600;background:rgba(3,22,61,.48);display:grid;place-items:center;padding:18px}
      .update-card{width:min(460px,100%);max-height:calc(100vh - 36px);overflow:auto;background:#fff;border:1px solid #dfe5ee;border-radius:18px;box-shadow:0 24px 70px rgba(0,0,0,.3);padding:20px;color:#071126}
      .update-brand{color:#03163d;font-weight:950;font-size:13px;letter-spacing:.08em;text-transform:uppercase}.update-brand span{color:#d89400}
      .update-card h2{margin:8px 0 8px;color:#03163d;font-size:25px;line-height:1.1}.update-card p{margin:0;color:#59657a;line-height:1.45}
      .update-versions{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:16px 0}.update-version-box{border:1px solid #dfe5ee;border-radius:12px;background:#f8fafc;padding:12px}.update-version-box span{display:block;color:#667085;font-size:12px;font-weight:850}.update-version-box strong{display:block;color:#03163d;font-size:18px;margin-top:3px}
      .update-notes{white-space:pre-line;border:1px solid #f0d57b;background:#fff7d6;color:#5d4300;border-radius:12px;padding:12px;margin:12px 0;line-height:1.45}
      .update-progress{height:9px;border-radius:999px;background:#e5eaf2;overflow:hidden;margin:14px 0 8px}.update-progress span{display:block;height:100%;width:0;background:#f5b821;transition:width .18s}
      .update-message{min-height:22px;font-weight:850;color:#59657a}.update-message.bad{color:#b42318}.update-message.ok{color:#08783e}
      .update-actions{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:16px}.update-actions.single{grid-template-columns:1fr}
      .update-primary,.update-secondary{min-height:50px;border-radius:12px;font-weight:950;padding:0 14px}.update-primary{border:1px solid #03163d;background:#03163d;color:#fff}.update-secondary{border:1px solid #dfe5ee;background:#fff;color:#03163d}.update-primary:disabled,.update-secondary:disabled{opacity:.68;cursor:wait}
      @media(max-width:380px){.update-card{padding:16px}.update-versions,.update-actions{grid-template-columns:1fr}.update-card h2{font-size:22px}}
    `;
    document.head.appendChild(style);
  }

  function ensureDialog(){
    installStyles();
    let dialog = $("lavidaUpdateDialog");
    if(dialog) return dialog;
    dialog = document.createElement("div");
    dialog.id = "lavidaUpdateDialog";
    dialog.className = "update-backdrop hidden";
    dialog.setAttribute("role","dialog");
    dialog.setAttribute("aria-modal","true");
    dialog.setAttribute("aria-labelledby","updateTitle");
    dialog.innerHTML = `
      <section class="update-card">
        <div class="update-brand">LAVIDA <span>Connect</span></div>
        <h2 id="updateTitle">A new LAVIDA Connect update is available</h2>
        <p id="updateIntro">Install the latest version to keep LAVIDA Connect secure and up to date.</p>
        <div class="update-versions">
          <div class="update-version-box"><span>Installed version</span><strong id="updateInstalledVersion">-</strong></div>
          <div class="update-version-box"><span>Latest version</span><strong id="updateLatestVersion">-</strong></div>
        </div>
        <p id="updateSize" class="hidden"></p>
        <div id="updateNotes" class="update-notes"></div>
        <div id="updateProgressWrap" class="update-progress hidden"><span id="updateProgressBar"></span></div>
        <p id="updateMessage" class="update-message" aria-live="polite"></p>
        <div id="updateActions" class="update-actions">
          <button id="updateNowButton" class="update-primary" type="button">Update Now</button>
          <button id="updateLaterButton" class="update-secondary" type="button">Later</button>
        </div>
      </section>
    `;
    document.body.appendChild(dialog);
    $("updateNowButton").addEventListener("click",async()=>{
      const plugin = updater();
      if($("updateNowButton").dataset.action === "settings" && plugin){
        await plugin.openInstallPermissionSettings();
        return;
      }
      startUpdate();
    });
    $("updateLaterButton").addEventListener("click",snoozeUpdate);
    return dialog;
  }

  function formatBytes(value){
    const bytes = Number(value || 0);
    if(!bytes) return "";
    if(bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  function friendlyError(error){
    const code = error?.code || error?.data?.code || "";
    const message = error?.message || error?.data?.message || "";
    if(code === "permission_required" || code === "permissionRequired") return "Android installation permission is required before LAVIDA Connect can update.";
    if(code === "no_internet") return "No internet connection. Connect and try again.";
    if(code === "release_server_unavailable") return "LAVIDA update server is unavailable. Please try again.";
    if(code === "download_interrupted") return "The update download was interrupted. Please retry.";
    if(code === "invalid_checksum" || code === "invalid_apk") return "The downloaded update is corrupted or invalid. Please retry.";
    if(code === "insufficient_storage") return "There is not enough device storage to download this update.";
    if(code === "signature_mismatch") return "This APK is not signed with the official LAVIDA certificate and was blocked.";
    if(code === "untrusted_release_url" || code === "insecure_release_url") return "LAVIDA refused an untrusted update location.";
    if(/network|failed to fetch|unable to resolve|timeout/i.test(message)) return "No internet connection. Connect and try again.";
    return message || "LAVIDA could not complete the update. Please retry.";
  }

  function setInlineStatus(text,type){
    const box = $("updateInlineStatus");
    if(!box) return;
    box.textContent = text || "";
    box.className = `notice ${type === "bad" ? "bad" : ""} ${text ? "" : "hidden"}`.trim();
  }

  function setInstalledVersion(version){
    const target = $("installedAppVersion");
    if(target) target.textContent = version ? `${version.versionName} (${version.versionCode})` : "Web preview";
  }

  function showUpdatePrompt(result, manual){
    const manifest = result.manifest || {};
    const installed = result.installed || {};
    const mandatory = Boolean(result.mandatory);
    currentUpdate = result;
    ensureDialog();
    $("updateTitle").textContent = mandatory ? "This version is no longer supported. Update to continue." : `LAVIDA Connect ${manifest.latestVersionName || ""} is available.`;
    $("updateIntro").textContent = mandatory ? "Install the latest LAVIDA Connect release to continue using the app." : "Install the latest LAVIDA Connect release for improvements and fixes.";
    $("updateInstalledVersion").textContent = `${installed.versionName || "Unknown"} (${installed.versionCode || "-"})`;
    $("updateLatestVersion").textContent = `${manifest.latestVersionName || "Unknown"} (${manifest.latestVersionCode || "-"})`;
    $("updateNotes").textContent = manifest.releaseNotes || "LAVIDA Connect improvements and fixes.";
    const size = formatBytes(manifest.updateSizeBytes);
    $("updateSize").textContent = size ? `Update size: ${size}` : "";
    $("updateSize").classList.toggle("hidden", !size);
    $("updateProgressWrap").classList.add("hidden");
    $("updateProgressBar").style.width = "0";
    setUpdateMessage("", "");
    $("updateLaterButton").classList.toggle("hidden", mandatory);
    $("updateActions").classList.toggle("single", mandatory);
    $("lavidaUpdateDialog").classList.remove("hidden");
    document.body.classList.toggle("update-locked", mandatory);
    if(!manual && !mandatory) localStorage.setItem(DISMISSED_VERSION_KEY, "");
  }

  function closeUpdatePrompt(){
    const dialog = $("lavidaUpdateDialog");
    if(dialog) dialog.classList.add("hidden");
    document.body.classList.remove("update-locked");
  }

  function setUpdateMessage(text,type){
    const message = $("updateMessage");
    if(!message) return;
    message.textContent = text || "";
    message.className = `update-message ${type || ""}`.trim();
  }

  function shouldCheck(manual){
    if(manual) return true;
    const last = Number(localStorage.getItem(LAST_CHECK_KEY) || 0);
    return Date.now() - last > CHECK_INTERVAL_MS;
  }

  function isSnoozed(result, manual){
    if(manual || result.mandatory) return false;
    const until = Number(localStorage.getItem(SNOOZE_KEY) || 0);
    const dismissedVersion = localStorage.getItem(DISMISSED_VERSION_KEY);
    return Date.now() < until && dismissedVersion === String(result.manifest?.latestVersionCode || "");
  }

  async function checkForUpdates(options={}){
    const manual = Boolean(options.manual);
    const plugin = updater();
    if(!plugin){
      setInstalledVersion(null);
      if(manual) setInlineStatus("Update checks are available in the installed Android app.", "bad");
      return;
    }
    if(!shouldCheck(manual)) return;
    if(manual) setInlineStatus("Checking for LAVIDA Connect updates...", "");
    try{
      const status = await plugin.getPendingInstallStatus();
      setInstalledVersion(status.installed);
      if(status.status === "pending" && status.canInstallFromThisSource){
        const continued = await plugin.continuePendingInstall();
        if(continued.status === "installationStarted") setInlineStatus("Android installer opened. Complete the update installation.", "");
        return;
      }
      const result = await plugin.checkForUpdate();
      localStorage.setItem(LAST_CHECK_KEY, String(Date.now()));
      setInstalledVersion(result.installed);
      if(result.updateAvailable && !isSnoozed(result, manual)){
        showUpdatePrompt(result, manual);
        if(manual) setInlineStatus("", "");
      }else if(manual){
        setInlineStatus("LAVIDA Connect is already up to date.", "");
      }
    }catch(error){
      if(manual) setInlineStatus(friendlyError(error), "bad");
    }
  }

  async function startUpdate(){
    const plugin = updater();
    if(!plugin || !currentUpdate) return;
    $("updateNowButton").disabled = true;
    $("updateLaterButton").disabled = true;
    $("updateNowButton").dataset.action = "update";
    $("updateNowButton").textContent = "Preparing...";
    $("updateProgressWrap").classList.remove("hidden");
    setUpdateMessage("Downloading the official LAVIDA Connect APK...", "");
    try{
      if(progressListener?.remove) progressListener.remove();
      progressListener = await plugin.addListener("downloadProgress",(progress)=>{
        const percent = Number(progress.percent || 0);
        $("updateProgressBar").style.width = `${Math.max(2, percent)}%`;
        setUpdateMessage(progress.totalBytes > 0 ? `Downloading... ${percent}%` : `Downloading... ${formatBytes(progress.downloadedBytes)}`, "");
      });
      const result = await plugin.downloadUpdate();
      if(result.status === "permissionRequired"){
        setUpdateMessage("Android needs permission to install updates from LAVIDA Connect. Open settings, allow this source, then return here.", "bad");
        $("updateNowButton").textContent = "Open Settings";
        $("updateNowButton").dataset.action = "settings";
        $("updateNowButton").disabled = false;
        $("updateLaterButton").disabled = false;
        return;
      }
      if(result.status === "installationStarted"){
        $("updateNowButton").textContent = "Installer Opened";
        setUpdateMessage("Complete the Android installation screen. Your login and data will be preserved.", "ok");
      }else if(result.status === "current"){
        setUpdateMessage("LAVIDA Connect is already up to date.", "ok");
        setTimeout(closeUpdatePrompt, 1200);
      }
    }catch(error){
      setUpdateMessage(friendlyError(error), "bad");
      $("updateNowButton").disabled = false;
      $("updateLaterButton").disabled = false;
      $("updateNowButton").textContent = "Retry";
    }
  }

  function snoozeUpdate(){
    if(currentUpdate?.mandatory) return;
    localStorage.setItem(SNOOZE_KEY, String(Date.now() + SNOOZE_MS));
    localStorage.setItem(DISMISSED_VERSION_KEY, String(currentUpdate?.manifest?.latestVersionCode || ""));
    closeUpdatePrompt();
  }

  async function handleAppResume(){
    const plugin = updater();
    if(!plugin) return;
    try{
      const status = await plugin.getPendingInstallStatus();
      setInstalledVersion(status.installed);
      if(status.status === "pending"){
        if(status.canInstallFromThisSource){
          const continued = await plugin.continuePendingInstall();
          if(continued.status === "installationStarted") setInlineStatus("Android installer opened. Complete the LAVIDA Connect update.", "");
        }else{
          setInlineStatus("Installation permission is still required to finish the LAVIDA Connect update.", "bad");
        }
      }
    }catch(error){}
    checkForUpdates({manual:false});
  }

  function init(){
    installStyles();
    const button = $("checkUpdatesButton");
    if(button) button.addEventListener("click",()=>checkForUpdates({manual:true}));
    checkForUpdates({manual:false});
    const app = appPlugin();
    if(app?.addListener){
      app.addListener("appStateChange",(state)=>{if(state.isActive) handleAppResume();});
    }
  }

  if(document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
  window.LavidaUpdaterUI = {checkForUpdates};
})();
