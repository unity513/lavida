(function(root){
  "use strict";

  const APP_NAME = "LAVIDA Connect";
  const SUPABASE_URL = "https://cgvpoddtqswmtzvyrmwj.supabase.co";
  const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNndnBvZGR0cXN3bXR6dnlybXdqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYzNDE0OTMsImV4cCI6MjA5MTkxNzQ5M30.Ut_5jGo8L66zi8zxqR25nV_gkDBYLrT7p3Fx-4G5wGQ";
  const DEFAULT_DESTINATION = "./marketplace.html#home";
  const ROLE_DESTINATIONS = Object.freeze({
    owner: "./marketplace-admin.html",
    admin: "./marketplace-admin.html",
    executive: "./marketplace-admin.html",
    manager: "./marketplace-admin.html",
    printing_admin: "./printing-admin.html",
    cashier: "./marketplace.html#home",
    customer: "./marketplace.html#home",
    player: "./chess365.html#chess-home"
  });
  const SAFE_PAGES = new Set([
    "index.html",
    "marketplace.html",
    "marketplace-admin.html",
    "marketplace-orders-admin.html",
    "user-management.html",
    "printing-admin.html",
    "payments-pricing-admin.html",
    "signin.html",
    "register.html",
    "forgot-password.html",
    "reset-password.html",
    "community.html",
    "chess365.html",
    "games365.html",
    "bawo365.html",
    "hrm365.html",
    "product-details.html"
  ]);

  let client = null;
  let listener = null;

  function createClient(url, anonKey){
    if(client) return client;
    client = root.supabase.createClient(url, anonKey, {
      auth: {
        detectSessionInUrl: true,
        persistSession: true,
        autoRefreshToken: true,
        flowType: "implicit"
      }
    });
    return client;
  }

  function getClient(){
    return createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  }

  function debug(label, error, extra){
    console.error(`LAVIDA auth ${label}:`, {
      code: error?.code || null,
      status: error?.status || error?.statusCode || null,
      message: error?.message || String(error || ""),
      details: error?.details || null,
      hint: error?.hint || null,
      extra: extra || null
    });
  }

  function friendlyError(error, fallback){
    const text = `${error?.message || ""} ${error?.code || ""}`.toLowerCase();
    if(/invalid login credentials|invalid credentials|email not confirmed|email_not_confirmed|user not found|not found/.test(text)){
      if(/email not confirmed|email_not_confirmed/.test(text)) return "Please verify your email address before signing in.";
      if(/user not found|not found/.test(text)) return "No LAVIDA account was found for this email address.";
      return "The email address or password is incorrect.";
    }
    if(/already registered|user already registered|already exists/.test(text)) return "This email address is already registered with LAVIDA.";
    if(/rate limit|too many|over_email_send_rate_limit/.test(text)) return "Please wait a moment before trying again.";
    if(/expired|session.*missing|auth session missing|jwt expired|refresh_token_not_found|invalid refresh token|invalid.*token|otp_expired/.test(text)) return "This link or session has expired. Please request a new one.";
    if(/password|weak/.test(text)) return "Please choose a stronger password with at least eight characters.";
    if(/network|fetch|failed to fetch|timeout/.test(text)) return "LAVIDA could not connect right now. Please check your connection and try again.";
    if(/permission|row level|unauthorized|forbidden|42501/.test(text)) return "Your LAVIDA account does not have access to this page.";
    return fallback || "We could not complete your request. Please try again.";
  }

  function destinationForRole(role){
    return ROLE_DESTINATIONS[String(role || "").toLowerCase()] || DEFAULT_DESTINATION;
  }

  function pageNameFromPath(pathname){
    const raw = String(pathname || "").split("/").pop() || "index.html";
    return /\.[a-z0-9]+$/i.test(raw) ? raw : `${raw}.html`;
  }

  function safeDestination(value, fallback){
    const base = new URL(root.location.href);
    if(!value) return fallback || DEFAULT_DESTINATION;
    try{
      const next = new URL(value, base);
      if(next.origin !== base.origin) return fallback || DEFAULT_DESTINATION;
      const currentFile = pageNameFromPath(base.pathname);
      const file = pageNameFromPath(next.pathname);
      if(!SAFE_PAGES.has(file) || /supabase|grandmaster365:|grandmaster\//i.test(next.href)) return fallback || DEFAULT_DESTINATION;
      if(file === currentFile && next.hash === base.hash) return fallback || DEFAULT_DESTINATION;
      return `${file}${next.search}${next.hash}`;
    }catch(error){
      return fallback || DEFAULT_DESTINATION;
    }
  }

  function rememberReturnTo(){
    const value = `${pageNameFromPath(root.location.pathname)}${root.location.search}${root.location.hash}`;
    if(!/signin|register|forgot-password|reset-password|index\.html/i.test(value)) sessionStorage.setItem("lavida_auth_return_to", value);
  }

  function consumeReturnTo(fallback){
    const params = new URLSearchParams(root.location.search);
    const fromUrl = params.get("returnTo");
    const stored = sessionStorage.getItem("lavida_auth_return_to");
    sessionStorage.removeItem("lavida_auth_return_to");
    return safeDestination(fromUrl || stored, fallback);
  }

  async function getSession(db){
    const {data, error} = await db.auth.getSession();
    if(error) throw error;
    return data?.session || null;
  }

  async function loadRole(db, session){
    const email = session?.user?.email || "";
    if(!email) return null;
    const {data, error} = await db
      .from("user_roles")
      .select("role,active")
      .eq("email", email)
      .eq("active", true)
      .maybeSingle();
    if(error) throw error;
    return data?.role || null;
  }

  async function signIn(db, email, password){
    const {data, error} = await db.auth.signInWithPassword({email, password});
    if(error) {
      debug("sign in failed", error, {email});
      throw error;
    }
    return data?.session || null;
  }

  async function signUp(db, email, password, options){
    const {data, error} = await db.auth.signUp({
      email,
      password,
      options: Object.assign({emailRedirectTo: new URL("./marketplace.html#home", root.location.href).href}, options || {})
    });
    if(error) {
      debug("sign up failed", error, {email});
      throw error;
    }
    return data?.session || null;
  }

  async function signOut(db){
    try{ await db.auth.signOut({scope:"global"}); }
    catch(error){ debug("sign out failed", error); }
    try{
      for(let index = localStorage.length - 1; index >= 0; index -= 1){
        const key = localStorage.key(index) || "";
        if(/^sb-[^-]+-auth-token$/.test(key) || /supabase\.auth\.token/i.test(key)) localStorage.removeItem(key);
      }
    }catch(error){ debug("auth storage cleanup failed", error); }
    sessionStorage.removeItem("lavida_auth_return_to");
  }

  function listen(db, callback){
    if(listener?.unsubscribe) listener.unsubscribe();
    const result = db.auth.onAuthStateChange((event, session) => callback(event, session));
    listener = result?.data?.subscription || result?.subscription || null;
    return listener;
  }

  root.LavidaAuth = {
    APP_NAME,
    SUPABASE_URL,
    ROLE_DESTINATIONS,
    createClient,
    getClient,
    debug,
    friendlyError,
    destinationForRole,
    safeDestination,
    rememberReturnTo,
    consumeReturnTo,
    getSession,
    loadRole,
    signIn,
    signUp,
    signOut,
    listen
  };
})(window);
