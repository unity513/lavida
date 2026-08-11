(function(){
  const VIDEO_BUCKET = "community-videos";
  const COMMUNITY_TABLE = "community_updates";
  const MAX_VIDEO_BYTES = 100 * 1024 * 1024;
  const ALLOWED_TYPES = ["video/mp4", "video/quicktime", "video/webm"];
  const ALLOWED_EXTS = ["mp4", "mov", "webm"];
  const LOCAL_VIDEO_DB = "lavida_community_video_blobs_v1";
  const LOCAL_VIDEO_STORE = "videos";
  const localVideoUrls = new Map();
  let selectedFile = null;
  let selectedPreviewUrl = "";
  let selectedDuration = 0;
  let uploadedPath = "";
  let uploadedUrl = "";
  let loadingRemoteVideos = false;

  const $ = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? "").replace(/[&<>"']/g,(c)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));

  function setComposerNotice(text, type){
    if(typeof notice === "function") notice("composerNotice", text, type);
  }

  function setProgress(value, text){
    const bar = $("communityVideoProgressBar");
    const label = $("communityVideoProgressText");
    if(bar) bar.style.width = `${Math.max(0, Math.min(100, value))}%`;
    if(label) label.textContent = text;
  }

  function safeFileName(name){
    return String(name || "video").replace(/[^\w.-]+/g, "_").replace(/^_+|_+$/g, "");
  }

  function withTimeout(promise, ms, message){
    let timer;
    const timeout = new Promise((_, reject)=>{
      timer = setTimeout(()=>reject(new Error(message)), ms);
    });
    return Promise.race([promise, timeout]).finally(()=>clearTimeout(timer));
  }

  function currentUserFallback(){
    if(typeof currentAuthor === "function") return currentAuthor();
    const email = localStorage.getItem("lavida_connect_customer_email") || "";
    return {
      name: email ? email.split("@")[0].replace(/[._-]+/g," ").replace(/\b\w/g,c=>c.toUpperCase()) : "Community Member",
      email
    };
  }

  function openLocalVideoDb(){
    return new Promise((resolve, reject)=>{
      if(!("indexedDB" in window)) return reject(new Error("This device cannot store local video previews."));
      const request = indexedDB.open(LOCAL_VIDEO_DB, 1);
      request.onupgradeneeded = () => {
        const db = request.result;
        if(!db.objectStoreNames.contains(LOCAL_VIDEO_STORE)) db.createObjectStore(LOCAL_VIDEO_STORE, {keyPath:"key"});
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error("Local video storage failed."));
    });
  }

  async function localVideoStore(mode, callback){
    const database = await openLocalVideoDb();
    return new Promise((resolve, reject)=>{
      const transaction = database.transaction(LOCAL_VIDEO_STORE, mode);
      const store = transaction.objectStore(LOCAL_VIDEO_STORE);
      const request = callback(store);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error("Local video storage failed."));
      transaction.oncomplete = () => database.close();
      transaction.onerror = () => {
        database.close();
        reject(transaction.error || new Error("Local video storage failed."));
      };
    });
  }

  async function saveLocalVideoBlob(key, file){
    await localVideoStore("readwrite", (store)=>store.put({
      key,
      blob: file,
      name: file.name || "community-video.mp4",
      type: file.type || "video/mp4",
      saved_at: new Date().toISOString()
    }));
  }

  async function removeLocalVideoBlob(key){
    if(!key) return;
    await localVideoStore("readwrite", (store)=>store.delete(key)).catch(()=>{});
    const url = localVideoUrls.get(key);
    if(url) URL.revokeObjectURL(url);
    localVideoUrls.delete(key);
  }

  async function loadLocalVideoUrl(key){
    if(!key) return "";
    if(localVideoUrls.has(key)) return localVideoUrls.get(key);
    const row = await localVideoStore("readonly", (store)=>store.get(key)).catch(()=>null);
    if(!row?.blob) return "";
    const url = URL.createObjectURL(row.blob);
    localVideoUrls.set(key, url);
    return url;
  }

  function ensureComposerUi(){
    const select = $("postMediaType");
    if(select && !select.querySelector('option[value="video"]')){
      select.insertAdjacentHTML("beforeend", '<option value="video">Video</option>');
    }

    const fields = document.querySelector(".composer-fields");
    if(fields && !$("communityVideoPanel")){
      fields.insertAdjacentHTML("afterend", `
        <div id="communityVideoPanel" class="community-video-panel hidden">
          <div class="video-pick-grid">
            <label class="video-pick">Record video<input id="communityVideoRecordInput" type="file" accept="video/mp4,video/quicktime,video/webm" capture="environment"></label>
            <label class="video-pick">Upload video<input id="communityVideoUploadInput" type="file" accept="video/mp4,video/quicktime,video/webm"></label>
          </div>
          <div id="communityVideoPreview" class="video-preview-box"><div class="video-empty"><b>No video selected</b><span>Choose MP4, MOV, or WebM up to 100 MB.</span></div></div>
          <div class="video-tools">
            <button type="button" data-community-video-replace>Replace</button>
            <button type="button" data-community-video-remove>Remove</button>
          </div>
          <div class="video-field">
            <label>Upload progress</label>
            <div class="video-progress"><span id="communityVideoProgressBar"></span></div>
            <div id="communityVideoProgressText" class="video-help">Waiting for video.</div>
          </div>
        </div>
      `);
    }

    document.querySelectorAll(".composer-actions .video").forEach((button)=>{
      button.dataset.openVideoComposer = "";
      delete button.dataset.media;
      button.textContent = "Video";
    });

    $("communityVideoRecordInput")?.addEventListener("change", (event)=>selectVideo(event.target.files?.[0]));
    $("communityVideoUploadInput")?.addEventListener("change", (event)=>selectVideo(event.target.files?.[0]));
    select?.addEventListener("change", syncVideoPanel);
    syncVideoPanel();
  }

  function syncVideoPanel(){
    $("communityVideoPanel")?.classList.toggle("hidden", $("postMediaType")?.value !== "video");
  }

  function openVideoComposer(){
    if(typeof openComposer === "function") openComposer("video");
    const select = $("postMediaType");
    if(select) select.value = "video";
    syncVideoPanel();
    $("postText")?.focus({preventScroll:true});
  }

  function validateFile(file){
    if(!file) return "Choose a video first.";
    const ext = String(file.name || "").split(".").pop().toLowerCase();
    if(!ALLOWED_TYPES.includes(file.type) && !ALLOWED_EXTS.includes(ext)) return "Unsupported video format. Please use MP4, MOV, or WebM.";
    if(file.size > MAX_VIDEO_BYTES) return "Video exceeds the maximum file size of 100 MB.";
    return "";
  }

  async function selectVideo(file){
    const error = validateFile(file);
    if(error){
      setComposerNotice(error, "bad");
      return;
    }
    selectedFile = file;
    uploadedPath = "";
    uploadedUrl = "";
    selectedDuration = 0;
    if(selectedPreviewUrl) URL.revokeObjectURL(selectedPreviewUrl);
    selectedPreviewUrl = URL.createObjectURL(file);
    $("communityVideoPreview").innerHTML = `<video src="${selectedPreviewUrl}" controls muted playsinline preload="metadata"></video>`;
    setProgress(10, "Reading video...");
    try{
      selectedDuration = await readDuration(selectedPreviewUrl);
      setProgress(20, "Video ready for preview.");
      setComposerNotice("Video selected. Add your caption, then publish.", "ok");
    }catch(error){
      setComposerNotice("File could not be read. Try another video.", "bad");
    }
  }

  function readDuration(url){
    return new Promise((resolve, reject)=>{
      const video = document.createElement("video");
      video.preload = "metadata";
      video.src = url;
      video.onloadedmetadata = () => resolve(Number(video.duration || 0));
      video.onerror = reject;
    });
  }

  function removeSelectedVideo(){
    selectedFile = null;
    selectedDuration = 0;
    uploadedPath = "";
    uploadedUrl = "";
    if(selectedPreviewUrl) URL.revokeObjectURL(selectedPreviewUrl);
    selectedPreviewUrl = "";
    $("communityVideoPreview").innerHTML = `<div class="video-empty"><b>No video selected</b><span>Choose MP4, MOV, or WebM up to 100 MB.</span></div>`;
    setProgress(0, "Video removed.");
  }

  async function uploadSelectedVideo(){
    const {data:{session}} = await db.auth.getSession();
    if(!session?.user?.id) throw new Error("Please sign in before posting a video.");
    const error = validateFile(selectedFile);
    if(error) throw new Error(error);
    setProgress(35, "Uploading video...");
    const path = `${session.user.id}/${Date.now()}-${safeFileName(selectedFile.name)}`;
    const {error: uploadError} = await withTimeout(
      db.storage.from(VIDEO_BUCKET).upload(path, selectedFile, {
        cacheControl: "3600",
        contentType: selectedFile.type || "video/mp4",
        upsert: false
      }),
      45000,
      "Upload is taking too long. Check your connection and retry."
    );
    if(uploadError) throw uploadError;
    setProgress(80, "Saving community post...");
    uploadedPath = path;
    uploadedUrl = db.storage.from(VIDEO_BUCKET).getPublicUrl(path).data.publicUrl;
    return {path, url: uploadedUrl};
  }

  async function publishVideoPost(){
    const caption = $("postText")?.value.trim() || "";
    const category = $("postCategory")?.value || "Business";
    if(!caption){
      setComposerNotice("Write a caption before publishing your video.", "bad");
      return;
    }
    if(!selectedFile && !uploadedUrl){
      setComposerNotice("Choose or record a video before publishing.", "bad");
      return;
    }

    $("publishPostButton").disabled = true;
    try{
      const {data:{session}} = await db.auth.getSession();
      if(!session?.user?.id) throw new Error("Please sign in before posting a video.");
      const author = currentUserFallback();
      const upload = uploadedUrl ? {path: uploadedPath, url: uploadedUrl} : await uploadSelectedVideo();
      const payload = {
        title: caption.slice(0, 90) || "Community video",
        body: caption,
        user_id: session.user.id,
        author_name: author.name,
        author_handle: author.email ? `@${author.email.split("@")[0]}` : "@lavida",
        category,
        post_type: "video",
        media_type: "video",
        video_url: upload.url,
        video_path: upload.path,
        video_duration: Math.round(selectedDuration || 0),
        video_size: selectedFile?.size || null,
        updated_at: new Date().toISOString()
      };
      const {data, error} = await withTimeout(
        db.from(COMMUNITY_TABLE).insert(payload).select("*").single(),
        20000,
        "The video uploaded, but saving the post timed out. Please retry on a stronger connection."
      );
      if(error) throw error;
      addVideoToFeed(data || payload);
      $("postText").value = "";
      $("composer")?.classList.remove("open");
      removeSelectedVideo();
      setProgress(100, "Published.");
      setComposerNotice("Your video has been shared with the community.", "ok");
    }catch(error){
      console.error("LAVIDA video post failed", error);
      const canKeepLocal = selectedFile && selectedPreviewUrl && /bucket not found|not found|schema cache|column|community_updates|Upload is taking too long|Failed to fetch/i.test(error?.message || "");
      if(canKeepLocal){
        await publishLocalVideoPost(caption, category);
        return;
      }
      const message = /bucket not found|not found/i.test(error?.message || "")
        ? "Video storage is not ready. Run the community video migration, then retry."
        : /schema cache|column|community_updates/i.test(error?.message || "")
          ? "Community video database fields are missing. Run the community video migration, then retry."
          : error?.message || "Video upload failed. Please check your connection and retry.";
      setComposerNotice(message, "bad");
      setProgress(20, "Upload failed. Retry when ready.");
      if(uploadedPath){
        await db.storage.from(VIDEO_BUCKET).remove([uploadedPath]).catch(()=>{});
        uploadedPath = "";
        uploadedUrl = "";
      }
    }finally{
      $("publishPostButton").disabled = false;
    }
  }

  async function publishLocalVideoPost(caption, category){
    const author = currentUserFallback();
    const key = `local-video-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    await saveLocalVideoBlob(key, selectedFile);
    const localUrl = selectedPreviewUrl;
    localVideoUrls.set(key, localUrl);
    state.posts.unshift({
      id: key,
      author: author.name,
      handle: author.email ? `@${author.email.split("@")[0]}` : "@lavida",
      role: "Community member",
      verified: false,
      category,
      text: caption,
      media: "video",
      post_type: "video",
      local_only: true,
      local_video_key: key,
      video_url: localUrl,
      video_duration: Math.round(selectedDuration || 0),
      likes: 0,
      comments: [],
      createdAt: "now",
      liked: false
    });
    $("postText").value = "";
    $("composer")?.classList.remove("open");
    selectedFile = null;
    selectedDuration = 0;
    selectedPreviewUrl = "";
    uploadedPath = "";
    uploadedUrl = "";
    if(typeof saveState === "function") saveState();
    if(typeof renderFeed === "function") renderFeed();
    setProgress(100, "Saved on this phone.");
    setComposerNotice("Your video is showing on this phone. Run the community video migration to share it across devices.", "ok");
  }

  function addVideoToFeed(row){
    const id = `community-video-${row.id || Date.now()}`;
    if(state.posts.some((post)=>post.id === id)) return;
    state.posts.unshift({
      id,
      remoteId: row.id,
      author: row.author_name || currentUserFallback().name,
      handle: row.author_handle || "@lavida",
      role: "Community member",
      verified: false,
      category: row.category || "Business",
      text: row.body || row.title || "",
      media: "video",
      video_url: row.video_url,
      video_path: row.video_path,
      video_duration: row.video_duration,
      likes: Number(row.likes_count || 0),
      comments: [],
      createdAt: row.created_at ? new Date(row.created_at).toLocaleString() : "now",
      liked: false
    });
    if(typeof saveState === "function") saveState();
    if(typeof renderFeed === "function") renderFeed();
  }

  function installVideoRenderer(){
    const originalMediaHtml = mediaHtml;
    mediaHtml = function(post){
      if(post.media === "video"){
        if(!post.video_url) return `<div class="video-unavailable">Video is loading on this device.</div>`;
        const localBadge = post.local_only ? "<span>Saved on this phone</span>" : "";
        return `<div class="video-frame"><video src="${esc(post.video_url)}" controls muted playsinline preload="metadata"></video></div><div class="video-stats"><span>${esc(post.video_duration || 0)} sec</span>${localBadge}<button type="button" data-delete-video-post="${esc(post.id)}">Delete video</button></div>`;
      }
      return originalMediaHtml(post);
    };
  }

  async function loadRemoteVideos(){
    if(loadingRemoteVideos) return;
    loadingRemoteVideos = true;
    try{
      const {data, error} = await db.from(COMMUNITY_TABLE).select("*").eq("post_type", "video").order("created_at", {ascending:false}).limit(50);
      if(error) throw error;
      (data || []).reverse().forEach(addVideoToFeed);
    }catch(error){
      if(/schema cache|column|post_type/i.test(error?.message || "")){
        setComposerNotice("Community video database fields are not installed yet. Run the migration before publishing videos.", "bad");
      }else{
        console.warn("LAVIDA video feed load failed", error);
      }
    }finally{
      loadingRemoteVideos = false;
    }
  }

  async function deleteVideoPost(postId){
    const post = state.posts.find((item)=>item.id === postId);
    if(!post) return;
    if(!confirm("Delete this video post?")) return;
    try{
      if(post.remoteId){
        const {error} = await db.from(COMMUNITY_TABLE).delete().eq("id", post.remoteId);
        if(error) throw error;
      }
      if(post.video_path) await db.storage.from(VIDEO_BUCKET).remove([post.video_path]);
      if(post.local_video_key) await removeLocalVideoBlob(post.local_video_key);
      state.posts = state.posts.filter((item)=>item.id !== postId);
      if(typeof saveState === "function") saveState();
      if(typeof renderFeed === "function") renderFeed();
      setComposerNotice("Video post deleted.", "ok");
    }catch(error){
      console.error("LAVIDA video delete failed", error);
      setComposerNotice(error?.message || "Video post could not be deleted.", "bad");
    }
  }

  document.addEventListener("click", (event)=>{
    if(event.target.closest("[data-open-video-composer]")){
      event.preventDefault();
      openVideoComposer();
      return;
    }
    if(event.target.closest("[data-community-video-replace]")){
      $("communityVideoUploadInput")?.click();
      return;
    }
    if(event.target.closest("[data-community-video-remove]")){
      removeSelectedVideo();
      return;
    }
    const deleteButton = event.target.closest("[data-delete-video-post]");
    if(deleteButton){
      deleteVideoPost(deleteButton.dataset.deleteVideoPost);
    }
  });

  $("publishPostButton")?.addEventListener("click", (event)=>{
    if($("postMediaType")?.value !== "video") return;
    event.preventDefault();
    event.stopImmediatePropagation();
    publishVideoPost();
  }, true);

  function start(){
    ensureComposerUi();
    installVideoRenderer();
    if(typeof renderFeed === "function") renderFeed();
    hydrateLocalVideoPosts();
    loadRemoteVideos();
  }

  async function hydrateLocalVideoPosts(){
    const localPosts = (state.posts || []).filter((post)=>post.media === "video" && post.local_video_key);
    if(!localPosts.length) return;
    let changed = false;
    for(const post of localPosts){
      const url = await loadLocalVideoUrl(post.local_video_key);
      if(url && post.video_url !== url){
        post.video_url = url;
        changed = true;
      }
    }
    if(changed && typeof renderFeed === "function") renderFeed();
  }

  if(document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
