(function(){
  "use strict";

  const SETTINGS = [
    ["service_updates","Service Updates","Quotes, projects and Digital or Document service updates."],
    ["order_delivery","Orders & Delivery","Printing, pickup, delivery and marketplace order changes."],
    ["invoice_payment","Invoices & Payments","Invoices, quotes, payments and payment problems."],
    ["games_tournaments","Games & Tournaments","Chess 365 tournaments, matches and player updates."],
    ["promotions","Promotions","Optional offers and relevant campaigns."],
    ["app_updates","Product/App Updates","Major improvements and required update notices."]
  ];
  const DEFAULT_PREFS = {
    service_updates:true,
    order_delivery:true,
    invoice_payment:true,
    games_tournaments:true,
    promotions:false,
    app_updates:true,
    push_enabled:false
  };
  const AUTH_RETURN_KEY = "lavida_auth_return_to";
  const DEVICE_ID_KEY = "lavida_device_installation_id";
  const NATIVE_TOKEN_KEY = "lavida_native_push_token";
  const DEFAULT_DESTINATION = "marketplace.html#notifications";
  let activeFilter = "all";
  let realtimeChannel = null;
  const TOAST_DURATION = 3000;
  const toastQueue = [];
  const queuedToastKeys = new Set();
  let activeToast = null;
  let toastTimer = null;
  let toastFadeTimer = null;
  let toastStartedAt = 0;
  let toastRemaining = TOAST_DURATION;
  let toastHovered = false;
  let toastFocused = false;

  function byId(id){return document.getElementById(id)}
  function html(value){return typeof esc === "function" ? esc(value) : String(value ?? "").replace(/[&<>"']/g,(c)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
  function client(){return typeof db !== "undefined" ? db : null}
  function session(){return typeof authSession !== "undefined" ? authSession : null}
  function deviceInstallationId(){
    try{
      let value = localStorage.getItem(DEVICE_ID_KEY);
      if(!value){
        value = crypto?.randomUUID?.() || `device-${Date.now()}-${Math.random().toString(16).slice(2)}`;
        localStorage.setItem(DEVICE_ID_KEY, value);
      }
      return value;
    }catch(error){
      return "";
    }
  }
  function isNativeAndroidApp(){
    try{
      const capacitor = window.Capacitor;
      if(capacitor?.isNativePlatform?.() && capacitor?.getPlatform?.() === "android")return true;
      if(capacitor?.getPlatform?.() === "android" && !/^https?:/i.test(location.protocol))return true;
    }catch(error){}
    return Boolean(window.LavidaAndroidPush || window.AndroidPush || window.LavidaNativePushToken);
  }
  function nativeTokenFrom(value){
    if(!value)return "";
    if(typeof value === "string")return value.trim();
    return String(value.token || value.fcm_token || value.fcmToken || "").trim();
  }
  async function currentSession(){
    if(session()?.user)return session();
    if(typeof refreshAuthSession === "function")return await refreshAuthSession();
    const database = client();
    if(!database)return null;
    const {data} = await database.auth.getSession();
    return data?.session || null;
  }
  function icon(name){
    const paths = {
      invoice:'<path d="M6 3h12v18l-3-2-3 2-3-2-3 2z"></path><path d="M9 8h6M9 12h6M9 16h3"></path>',
      payment:'<path d="M3 7h18v10H3z"></path><path d="M3 10h18"></path><path d="m8 15 2 2 4-5"></path>',
      delivery:'<path d="M21 16V8l-9-5-9 5v8l9 5z"></path><path d="m3.3 7.5 8.7 5 8.7-5"></path><path d="M12 22V12"></path>',
      printing:'<path d="M6 9V3h12v6"></path><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"></path><path d="M6 14h12v7H6z"></path>',
      service:'<path d="M4 5h16v11H4z"></path><path d="M8 21h8M12 16v5"></path>',
      document:'<path d="M6 3h8l4 4v14H6z"></path><path d="M14 3v5h5"></path><path d="M9 13h6M9 17h5"></path>',
      games:'<path d="M8 21h8"></path><path d="M12 17v4"></path><path d="M7 4h10l-1 9H8z"></path><path d="M7 8H4a3 3 0 0 0 3 3"></path><path d="M17 8h3a3 3 0 0 1-3 3"></path>',
      promotion:'<path d="M20.6 13.4 13.4 20.6a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8Z"></path><circle cx="8" cy="8" r="1"></circle>',
      system:'<path d="M12 3v4"></path><path d="M12 17v4"></path><path d="M3 12h4"></path><path d="M17 12h4"></path><path d="m5.6 5.6 2.8 2.8"></path><path d="m15.6 15.6 2.8 2.8"></path><path d="m18.4 5.6-2.8 2.8"></path><path d="m8.4 15.6-2.8 2.8"></path>',
      bell:'<path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9"></path><path d="M10 21h4"></path>',
      check:'<path d="m5 12 4 4L19 6"></path>',
      mark:'<path d="M20 6 9 17l-5-5"></path>'
    };
    return `<svg viewBox="0 0 24 24" fill="none" stroke-width="2">${paths[name] || paths.bell}</svg>`;
  }
  function categoryLabel(row){
    return ({
      service:"Service",
      order_delivery:"Orders",
      invoice_payment:"Invoice",
      games:"Games 365",
      marketplace:"Market 365",
      marketing:"Promotion",
      system:"LAVIDA",
      security:"Security"
    })[row?.category] || row?.service_label || "LAVIDA";
  }
  function iconFor(row){
    const text = `${row?.notification_type || ""} ${row?.category || ""} ${row?.service_label || ""}`.toLowerCase();
    if(/invoice|quote/.test(text))return "invoice";
    if(/payment/.test(text))return "payment";
    if(/delivery|collection|pickup|order/.test(text))return row?.service_label === "Print 365" ? "printing" : "delivery";
    if(/print/.test(text))return "printing";
    if(/document|profile|cv/.test(text))return "document";
    if(/chess|game|tournament|match/.test(text))return "games";
    if(/promo|offer|campaign|discount/.test(text))return "promotion";
    if(/update|release|required/.test(text))return "system";
    return "service";
  }
  function timeAgo(value){
    const date = value ? new Date(value) : new Date();
    const diff = Math.max(0, Date.now() - date.getTime());
    const minute = 60000, hour = 60 * minute, day = 24 * hour;
    if(diff < minute)return "Just now";
    if(diff < hour)return `${Math.floor(diff / minute)} min ago`;
    if(diff < day)return `${Math.floor(diff / hour)} hr ago`;
    if(diff < 2 * day)return "Yesterday";
    return date.toLocaleDateString(undefined,{month:"short",day:"numeric"});
  }
  function setBadge(count){
    if(typeof setNotificationBadge === "function"){
      setNotificationBadge(count);
      return;
    }
    const badge = byId("notificationBadge");
    if(!badge)return;
    const safe = Math.max(0, Number(count || 0));
    badge.textContent = safe > 99 ? "99+" : String(safe);
    badge.classList.toggle("hidden", safe <= 0);
  }
  function selfFilter(user){
    if(!user)return "";
    const clauses = [`user_id.eq.${user.id}`];
    if(user.email)clauses.push(`email.eq.${user.email}`);
    return clauses.join(",");
  }
  async function refreshBadge(){
    const database = client();
    const current = await currentSession();
    if(!database || !current?.user){setBadge(0);return 0;}
    try{
      const {count,error} = await database
        .from("notifications")
        .select("id",{count:"exact",head:true})
        .or(selfFilter(current.user))
        .eq("is_read", false)
        .is("archived_at", null);
      if(error)throw error;
      setBadge(count || 0);
      return count || 0;
    }catch(error){
      setBadge(0);
      return 0;
    }
  }
  async function ensurePreferences(){
    const database = client();
    const current = await currentSession();
    if(!database || !current?.user)return null;
    try{
      const {data,error} = await database.from("notification_preferences").select("*").eq("user_id", current.user.id).maybeSingle();
      if(error)throw error;
      if(data)return data;
      const payload = {user_id:current.user.id, ...DEFAULT_PREFS};
      const inserted = await database.from("notification_preferences").insert(payload).select("*").single();
      if(inserted.error)throw inserted.error;
      return inserted.data;
    }catch(error){
      return {...DEFAULT_PREFS, user_id:current.user.id};
    }
  }
  async function loadConfig(){
    const database = client();
    if(!database)return {};
    try{
      const {data,error} = await database.from("notification_public_config").select("*").eq("id",1).maybeSingle();
      if(error)throw error;
      return data || {};
    }catch(error){
      return {};
    }
  }
  function renderShell(){
    const root = byId("notifications");
    if(root && !byId("notificationCentreRoot")){
      root.innerHTML = `<div id="notificationCentreRoot" class="notification-centre">
        <div class="notification-centre-head">
          <div><h2>Notifications</h2><p>Updates about orders, invoices, projects and LAVIDA services.</p></div>
          <button id="notificationMarkAllButton" class="notification-action-icon" type="button" aria-label="Mark all as read">${icon("mark")}</button>
        </div>
        <section id="notificationPermissionCard" class="notification-permission-card hidden"></section>
        <div class="notification-tabs" role="tablist">
          <button class="notification-tab active" type="button" data-notification-filter="all">All</button>
          <button class="notification-tab" type="button" data-notification-filter="unread">Unread</button>
        </div>
        <div id="notificationList" class="notification-list"><div class="notice">Loading notifications...</div></div>
      </div>`;
    }
    injectSettings();
    injectAdminLinks();
  }
  function injectSettings(){
    const account = byId("contact");
    if(!account || byId("notificationSettingsCard"))return;
    const card = document.createElement("section");
    card.id = "notificationSettingsCard";
    card.className = "notification-settings-card admin-tools";
    card.innerHTML = `<h3>Notification Settings</h3><div id="notificationPhoneStatus" class="notification-phone-status"><div><strong>Phone Notifications</strong><span>Checking...</span></div><button class="notification-secondary" type="button" data-enable-phone-notifications>Enable</button></div><div id="notificationPreferenceRows"></div>`;
    const anchor = byId("appUpdateCard") || account.firstElementChild;
    if(anchor && anchor.parentNode)anchor.parentNode.insertBefore(card, anchor.nextSibling);
    else account.appendChild(card);
  }
  function injectAdminLinks(){
    const tools = byId("adminToolsSection");
    if(tools && !byId("notificationAdminAccountLink")){
      const link = document.createElement("a");
      link.id = "notificationAdminAccountLink";
      link.href = "notifications-admin.html";
      link.className = "notification-admin-link";
      link.innerHTML = `Notifications Admin <span>Open</span>`;
      tools.appendChild(link);
    }
    const menu = byId("lavidaAdminMenuSection");
    if(menu && !byId("notificationAdminMenuLink")){
      const link = document.createElement("a");
      link.id = "notificationAdminMenuLink";
      link.href = "notifications-admin.html";
      link.setAttribute("data-menu-destination","notifications-admin.html");
      link.textContent = "Notifications Admin";
      menu.appendChild(link);
    }
  }
  async function renderPermissionCard(){
    const card = byId("notificationPermissionCard");
    if(!card)return;
    const prefs = await ensurePreferences();
    const config = await loadConfig();
    const permission = typeof Notification === "undefined" ? "unsupported" : Notification.permission;
    if(isNativeAndroidApp()){
      card.classList.add("hidden");
      return;
    }
    if(!prefs || prefs.push_enabled || permission === "granted"){
      card.classList.add("hidden");
      return;
    }
    if(!config.vapid_public_key){
      card.classList.add("hidden");
      return;
    }
    if(permission === "denied"){
      card.innerHTML = `<span class="notification-permission-icon">${icon("bell")}</span><div><h3>Phone notifications are off</h3><p>You can allow LAVIDA notifications in your browser or phone settings, then enable them here.</p></div>`;
      card.classList.remove("hidden");
      return;
    }
    card.innerHTML = `<span class="notification-permission-icon">${icon("bell")}</span><div><h3>Stay updated</h3><p>Get notified when orders are ready, invoices are issued, projects are updated and tournaments are announced.</p><div class="notification-permission-actions"><button class="notification-primary" type="button" data-enable-phone-notifications>Enable Notifications</button><button class="notification-secondary" type="button" data-dismiss-phone-notifications>Maybe Later</button></div></div>`;
    card.classList.remove("hidden");
  }
  function renderEmpty(){
    const list = byId("notificationList");
    if(!list)return;
    list.innerHTML = `<div class="notification-empty"><span class="notification-permission-icon">${icon("check")}</span><h3>You're all caught up</h3><p>Updates about your orders, invoices, projects and LAVIDA services will appear here.</p></div>`;
  }
  function renderItems(rows){
    const list = byId("notificationList");
    if(!list)return;
    if(!rows.length){renderEmpty();return;}
    list.innerHTML = rows.map((row)=>`<article class="notification-item ${row.is_read ? "" : "unread"}" data-notification-id="${html(row.id)}">
      <span class="notification-item-icon">${icon(iconFor(row))}</span>
      <div>
        <h3>${html(row.title)}</h3>
        <p>${html(row.body)}</p>
        <div class="notification-meta">${row.is_read ? "" : '<span class="notification-read-dot" aria-label="Unread"></span>'}<span class="notification-category">${html(row.service_label || categoryLabel(row))}</span><span>${html(timeAgo(row.created_at))}</span></div>
        <div class="notification-item-actions">${row.action_url ? `<button class="primary" type="button" data-open-notification="${html(row.id)}">${html(row.action_label || "View")}</button>` : ""}${row.is_read ? "" : `<button type="button" data-read-notification="${html(row.id)}">Mark read</button>`}</div>
      </div>
    </article>`).join("");
  }
  async function loadNotifications(){
    renderShell();
    const list = byId("notificationList");
    const database = client();
    const current = await currentSession();
    if(!database || !current?.user){
      if(list)list.innerHTML = `<div class="notice">Sign in to view your LAVIDA notifications.</div>`;
      setBadge(0);
      return;
    }
    await renderPermissionCard();
    try{
      let query = database
        .from("notifications")
        .select("*")
        .or(selfFilter(current.user))
        .is("archived_at", null)
        .order("created_at",{ascending:false})
        .limit(80);
      if(activeFilter === "unread")query = query.eq("is_read", false);
      const {data,error} = await query;
      if(error)throw error;
      renderItems(data || []);
      await refreshBadge();
      setupRealtime(current.user);
    }catch(error){
      if(list)list.innerHTML = `<div class="notice bad">Notifications are being installed. Please try again shortly.</div>`;
      setBadge(0);
    }
  }
  async function renderSettings(){
    const container = byId("notificationPreferenceRows");
    const phone = byId("notificationPhoneStatus");
    if(!container || !phone)return;
    const prefs = await ensurePreferences();
    const config = await loadConfig();
    const permission = typeof Notification === "undefined" ? "unsupported" : Notification.permission;
    if(isNativeAndroidApp()){
      const nativeActive = await currentNativePushStatus();
      phone.innerHTML = `<div><strong>Android App Notifications</strong><span>${nativeActive ? "Enabled" : "Not Enabled"}</span></div><button class="notification-secondary" type="button" disabled>${nativeActive ? "Active" : "Use app prompt"}</button>`;
      container.innerHTML = SETTINGS.map(([key,title,copy])=>`<label class="notification-setting-row"><span><b>${html(title)}</b><small>${html(copy)}</small></span><span class="notification-switch"><input type="checkbox" data-notification-pref="${html(key)}" ${prefs?.[key] !== false ? "checked" : ""}><span></span></span></label>`).join("");
      return;
    }
    const phoneEnabled = Boolean(prefs?.push_enabled) && permission === "granted";
    phone.innerHTML = `<div><strong>Phone Notifications</strong><span>${phoneEnabled ? "Enabled" : permission === "denied" ? "Blocked in device settings" : "Not Enabled"}</span></div><button class="notification-secondary" type="button" data-enable-phone-notifications ${config.vapid_public_key ? "" : "disabled"}>${phoneEnabled ? "Refresh" : "Enable Phone Notifications"}</button>`;
    if(!config.vapid_public_key){
      phone.querySelector("span").textContent = "Not available on this device yet";
    }
    container.innerHTML = SETTINGS.map(([key,title,copy])=>`<label class="notification-setting-row"><span><b>${html(title)}</b><small>${html(copy)}</small></span><span class="notification-switch"><input type="checkbox" data-notification-pref="${html(key)}" ${prefs?.[key] !== false ? "checked" : ""}><span></span></span></label>`).join("");
  }
  async function markRead(ids){
    const database = client();
    if(!database)return;
    try{
      if(database.rpc){
        await database.rpc("mark_lavida_notifications_read",{p_notification_ids:ids || null});
      }else if(ids?.length){
        await database.from("notifications").update({is_read:true,read_at:new Date().toISOString()}).in("id",ids);
      }
    }catch(error){
      if(ids?.length)await database.from("notifications").update({is_read:true,read_at:new Date().toISOString()}).in("id",ids);
    }
    await refreshBadge();
    await loadNotifications();
  }
  async function openNotification(id){
    const database = client();
    let row = null;
    try{
      const {data} = await database.from("notifications").select("*").eq("id",id).maybeSingle();
      row = data || null;
    }catch(error){}
    await markRead([id]);
    const destination = row?.action_url || DEFAULT_DESTINATION;
    if(!destination)return;
    if(destination.startsWith("#") && typeof navigateRoute === "function"){
      navigateRoute(destination.slice(1),{resetScroll:true});
      return;
    }
    if(/^marketplace\.html#/i.test(destination) && typeof navigateRoute === "function"){
      navigateRoute(destination.split("#")[1] || "home",{resetScroll:true});
      return;
    }
    location.href = destination;
  }
  function urlBase64ToUint8Array(base64String){
    const padding = "=".repeat((4 - base64String.length % 4) % 4);
    const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
    const rawData = atob(base64);
    const outputArray = new Uint8Array(rawData.length);
    for(let i = 0; i < rawData.length; ++i)outputArray[i] = rawData.charCodeAt(i);
    return outputArray;
  }
  async function enablePhoneNotifications(){
    const database = client();
    const current = await currentSession();
    if(!database || !current?.user){
      sessionStorage.setItem(AUTH_RETURN_KEY, DEFAULT_DESTINATION);
      location.href = `signin.html?returnTo=${encodeURIComponent(DEFAULT_DESTINATION)}`;
      return;
    }
    if(!("serviceWorker" in navigator) || !("PushManager" in window) || typeof Notification === "undefined"){
      showInlinePushNotice("Phone notifications are not supported on this device or browser.");
      return;
    }
    const config = await loadConfig();
    if(!config.vapid_public_key){
      showInlinePushNotice("Phone notifications are not available yet. You will still receive updates inside LAVIDA.");
      return;
    }
    const permission = await Notification.requestPermission();
    if(permission !== "granted"){
      await database.from("notification_preferences").upsert({user_id:current.user.id,push_enabled:false,push_denied_at:new Date().toISOString()},{onConflict:"user_id"});
      await renderPermissionCard();
      await renderSettings();
      return;
    }
    const registration = await navigator.serviceWorker.register("./gm-offline-sw.js");
    const existing = await registration.pushManager.getSubscription();
    const subscription = existing || await registration.pushManager.subscribe({
      userVisibleOnly:true,
      applicationServerKey:urlBase64ToUint8Array(config.vapid_public_key)
    });
    const payload = subscription.toJSON();
    const endpoint = payload.endpoint;
    const keys = payload.keys || {};
    await database.from("push_subscriptions").upsert({
      user_id:current.user.id,
      endpoint,
      p256dh:keys.p256dh || "",
      auth:keys.auth || "",
      auth_key:keys.auth || "",
      platform:"web",
      installation_id:deviceInstallationId(),
      user_agent:navigator.userAgent,
      active:true,
      last_used_at:new Date().toISOString()
    },{onConflict:"endpoint"});
    await database.from("notification_preferences").upsert({user_id:current.user.id,push_enabled:true},{onConflict:"user_id"});
    await renderPermissionCard();
    await renderSettings();
  }
  async function currentNativePushStatus(){
    if(!isNativeAndroidApp())return false;
    const database = client();
    const current = await currentSession();
    if(!database || !current?.user)return false;
    const token = localStorage.getItem(NATIVE_TOKEN_KEY) || nativeTokenFrom(window.LavidaNativePushToken);
    const installationId = deviceInstallationId();
    try{
      let query = database.from("mobile_push_tokens").select("id",{count:"exact",head:true}).eq("user_id",current.user.id).eq("active",true);
      if(token)query = query.eq("fcm_token", token);
      else if(installationId)query = query.eq("installation_id", installationId);
      const {count,error} = await query;
      if(error)throw error;
      return Number(count || 0) > 0;
    }catch(error){
      return false;
    }
  }
  async function registerAndroidPushToken(tokenOrPayload, extra = {}){
    const database = client();
    const current = await currentSession();
    const details = typeof tokenOrPayload === "string" ? {token:tokenOrPayload, ...extra} : {...(tokenOrPayload || {}), ...extra};
    const token = nativeTokenFrom(details);
    if(!database || !current?.user || !token)return null;
    const installationId = details.installation_id || details.installationId || deviceInstallationId();
    const {data,error} = await database.rpc("register_lavida_mobile_push_token",{
      p_fcm_token:token,
      p_platform:details.platform || "android",
      p_installation_id:installationId,
      p_device_label:details.device_label || details.deviceLabel || "Android app",
      p_app_version:details.app_version || details.appVersion || null
    });
    if(error)throw error;
    try{localStorage.setItem(NATIVE_TOKEN_KEY, token)}catch(error){}
    await renderSettings();
    return data;
  }
  async function deactivateAndroidPushToken(tokenOrPayload){
    const database = client();
    const current = await currentSession();
    if(!database || !current?.user)return 0;
    const token = nativeTokenFrom(tokenOrPayload) || localStorage.getItem(NATIVE_TOKEN_KEY) || "";
    const installationId = (typeof tokenOrPayload === "object" && (tokenOrPayload.installation_id || tokenOrPayload.installationId)) || deviceInstallationId();
    try{
      const {data} = await database.rpc("deactivate_lavida_mobile_push_token",{
        p_fcm_token:token || null,
        p_installation_id:installationId || null
      });
      return Number(data || 0);
    }finally{
      try{localStorage.removeItem(NATIVE_TOKEN_KEY)}catch(error){}
    }
  }
  async function prepareLogout(){
    const database = client();
    const current = await currentSession();
    if(!database || !current?.user)return;
    await deactivateAndroidPushToken().catch(()=>0);
    if(!("serviceWorker" in navigator))return;
    try{
      const registration = await navigator.serviceWorker.ready;
      const subscription = await registration.pushManager?.getSubscription?.();
      if(subscription?.endpoint){
        await database.from("push_subscriptions").update({active:false}).eq("endpoint",subscription.endpoint).eq("user_id",current.user.id);
      }
    }catch(error){}
  }
  function showInlinePushNotice(message){
    const card = byId("notificationPermissionCard");
    if(card){
      card.innerHTML = `<span class="notification-permission-icon">${icon("bell")}</span><div><h3>Phone notifications</h3><p>${html(message)}</p></div>`;
      card.classList.remove("hidden");
    }
    const phone = byId("notificationPhoneStatus");
    if(phone){
      const status = phone.querySelector("span");
      if(status)status.textContent = message;
    }
  }
  async function updatePreference(input){
    const database = client();
    const current = await currentSession();
    if(!database || !current?.user)return;
    const key = input.dataset.notificationPref;
    if(!SETTINGS.some(([field])=>field === key))return;
    const payload = {user_id:current.user.id, [key]:input.checked};
    await database.from("notification_preferences").upsert(payload,{onConflict:"user_id"});
    await renderSettings();
  }
  function toastKey(item){
    return item.key || `${item.type || "info"}:${item.title || ""}:${item.message || item.body || ""}`;
  }
  function updateToastOffset(){
    const toast = byId("notificationToast");
    if(!toast)return;
    const headers = [...document.querySelectorAll("header,.topbar,.app-header,[data-app-header]")];
    const bottom = headers.reduce((max,node)=>{
      const style = getComputedStyle(node);
      if(style.display === "none" || style.visibility === "hidden")return max;
      const rect = node.getBoundingClientRect();
      return rect.bottom > 0 && rect.top <= 1 ? Math.max(max,rect.bottom) : max;
    },0);
    document.documentElement.style.setProperty("--lavida-toast-top",`${Math.max(12,Math.ceil(bottom)+12)}px`);
  }
  function clearToastTimers(){
    clearTimeout(toastTimer);
    clearTimeout(toastFadeTimer);
    toastTimer = null;
    toastFadeTimer = null;
  }
  function pauseToast(){
    const toast = byId("notificationToast");
    if(!toast || !activeToast || toast.classList.contains("leaving"))return;
    toastRemaining = Math.max(0,toastRemaining-(Date.now()-toastStartedAt));
    clearTimeout(toastTimer);
    toastTimer = null;
    toast.classList.add("paused");
    toast.style.setProperty("--lavida-toast-remaining",`${toastRemaining}ms`);
  }
  function resumeToast(){
    const toast = byId("notificationToast");
    if(!toast || !activeToast || toastHovered || toastFocused || toast.classList.contains("leaving"))return;
    toast.classList.remove("paused");
    toastStartedAt = Date.now();
    toast.style.setProperty("--lavida-toast-remaining",`${toastRemaining}ms`);
    toastTimer = setTimeout(dismissToast,toastRemaining);
  }
  function dismissToast(){
    const toast = byId("notificationToast");
    if(!toast || !activeToast)return;
    clearToastTimers();
    toast.classList.remove("visible","paused");
    toast.classList.add("leaving");
    const dismissedKey = toastKey(activeToast);
    activeToast = null;
    queuedToastKeys.delete(dismissedKey);
    toastFadeTimer = setTimeout(()=>{
      toast.classList.remove("leaving");
      toastFadeTimer = null;
      showNextToast();
    },220);
  }
  function ensureToast(){
    let toast = byId("notificationToast");
    if(!toast){
      toast = document.createElement("div");
      toast.id = "notificationToast";
      toast.className = "notification-toast";
      toast.setAttribute("role","status");
      toast.setAttribute("aria-live","polite");
      toast.setAttribute("aria-atomic","true");
      document.body.appendChild(toast);
      toast.addEventListener("mouseenter",()=>{toastHovered=true;pauseToast()});
      toast.addEventListener("mouseleave",()=>{toastHovered=false;resumeToast()});
      toast.addEventListener("focusin",()=>{toastFocused=true;pauseToast()});
      toast.addEventListener("focusout",()=>{toastFocused=toast.contains(document.activeElement);resumeToast()});
    }
    return toast;
  }
  function showNextToast(){
    if(activeToast || toastFadeTimer || !toastQueue.length)return;
    const item = toastQueue.shift();
    activeToast = item;
    const toast = ensureToast();
    const type = ["success","error","warning","info"].includes(item.type) ? item.type : "info";
    const glyph = type === "success" ? "check" : type === "error" ? "!" : type === "warning" ? "!" : "i";
    const action = item.actionLabel && item.onAction ? `<button class="notification-toast-action" type="button" data-toast-action>${html(item.actionLabel)}</button>` : "";
    toast.className = `notification-toast ${type}`;
    toast.innerHTML = `<span class="notification-toast-icon" aria-hidden="true">${glyph}</span><div class="notification-toast-copy">${item.title ? `<b>${html(item.title)}</b>` : ""}<span>${html(item.message || item.body || "")}</span></div>${action}<button class="notification-toast-close" type="button" data-toast-close aria-label="Dismiss notification">&times;</button><span class="notification-toast-countdown" aria-hidden="true"></span>`;
    toast.querySelector("[data-toast-close]").addEventListener("click",dismissToast);
    toast.querySelector("[data-toast-action]")?.addEventListener("click",()=>{item.onAction();dismissToast()});
    toastRemaining = Math.max(1,Number(item.duration || TOAST_DURATION));
    toastStartedAt = Date.now();
    toastHovered = false;
    toastFocused = false;
    toast.style.setProperty("--lavida-toast-duration",`${toastRemaining}ms`);
    updateToastOffset();
    requestAnimationFrame(()=>toast.classList.add("visible"));
    toastTimer = setTimeout(dismissToast,toastRemaining);
  }
  function notify(input,type){
    const item = typeof input === "string" ? {message:input,type:type || "info"} : {...(input || {})};
    item.type = item.type || type || "info";
    const key = toastKey(item);
    if(queuedToastKeys.has(key))return false;
    queuedToastKeys.add(key);
    toastQueue.push(item);
    showNextToast();
    return true;
  }
  function showToast(row){
    notify({
      key:`realtime:${row.id || `${row.title}:${row.body}`}`,
      type:"info",
      title:row.title || "LAVIDA Update",
      message:row.body || "",
      duration:6500,
      actionLabel:row.id ? "View" : "",
      onAction:row.id ? ()=>openNotification(row.id) : null
    });
  }
  function setupRealtime(user){
    const database = client();
    if(!database?.channel || !user?.id || realtimeChannel)return;
    try{
      realtimeChannel = database.channel(`lavida-notifications-${user.id}`)
        .on("postgres_changes",{event:"INSERT",schema:"public",table:"notifications",filter:`user_id=eq.${user.id}`},(payload)=>{
          refreshBadge();
          if(location.hash === "#notifications")loadNotifications();
          showToast(payload.new || {});
        })
        .on("postgres_changes",{event:"UPDATE",schema:"public",table:"notifications",filter:`user_id=eq.${user.id}`},()=>{
          refreshBadge();
          if(location.hash === "#notifications")loadNotifications();
        })
        .subscribe();
    }catch(error){}
  }
  async function createNotification(payload){
    const database = client();
    if(!database)return null;
    const mapped = {
      p_user_id:payload.userId || payload.user_id || null,
      p_email:payload.email || null,
      p_notification_type:payload.type || payload.notification_type || "lavida_update",
      p_category:payload.category || "service",
      p_title:payload.title || "LAVIDA Update",
      p_body:payload.body || "",
      p_action_label:payload.actionLabel || payload.action_label || null,
      p_action_url:payload.actionUrl || payload.action_url || payload.destination || null,
      p_entity_type:payload.entityType || payload.entity_type || null,
      p_entity_id:payload.entityId || payload.entity_id || null,
      p_priority:payload.priority || "transactional",
      p_service_label:payload.serviceLabel || payload.service_label || null,
      p_idempotency_key:payload.idempotencyKey || payload.idempotency_key || null,
      p_metadata:payload.metadata || {},
      p_send_push:payload.sendPush !== false
    };
    const {data,error} = await database.rpc("create_lavida_notification", mapped);
    if(error)throw error;
    await refreshBadge();
    return data;
  }
  async function init(){
    renderShell();
    if(window.LavidaNativePushToken)registerAndroidPushToken(window.LavidaNativePushToken).catch(()=>{});
    await renderSettings();
    await refreshBadge();
    if(location.hash === "#notifications")await loadNotifications();
  }

  document.addEventListener("click",(event)=>{
    if(event.target.closest("#marketplaceNotificationsButton")){
      setTimeout(()=>loadNotifications(), 0);
      return;
    }
    const filter = event.target.closest("[data-notification-filter]");
    if(filter){
      activeFilter = filter.dataset.notificationFilter || "all";
      document.querySelectorAll("[data-notification-filter]").forEach((button)=>button.classList.toggle("active",button === filter));
      loadNotifications();
      return;
    }
    const read = event.target.closest("[data-read-notification]");
    if(read){markRead([read.dataset.readNotification]);return;}
    const open = event.target.closest("[data-open-notification]");
    if(open){openNotification(open.dataset.openNotification);return;}
    if(event.target.closest("#notificationMarkAllButton")){markRead(null);return;}
    if(event.target.closest("[data-enable-phone-notifications]")){enablePhoneNotifications();return;}
    if(event.target.closest("[data-dismiss-phone-notifications]")){
      byId("notificationPermissionCard")?.classList.add("hidden");
      return;
    }
  });
  document.addEventListener("change",(event)=>{
    const pref = event.target.closest("[data-notification-pref]");
    if(pref)updatePreference(pref);
  });
  window.addEventListener("hashchange",()=>{if(location.hash === "#notifications")loadNotifications(); if(location.hash === "#account")renderSettings();});
  window.addEventListener("focus",()=>{refreshBadge(); if(location.hash === "#notifications")loadNotifications();});
  window.addEventListener("lavida-native-push-token",(event)=>{registerAndroidPushToken(event.detail || {}).catch(()=>{});});
  window.addEventListener("lavida-native-push-disabled",(event)=>{deactivateAndroidPushToken(event.detail || {}).catch(()=>{});});

  window.LavidaNotifications = {
    init,
    load:loadNotifications,
    refreshBadge,
    create:createNotification,
    enablePhoneNotifications,
    registerAndroidPushToken,
    deactivateAndroidPushToken,
    prepareLogout,
    show:notify,
    success:(message,options={})=>notify({...options,message,type:"success"}),
    error:(message,options={})=>notify({...options,message,type:"error"}),
    warning:(message,options={})=>notify({...options,message,type:"warning"}),
    info:(message,options={})=>notify({...options,message,type:"info"}),
    dismiss:dismissToast
  };

  window.addEventListener("resize",updateToastOffset,{passive:true});
  window.addEventListener("orientationchange",updateToastOffset,{passive:true});

  init();
})();
