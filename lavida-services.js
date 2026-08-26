(function(){
  "use strict";

  const DRAFT_KEY = "lavida_service_request_draft_v1";
  const LOCAL_REQUESTS_KEY = "lavida_service_requests_local_v1";
  const MAX_FILES = 10;
  const MAX_FILE_SIZE = 20 * 1024 * 1024;
  const SERVICE_TABS = [
    ["all","All"],
    ["requests","Requests"],
    ["quotes","Quotes"],
    ["invoices","Invoices"],
    ["active","Active Services"],
    ["completed","Completed"]
  ];
  const ALLOWED_EXTENSIONS = [".pdf",".doc",".docx",".xls",".xlsx",".ppt",".pptx",".jpg",".jpeg",".png",".zip"];
  const ALLOWED_MIME = /^(application\/pdf|application\/msword|application\/vnd\.openxmlformats-officedocument|application\/vnd\.ms-|image\/jpeg|image\/png|application\/zip|application\/x-zip-compressed)$/i;
  const SERVICE_AREAS = {
    digital:{
      area:"digital",
      code:"DS",
      title:"Digital & Systems Support",
      shortTitle:"Digital Support",
      description:"Technology, websites, hosting, software and technical assistance.",
      longDescription:"Technology, systems, websites, hosting, business software and professional technical support.",
      cta:"Request Support",
      services:[
        ["systems_it","Systems & IT Support","Technical troubleshooting, setup and support."],
        ["website_development","Website Development","New professional websites and business sites."],
        ["website_redesign","Website Redesign","Refresh an existing website."],
        ["website_maintenance","Website Maintenance","Fixes, updates and improvements."],
        ["web_application","Web Application","Custom online tools, dashboards and portals."],
        ["web_hosting","Web Hosting","Hosting setup, migration and configuration."],
        ["domain_support","Domain Support","Domain setup, DNS and connection help."],
        ["business_email","Business Email","Email setup for your domain or team."],
        ["hosting_migration","Hosting Migration","Move a website, email or domain safely."],
        ["business_software","Business Software","QuickBooks, Sage, Microsoft 365, Canva and office tools."],
        ["installation_setup","Installation & Setup","Software installation and configuration."],
        ["data_migration","Data Migration","Move data between systems carefully."],
        ["training","Training","Staff or user training for digital tools."],
        ["ongoing_support","Ongoing Technical Support","Recurring support for systems and operations."],
        ["other_digital","Other","Tell us what you need help with."]
      ]
    },
    documents:{
      area:"documents",
      code:"DP",
      title:"Documents & Professional Profiles",
      shortTitle:"Documents",
      description:"CVs, reports, proposals, portfolios and professional documents.",
      longDescription:"Turn your experience, information and ideas into professionally structured digital documents.",
      cta:"Start a Document Request",
      services:[
        ["cv_design","CV Design & Development","Create a modern CV from your real experience."],
        ["cv_update","Update Existing CV","Improve, update or modernise an existing CV."],
        ["internship_report","Internship Report","Structure evidence from work you actually performed."],
        ["project_report","Project Report","Organise project work into a professional report."],
        ["business_report","Business Report","Develop a structured business document."],
        ["company_profile","Company Profile","Present a company professionally."],
        ["proposal","Proposal","Prepare a clean business or project proposal."],
        ["presentation","Presentation","Professional slides and pitch materials."],
        ["portfolio","Portfolio Document","Showcase work, skills and projects."],
        ["cover_letter","Cover Letter","Targeted professional cover letters."],
        ["document_formatting","Document Formatting","Format, polish and restructure documents."],
        ["other_document","Other Professional Document","Tell us what document you need."]
      ]
    }
  };

  let serviceState = freshState();
  let myServices = [];
  let activeServiceTab = "all";

  function byId(id){return document.getElementById(id)}
  function escapeHtml(value){return typeof esc === "function" ? esc(value) : String(value ?? "").replace(/[&<>"']/g,(c)=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));}
  function icon(name){
    const icons = {
      digital:'<path d="M4 5h16v11H4z"></path><path d="M8 21h8"></path><path d="M12 16v5"></path>',
      documents:'<path d="M6 3h8l4 4v14H6z"></path><path d="M14 3v5h5"></path><path d="M9 13h6M9 17h5"></path>',
      printing:'<path d="M6 9V3h12v6"></path><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"></path><path d="M6 14h12v7H6z"></path>',
      check:'<path d="m5 12 4 4L19 6"></path>',
      upload:'<path d="M12 3v12"></path><path d="m7 8 5-5 5 5"></path><path d="M5 19h14"></path>'
    };
    return `<svg viewBox="0 0 24 24" fill="none" stroke-width="2">${icons[name] || icons.digital}</svg>`;
  }
  function freshState(){
    return {area:"digital",serviceCode:"",step:0,answers:{},files:[],notice:"",noticeType:"",submitting:false,submitted:null};
  }
  function currentArea(){return SERVICE_AREAS[serviceState.area] || SERVICE_AREAS.digital}
  function currentService(){return currentArea().services.find(([code])=>code===serviceState.serviceCode) || null}
  function currentServiceName(){const found=currentService(); return found ? found[1] : currentArea().title}
  function serviceKind(code){
    if(/website|web_application/.test(code))return"website";
    if(/hosting|domain|email|migration/.test(code))return"hosting";
    if(/software|installation|data_migration|training/.test(code))return"software";
    if(/cv/.test(code))return"cv";
    if(/internship_report|project_report/.test(code))return"report";
    if(serviceState.area==="documents")return"document";
    return"digital";
  }
  function getValue(name){return serviceState.answers[name] || ""}
  function setNotice(text,type){serviceState.notice=text||"";serviceState.noticeType=type||""}
  function fileSize(size){
    const n=Number(size||0);
    if(n>1024*1024)return `${(n/1024/1024).toFixed(1)} MB`;
    if(n>1024)return `${(n/1024).toFixed(1)} KB`;
    return `${n} B`;
  }
  function fileAllowed(file){
    const lower = String(file.name || "").toLowerCase();
    const extOk = ALLOWED_EXTENSIONS.some((ext)=>lower.endsWith(ext));
    const mimeOk = !file.type || ALLOWED_MIME.test(file.type);
    if(!extOk)return"This file type is not supported.";
    if(!mimeOk)return"This file type is not supported.";
    if(file.size > MAX_FILE_SIZE)return"This file is larger than the allowed size.";
    return "";
  }
  function requestNumber(areaCode){
    const date = new Date();
    const y = String(date.getFullYear()).slice(-2);
    const m = String(date.getMonth()+1).padStart(2,"0");
    const d = String(date.getDate()).padStart(2,"0");
    const rand = Math.floor(1000 + Math.random()*9000);
    return `LVD-${areaCode}-${y}${m}${d}-${rand}`;
  }
  function statusLabel(value){
    return ({
      submitted:"Submitted",
      under_review:"Under Review",
      more_information_required:"More Information Required",
      scope_confirmed:"Scope Confirmed",
      quotation_ready:"Quotation Ready",
      quote_accepted:"Quote Accepted",
      invoice_issued:"Invoice Issued",
      awaiting_payment:"Awaiting Payment",
      payment_confirmed:"Payment Confirmed",
      in_progress:"In Progress",
      client_review:"Client Review",
      completed:"Completed",
      cancelled:"Cancelled",
      active_subscription:"Active Subscription",
      payment_due:"Payment Due",
      suspended:"Suspended"
    }[value] || String(value || "Submitted").replaceAll("_"," ").replace(/\b\w/g,(c)=>c.toUpperCase()));
  }
  function requestBucket(row){
    if(["completed","cancelled"].includes(row.status))return row.status;
    if(row.invoice_status && row.invoice_status !== "none")return"invoices";
    if(row.quote_status && row.quote_status !== "none")return"quotes";
    if(["in_progress","client_review","active_subscription","payment_due","suspended"].includes(row.status))return"active";
    return"requests";
  }
  function saveDraft(){
    const safeFiles = serviceState.files.map((row)=>({id:row.id,name:row.file.name,size:row.file.size,type:row.file.type,description:row.description||""}));
    sessionStorage.setItem(DRAFT_KEY,JSON.stringify({...serviceState,files:safeFiles}));
  }
  function restoreDraft(){
    try{
      const draft = JSON.parse(sessionStorage.getItem(DRAFT_KEY) || "null");
      if(draft && draft.area){
        serviceState = {...freshState(),...draft,files:[]};
      }
    }catch(error){}
  }
  function clearDraft(){sessionStorage.removeItem(DRAFT_KEY)}
  function localRequests(){
    try{return JSON.parse(localStorage.getItem(LOCAL_REQUESTS_KEY) || "[]")}catch(error){return[]}
  }
  function saveLocalRequest(row){
    const rows = [row,...localRequests()].slice(0,30);
    localStorage.setItem(LOCAL_REQUESTS_KEY,JSON.stringify(rows));
  }
  function preloadContact(){
    const user = authSession?.user;
    const meta = user?.user_metadata || {};
    if(!getValue("contact_name"))serviceState.answers.contact_name = meta.full_name || meta.name || userDisplayName?.(user) || "";
    if(!getValue("contact_email"))serviceState.answers.contact_email = user?.email || localStorage.getItem("lavida_connect_customer_email") || "";
    if(!getValue("contact_phone"))serviceState.answers.contact_phone = meta.phone || meta.phone_number || localStorage.getItem("lavida_connect_customer_phone") || "";
  }
  function normalizePrintCards(){
    try{
      const card = PRINT_SERVICE_CARDS.find((row)=>row.code==="cv_printing");
      if(card){
        card.name = "Document Printing";
        card.description = "Print completed CVs, reports and professional documents.";
        card.fallbackLabel = card.fallbackLabel || "From saved print pricing";
      }
      renderPrintServices?.();
    }catch(error){}
  }
  function injectHomeCards(){
    const home = byId("connectHome");
    const hero = home?.querySelector(".home-hero-carousel");
    if(!home || !hero || byId("professionalServicesHome"))return;
    const section = document.createElement("section");
    section.id = "professionalServicesHome";
    section.className = "professional-services";
    section.innerHTML = `<div class="professional-services-head"><div><h2>Professional Services</h2><p>Request work, upload evidence, review quotes and track delivery.</p></div></div>
      <div class="professional-service-grid">
        ${serviceCardMarkup("digital","digital")}
        ${serviceCardMarkup("documents","documents")}
        <a class="professional-service-card printing" href="#print365" data-service-page="print365"><span class="professional-service-icon">${icon("printing")}</span><span class="professional-service-copy"><strong>Printing Services</strong><span>Professional physical printing and finishing.</span><span class="professional-service-action">Start Printing</span></span></a>
      </div>`;
    hero.insertAdjacentElement("afterend",section);
    const mainListTitle = [...home.querySelectorAll(".home-section-title")].find((node)=>node.textContent.trim()==="More Services");
    if(mainListTitle)mainListTitle.textContent = "Explore More";
    retargetPopularCards();
  }
  function serviceCardMarkup(key,iconName){
    const area = SERVICE_AREAS[key];
    return `<button class="professional-service-card ${key}" type="button" data-service-start="${key}"><span class="professional-service-icon">${icon(iconName)}</span><span class="professional-service-copy"><strong>${escapeHtml(area.title)}</strong><span>${escapeHtml(area.description)}</span><span class="professional-service-action">${escapeHtml(area.cta)}</span></span></button>`;
  }
  function retargetPopularCards(){
    document.querySelectorAll(".popular-service-card").forEach((card)=>{
      const text = card.textContent.toLowerCase();
      if(/cv design|document services/.test(text)){
        card.setAttribute("href","#");
        card.setAttribute("data-service-start","documents");
        card.removeAttribute("data-service-page");
      }
      if(/systems support/.test(text)){
        card.setAttribute("href","#");
        card.setAttribute("data-service-start","digital");
        card.removeAttribute("data-service-page");
      }
    });
  }
  function injectAccountServices(){
    const account = byId("contact");
    if(!account || byId("myServicesPanel"))return;
    const panel = document.createElement("section");
    panel.id = "myServicesPanel";
    panel.className = "my-services-panel";
    panel.innerHTML = `<div class="my-services-head"><h3>My Services</h3><button id="refreshMyServicesButton" class="service-small-button" type="button">Refresh</button></div>
      <div id="myServicesTabs" class="my-services-tabs" aria-label="Service filters"></div>
      <div id="myServicesList" class="my-service-list"><div class="service-notice">Sign in to view your service requests.</div></div>
      <div id="serviceDetailPanel" class="service-detail-panel hidden"></div>`;
    account.insertAdjacentElement("afterbegin",panel);
    const adminTools = byId("adminToolsSection");
    if(adminTools && !byId("serviceRequestsAdminAccountLink")){
      const link = document.createElement("a");
      link.id = "serviceRequestsAdminAccountLink";
      link.href = "service-requests-admin.html";
      link.innerHTML = "Service Requests Admin <span>Open</span>";
      adminTools.appendChild(link);
    }
    const adminMenu = byId("lavidaAdminMenuSection");
    if(adminMenu && !byId("serviceRequestsAdminMenuLink")){
      const link = document.createElement("a");
      link.id = "serviceRequestsAdminMenuLink";
      link.href = "service-requests-admin.html";
      link.setAttribute("data-menu-destination","service-requests-admin.html");
      link.textContent = "Service Requests Admin";
      adminMenu.appendChild(link);
    }
  }
  function injectModal(){
    if(byId("serviceRequestModal"))return;
    const modal = document.createElement("div");
    modal.id = "serviceRequestModal";
    modal.className = "service-request-modal";
    modal.setAttribute("role","dialog");
    modal.setAttribute("aria-modal","true");
    modal.setAttribute("aria-labelledby","serviceRequestTitle");
    modal.hidden = true;
    modal.innerHTML = `<div class="service-request-sheet">
      <header class="service-request-head"><div><span id="serviceRequestKicker">Service Request</span><h2 id="serviceRequestTitle">Request Service</h2></div><button id="closeServiceRequestButton" class="service-request-close" type="button" aria-label="Back">&larr;</button></header>
      <nav id="serviceProgress" class="service-progress" aria-label="Request steps"></nav>
      <div id="serviceRequestBody" class="service-request-body"></div>
      <div class="service-request-actions"><button id="serviceBackButton" class="secondary" type="button">Back</button><button id="serviceNextButton" class="primary" type="button">Continue</button></div>
    </div>`;
    document.body.appendChild(modal);
  }
  function openServiceRequest(area,options={}){
    if(options.restore)restoreDraft();
    serviceState.area = area || serviceState.area || "digital";
    serviceState.step = serviceState.serviceCode ? Math.max(0,serviceState.step||0) : 0;
    setNotice("","");
    preloadContact();
    byId("serviceRequestModal").hidden = false;
    document.body.classList.add("business-modal-open");
    document.body.classList.add("service-request-open");
    renderServiceRequest();
  }
  function closeServiceRequest(){
    saveDraft();
    byId("serviceRequestModal").hidden = true;
    document.body.classList.remove("business-modal-open");
    document.body.classList.remove("service-request-open");
  }
  function collectCurrentStep(){
    const body = byId("serviceRequestBody");
    if(!body)return;
    body.querySelectorAll("[data-service-field]").forEach((field)=>{
      const key = field.dataset.serviceField;
      if(field.type === "checkbox"){
        const values = [...body.querySelectorAll(`[data-service-field="${CSS.escape(key)}"]:checked`)].map((input)=>input.value);
        serviceState.answers[key] = values;
      }else{
        serviceState.answers[key] = field.value;
      }
    });
    body.querySelectorAll("[data-service-file-note]").forEach((input)=>{
      const row = serviceState.files.find((file)=>file.id===input.dataset.serviceFileNote);
      if(row)row.description = input.value;
    });
    saveDraft();
  }
  function renderServiceRequest(){
    const area = currentArea();
    const steps = ["Service","Details","Files","Review"];
    byId("serviceRequestKicker").textContent = area.shortTitle;
    byId("serviceRequestTitle").textContent = serviceState.submitted ? "Request received" : area.title;
    byId("serviceProgress").innerHTML = steps.map((label,index)=>`<button type="button" data-service-step="${index}" class="${index===serviceState.step?"active":""} ${index<serviceState.step?"done":""}">${escapeHtml(label)}</button>`).join("");
    const body = byId("serviceRequestBody");
    if(serviceState.submitted) body.innerHTML = successMarkup();
    else if(serviceState.step===0) body.innerHTML = serviceSelectionMarkup(area);
    else if(serviceState.step===1) body.innerHTML = detailsMarkup();
    else if(serviceState.step===2) body.innerHTML = filesMarkup();
    else body.innerHTML = reviewMarkup();
    body.querySelectorAll("[data-service-field]").forEach((field)=>{
      const key = field.dataset.serviceField;
      if(field.type !== "checkbox" && Object.prototype.hasOwnProperty.call(serviceState.answers,key))field.value = serviceState.answers[key] || "";
    });
    if(serviceState.notice) body.insertAdjacentHTML("beforeend",`<div class="service-notice ${serviceState.noticeType==="bad"?"bad":""}">${escapeHtml(serviceState.notice)}</div>`);
    const actions = document.querySelector(".service-request-actions");
    const back = byId("serviceBackButton"), next = byId("serviceNextButton");
    actions.classList.toggle("hidden",!serviceState.submitted && serviceState.step===0);
    back.textContent = serviceState.submitted ? "Done" : serviceState.step===0 ? "Close" : "Back";
    next.classList.toggle("hidden",Boolean(serviceState.submitted));
    next.textContent = serviceState.step===3 ? (serviceState.submitting ? "Submitting..." : "Submit Request") : "Continue";
    next.disabled = serviceState.submitting;
  }
  function serviceSelectionMarkup(area){
    return `<h3 class="service-step-title">What kind of ${area.area==="digital"?"support":"document help"} do you need?</h3>
      <p class="service-step-copy">${escapeHtml(area.longDescription)}</p>
      <div class="service-choice-list">${area.services.map(([code,name,desc])=>`<button class="service-choice ${serviceState.serviceCode===code?"active":""}" type="button" data-service-option="${escapeHtml(code)}"><span><b>${escapeHtml(name)}</b><small>${escapeHtml(desc)}</small></span><span aria-hidden="true">›</span></button>`).join("")}</div>`;
  }
  function dynamicDetailsMarkup(kind){
    if(kind==="website")return `<label class="service-field"><span>What do you need?</span><select data-service-field="website_need"><option value="">Choose one</option><option>New website</option><option>Existing website redesign</option><option>Website maintenance</option><option>E-commerce website</option><option>Web application</option><option>Customer/client portal</option><option>Hosting only</option><option>Domain only</option><option>Business email</option><option>Website migration</option><option>Other</option></select></label>
      <label class="service-field full"><span>What would you like us to help you achieve?</span><textarea data-service-field="goal" placeholder="Tell us about your organisation, project or business, the problem you want solved, and what the finished solution should achieve.">${escapeHtml(getValue("goal"))}</textarea></label>
      <label class="service-field"><span>Existing website URL</span><input data-service-field="existing_url" value="${escapeHtml(getValue("existing_url"))}" placeholder="https://..."></label>
      ${checks("existing_assets",["Domain","Hosting","Existing website","Logo","Brand colours","Website content","Product/service information","Database","Existing source code","None yet"])}`;
    if(kind==="hosting")return `<label class="service-field"><span>Do you already have a website?</span><select data-service-field="has_website"><option></option><option>Yes</option><option>No</option><option>Not sure</option></select></label>
      <label class="service-field"><span>Do you already have hosting?</span><select data-service-field="has_hosting"><option></option><option>Yes</option><option>No</option><option>Not sure</option></select></label>
      <label class="service-field"><span>Current provider</span><input data-service-field="hosting_provider" value="${escapeHtml(getValue("hosting_provider"))}" placeholder="If applicable"></label>
      <label class="service-field"><span>Domain name</span><input data-service-field="domain_name" value="${escapeHtml(getValue("domain_name"))}" placeholder="example.com"></label>
      <label class="service-field"><span>Website type</span><select data-service-field="website_type"><option></option><option>Business website</option><option>E-commerce</option><option>Web app</option><option>Portfolio</option><option>Blog/content site</option><option>Other</option></select></label>
      <label class="service-field"><span>Preferred billing</span><select data-service-field="billing_period"><option></option><option>Monthly</option><option>Quarterly</option><option>Yearly</option><option>Not sure</option></select></label>
      ${checks("hosting_needs",["New setup","Migration support","Business email","SSL/configuration support","Ongoing maintenance/support"])}`;
    if(kind==="software")return `<label class="service-field"><span>Which solution?</span><select data-service-field="software_solution"><option></option><option>QuickBooks</option><option>Sage</option><option>Microsoft 365</option><option>Canva</option><option>Accounting software</option><option>HR software</option><option>POS software</option><option>Other</option></select></label>
      <label class="service-field"><span>How many users?</span><input data-service-field="user_count" type="number" min="1" value="${escapeHtml(getValue("user_count"))}" placeholder="Example: 5"></label>
      <label class="service-field"><span>Active licence/subscription?</span><select data-service-field="has_license"><option></option><option>Yes</option><option>No</option><option>Not sure</option></select></label>
      ${checks("software_assistance",["Subscription/setup assistance","Installation","Initial setup","Configuration","Data migration","Training","Troubleshooting","Ongoing support"])}`;
    if(kind==="cv")return `<label class="service-field"><span>What do you need?</span><select data-service-field="cv_need"><option></option><option>Create a new CV</option><option>Redesign my existing CV</option><option>Update my CV</option><option>Convert my old CV into a modern digital CV</option></select></label>
      <label class="service-field"><span>Target job/industry</span><input data-service-field="target_industry" value="${escapeHtml(getValue("target_industry"))}" placeholder="Example: Accounting internship"></label>
      <label class="service-field full"><span>Background, education and experience</span><textarea data-service-field="experience_summary" placeholder="Share your education, work experience, internships, skills, achievements and certifications.">${escapeHtml(getValue("experience_summary"))}</textarea></label>
      <div class="service-notice">You bring the experience. We structure and present it professionally.</div>`;
    if(kind==="report")return `<label class="service-field"><span>Institution</span><input data-service-field="institution" value="${escapeHtml(getValue("institution"))}"></label>
      <label class="service-field"><span>Programme/course</span><input data-service-field="programme" value="${escapeHtml(getValue("programme"))}"></label>
      <label class="service-field"><span>Organisation where work took place</span><input data-service-field="work_organization" value="${escapeHtml(getValue("work_organization"))}"></label>
      <label class="service-field"><span>Period</span><input data-service-field="work_period" value="${escapeHtml(getValue("work_period"))}" placeholder="Example: Jun-Aug 2026"></label>
      <label class="service-field full"><span>Activities performed and skills gained</span><textarea data-service-field="activities" placeholder="Describe work you actually performed, evidence you have and key experiences.">${escapeHtml(getValue("activities"))}</textarea></label>
      <label class="service-field"><span>Required format?</span><select data-service-field="required_format"><option></option><option>Yes</option><option>No</option><option>Not sure</option></select></label>
      <div class="service-notice">Upload guidelines, templates, rubrics, notes, photos, timesheets or previous drafts in the Files step.</div>`;
    return `<label class="service-field"><span>Document goal</span><select data-service-field="document_goal"><option></option><option>Create new document</option><option>Redesign existing document</option><option>Format and polish</option><option>Prepare from notes/evidence</option><option>Other</option></select></label>
      <label class="service-field full"><span>Source material and expected result</span><textarea data-service-field="source_materials" placeholder="Tell us what information you already have and what the finished document should achieve.">${escapeHtml(getValue("source_materials"))}</textarea></label>`;
  }
  function checks(name,options){
    const selected = Array.isArray(serviceState.answers[name]) ? serviceState.answers[name] : [];
    return `<div class="service-field full"><span>${name==="existing_assets"?"What do you already have?":"Select all that apply"}</span><div class="service-checks">${options.map((option)=>`<label><input data-service-field="${escapeHtml(name)}" type="checkbox" value="${escapeHtml(option)}" ${selected.includes(option)?"checked":""}> ${escapeHtml(option)}</label>`).join("")}</div></div>`;
  }
  function detailsMarkup(){
    const kind = serviceKind(serviceState.serviceCode);
    return `<h3 class="service-step-title">${escapeHtml(currentServiceName())}</h3><p class="service-step-copy">Add the key details. LAVIDA will review the scope before quoting custom work.</p>
      <div class="service-field-grid">
        <label class="service-field"><span>Request title</span><input data-service-field="title" value="${escapeHtml(getValue("title"))}" placeholder="Short title"></label>
        <label class="service-field"><span>Deadline</span><input data-service-field="deadline" type="date" value="${escapeHtml(getValue("deadline"))}"></label>
        <label class="service-field full"><span>Main request</span><textarea data-service-field="description" placeholder="Describe what you need.">${escapeHtml(getValue("description"))}</textarea></label>
        ${dynamicDetailsMarkup(kind)}
        <label class="service-field"><span>Full name</span><input data-service-field="contact_name" value="${escapeHtml(getValue("contact_name"))}" placeholder="Your name"></label>
        <label class="service-field"><span>Phone</span><input data-service-field="contact_phone" type="tel" value="${escapeHtml(getValue("contact_phone"))}" placeholder="Phone number"></label>
        <label class="service-field full"><span>Email</span><input data-service-field="contact_email" type="email" value="${escapeHtml(getValue("contact_email"))}" placeholder="Email address"></label>
      </div>`;
  }
  function filesMarkup(){
    return `<h3 class="service-step-title">Evidence and supporting files</h3><p class="service-step-copy">Add up to ${MAX_FILES} files. You can include CVs, certificates, screenshots, templates, branding, report guidelines, spreadsheets, images or ZIP files.</p>
      <label class="service-file-input"><b>+ Add another file</b><input id="serviceFilesInput" type="file" multiple accept=".pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.jpg,.jpeg,.png,.zip,application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/vnd.openxmlformats-officedocument.presentationml.presentation,image/jpeg,image/png,application/zip"></label>
      <div class="service-file-list">${serviceState.files.map((row)=>fileRowMarkup(row)).join("") || `<div class="service-notice">No files added yet. Files are optional at this stage, but they help LAVIDA quote accurately.</div>`}</div>`;
  }
  function fileRowMarkup(row){
    const progress = row.uploaded ? 100 : row.uploading ? 55 : 0;
    const status = row.uploaded ? "Uploaded" : row.uploading ? "Uploading..." : "Ready to upload";
    return `<div class="service-file-row"><div class="service-file-row-top"><span><b>${escapeHtml(row.file.name)}</b><small>${escapeHtml(fileSize(row.file.size))} · ${escapeHtml(status)}</small></span><button type="button" data-remove-service-file="${escapeHtml(row.id)}">Remove</button></div><div class="service-upload-progress" aria-label="${escapeHtml(status)}"><span style="width:${progress}%"></span></div><label class="service-field"><span>What is this file?</span><input data-service-file-note="${escapeHtml(row.id)}" value="${escapeHtml(row.description || "")}" placeholder="Example: Existing CV - current version"></label></div>`;
  }
  function reviewMarkup(){
    const answers = serviceState.answers;
    const rows = [
      ["Service area",currentArea().title],
      ["Selected service",currentServiceName()],
      ["Request title",answers.title || currentServiceName()],
      ["Main request",answers.description || answers.goal || answers.source_materials || "Not provided"],
      ["Deadline",answers.deadline || "Not specified"],
      ["Files",`${serviceState.files.length} file${serviceState.files.length===1?"":"s"}`],
      ["Contact",`${answers.contact_name || ""} ${answers.contact_phone ? " / " + answers.contact_phone : ""} ${answers.contact_email ? " / " + answers.contact_email : ""}`.trim()]
    ];
    return `<h3 class="service-step-title">Review request</h3><p class="service-step-copy">Check the summary before sending it to LAVIDA for professional review.</p><div class="service-review">${rows.map(([label,value])=>`<div class="service-review-row"><span>${escapeHtml(label)}</span><b>${escapeHtml(value)}</b></div>`).join("")}</div><div class="service-notice">After submission, LAVIDA will review your requirements and supporting files. If scope confirmation is needed, your quotation or invoice will appear in My Services.</div>`;
  }
  function successMarkup(){
    const row = serviceState.submitted;
    return `<div class="service-success"><span class="service-success-icon">${icon("check")}</span><h3 class="service-step-title">Request received successfully</h3><p class="service-step-copy">Your request has been sent to the LAVIDA team for review.</p><div class="service-review"><div class="service-review-row"><span>Request ID</span><b>${escapeHtml(row.request_number || row.requestNumber)}</b></div><div class="service-review-row"><span>Status</span><b>${escapeHtml(statusLabel(row.status || "submitted"))}</b></div></div><p class="service-step-copy">Once the scope is confirmed, your quotation or invoice will appear in your account and you will receive a notification.</p><button class="service-small-button" type="button" data-view-my-services>View My Request</button></div>`;
  }
  function validateStep(){
    collectCurrentStep();
    setNotice("","");
    if(serviceState.step===0 && !serviceState.serviceCode){setNotice("Choose the service you need.","bad");return false}
    if(serviceState.step===1){
      const a = serviceState.answers;
      if(!a.description && !a.goal && !a.source_materials){setNotice("Tell us what you need help with.","bad");return false}
      if(!a.contact_name || !a.contact_phone || !a.contact_email){setNotice("Add your name, phone and email so LAVIDA can follow up.","bad");return false}
      if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(a.contact_email)){setNotice("Please enter a valid email address.","bad");return false}
    }
    return true;
  }
  async function nextStep(){
    if(serviceState.submitted)return;
    if(serviceState.step < 3){
      if(!validateStep()){renderServiceRequest();return}
      serviceState.step += 1;
      renderServiceRequest();
      return;
    }
    if(!validateStep()){renderServiceRequest();return}
    await submitRequest();
  }
  function prevStep(){
    if(serviceState.submitted){closeServiceRequest();return}
    if(serviceState.step===0){closeServiceRequest();return}
    collectCurrentStep();
    serviceState.step -= 1;
    renderServiceRequest();
  }
  function backFromHeader(){
    if(serviceState.submitted){closeServiceRequest();return}
    if(serviceState.step===0){closeServiceRequest();return}
    collectCurrentStep();
    serviceState.step -= 1;
    renderServiceRequest();
  }
  function addFiles(fileList){
    setNotice("","");
    const incoming = Array.from(fileList || []);
    for(const file of incoming){
      if(serviceState.files.length >= MAX_FILES){setNotice(`You can upload up to ${MAX_FILES} files in the initial request.`,"bad");break}
      const error = fileAllowed(file);
      if(error){setNotice(error,"bad");continue}
      serviceState.files.push({id:crypto.randomUUID(),file,description:"",uploaded:false});
    }
    renderServiceRequest();
  }
  async function uploadServiceFile(requestId,row){
    const userId = authSession.user.id;
    const cleanedName = typeof safeFileName === "function" ? safeFileName(row.file.name) : row.file.name.replace(/[^\w.-]+/g,"_");
    const path = `${userId}/${requestId}/${Date.now()}-${cleanedName}`;
    row.uploading = true;
    if(serviceState.step === 2)renderServiceRequest();
    try{
      const {error} = await db.storage.from("service-request-files").upload(path,row.file,{upsert:false,contentType:row.file.type || "application/octet-stream"});
      if(error)throw error;
      row.uploading = false;
      row.uploaded = true;
      if(serviceState.step === 2)renderServiceRequest();
      return path;
    }catch(error){
      row.uploading = false;
      if(serviceState.step === 2)renderServiceRequest();
      throw error;
    }
  }
  async function submitRequest(){
    serviceState.submitting = true;
    renderServiceRequest();
    try{
      const session = authSession?.user ? authSession : await refreshAuthSession?.();
      if(!session?.user){
        serviceState.submitting = false;
        saveDraft();
        sessionStorage.setItem("lavida_pending_service_request","1");
        requestSignIn?.("marketplace.html#account");
        return;
      }
      const area = currentArea();
      const service = currentService();
      const number = requestNumber(area.code);
      const payload = {
        user_id: session.user.id,
        request_number: number,
        service_area: area.area,
        service_area_name: area.title,
        service_code: serviceState.serviceCode,
        service_name: service ? service[1] : area.title,
        commercial_route: ["website_development","website_redesign","web_application","hosting_migration","internship_report","project_report"].includes(serviceState.serviceCode) ? "custom_quote" : "review_first",
        status: "submitted",
        title: serviceState.answers.title || (service ? service[1] : area.title),
        description: serviceState.answers.description || serviceState.answers.goal || serviceState.answers.source_materials || "",
        deadline: serviceState.answers.deadline || null,
        contact_name: serviceState.answers.contact_name,
        contact_phone: serviceState.answers.contact_phone,
        contact_email: serviceState.answers.contact_email,
        existing_website_url: serviceState.answers.existing_url || null,
        answers: serviceState.answers,
        uploaded_file_count: serviceState.files.length
      };
      const {data,error} = await db.from("service_requests").insert(payload).select("*").single();
      if(error)throw error;
      const fileRows = [];
      for(const row of serviceState.files){
        const path = await uploadServiceFile(data.id,row);
        fileRows.push({request_id:data.id,storage_bucket:"service-request-files",storage_path:path,file_name:row.file.name,file_type:row.file.type || "",file_size_bytes:row.file.size,file_description:row.description || "",uploaded_by:session.user.id});
      }
      if(fileRows.length){
        const {error:fileError}=await db.from("service_request_files").insert(fileRows);
        if(fileError)throw fileError;
      }
      await db.from("service_project_updates").insert({request_id:data.id,created_by:session.user.id,visible_to_customer:true,update_type:"status",message:"Request submitted for LAVIDA review."});
      localStorage.setItem("lavida_connect_customer_phone", serviceState.answers.contact_phone);
      localStorage.setItem("lavida_connect_customer_email", serviceState.answers.contact_email);
      serviceState.submitted = data;
      serviceState.submitting = false;
      clearDraft();
      loadMyServices();
      renderServiceRequest();
    }catch(error){
      console.error("LAVIDA service request submit error",error);
      serviceState.submitting = false;
      setNotice(friendlyServiceError(error),"bad");
      renderServiceRequest();
    }
  }
  function friendlyServiceError(error){
    const message = String(error?.message || "");
    if(/service_requests|schema cache|relation .* does not exist|PGRST205|42P01/i.test(message) || ["PGRST205","42P01"].includes(error?.code))return "The service request workspace is being installed. Please try again shortly.";
    if(/storage|bucket|permission|row level|unauthorized|42501/i.test(`${message} ${error?.code || ""}`))return "This file couldn't be uploaded. Try again or choose another file.";
    return "We couldn't submit your request. Please check your connection and try again.";
  }
  function renderMyServicesTabs(){
    const tabs = byId("myServicesTabs");
    if(!tabs)return;
    tabs.innerHTML = SERVICE_TABS.map(([key,label])=>`<button type="button" class="${activeServiceTab===key?"active":""}" data-my-service-tab="${key}">${escapeHtml(label)}</button>`).join("");
  }
  function filteredServices(){
    if(activeServiceTab==="all")return myServices;
    return myServices.filter((row)=>requestBucket(row)===activeServiceTab);
  }
  function renderMyServices(){
    renderMyServicesTabs();
    const list = byId("myServicesList");
    if(!list)return;
    if(!authSession?.user){list.innerHTML = `<div class="service-notice">Sign in to view your service requests.</div>`;return}
    const rows = filteredServices();
    if(!myServices.length){list.innerHTML = `<div class="service-notice">No service requests yet. Start with Digital Support or Documents from the Home page.</div>`;return}
    if(!rows.length){list.innerHTML = `<div class="service-notice">No services in this filter.</div>`;return}
    list.innerHTML = rows.map((row)=>`<article class="my-service-card"><header><div><h4>${escapeHtml(row.service_name || row.title)}</h4><small>${escapeHtml(row.request_number)} · ${escapeHtml(cleanDate?.(row.created_at) || "")}</small></div><span class="service-status">${escapeHtml(statusLabel(row.status))}</span></header><div class="my-service-meta"><span>Area: <b>${escapeHtml(row.service_area_name || row.service_area)}</b></span><span>Files: <b>${escapeHtml(row.uploaded_file_count || 0)}</b></span><span>Quote: <b>${escapeHtml(statusLabel(row.quote_status || "none"))}</b></span><span>Invoice: <b>${escapeHtml(statusLabel(row.invoice_status || "none"))}</b></span></div><button class="order-action-primary" type="button" data-service-detail="${escapeHtml(row.id)}">View Details</button></article>`).join("");
  }
  async function loadMyServices(){
    const list = byId("myServicesList");
    if(!list)return;
    renderMyServicesTabs();
    const session = authSession?.user ? authSession : await refreshAuthSession?.();
    if(!session?.user){renderMyServices();return}
    list.innerHTML = `<div class="service-notice">Loading your service requests...</div>`;
    try{
      const {data,error}=await db.from("service_requests").select("*").eq("user_id",session.user.id).order("created_at",{ascending:false}).limit(50);
      if(error)throw error;
      myServices = data || [];
      renderMyServices();
    }catch(error){
      myServices = localRequests().filter((row)=>row.user_id===session.user.id);
      list.innerHTML = `<div class="service-notice bad">${escapeHtml(friendlyServiceError(error))}</div>`;
      if(myServices.length)renderMyServices();
    }
  }
  async function viewServiceDetail(id){
    const panel = byId("serviceDetailPanel");
    if(!panel)return;
    panel.classList.remove("hidden");
    panel.innerHTML = `<div class="service-notice">Loading service details...</div>`;
    try{
      const {data,error}=await db.from("service_requests").select("*,service_request_files(*),service_quotes(*,service_quote_items(*)),service_invoices(*),service_project_updates(*)").eq("id",id).single();
      if(error)throw error;
      panel.innerHTML = serviceDetailMarkup(data);
      panel.scrollIntoView({behavior:"smooth",block:"start"});
    }catch(error){
      panel.innerHTML = `<div class="service-notice bad">${escapeHtml(friendlyServiceError(error))}</div>`;
    }
  }
  function serviceDetailMarkup(row){
    const files = row.service_request_files || [];
    const quotes = row.service_quotes || [];
    const invoices = row.service_invoices || [];
    const updates = row.service_project_updates || [];
    return `<h4>${escapeHtml(row.service_name || row.title)}</h4><div class="service-review">
      <div class="service-review-row"><span>Request ID</span><b>${escapeHtml(row.request_number)}</b></div>
      <div class="service-review-row"><span>Status</span><b>${escapeHtml(statusLabel(row.status))}</b></div>
      <div class="service-review-row"><span>Requirements</span><b>${escapeHtml(row.description || "Not provided")}</b></div>
      <div class="service-review-row"><span>Deadline</span><b>${escapeHtml(row.deadline || "Not specified")}</b></div>
    </div>
    <h4>Uploaded Files</h4><div class="service-file-list">${files.map((file)=>`<div class="service-file-row"><b>${escapeHtml(file.file_name)}</b><small>${escapeHtml(file.file_description || file.file_type || "")}</small></div>`).join("") || `<div class="service-notice">No files uploaded yet.</div>`}</div>
    <label class="service-file-input"><b>Upload More Files</b><input type="file" id="serviceMoreFiles" multiple accept=".pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.jpg,.jpeg,.png,.zip"></label><button class="service-small-button" type="button" data-upload-more-service-files="${escapeHtml(row.id)}">Add Files</button>
    <h4>Quote</h4>${quotes.map((quote)=>`<div class="service-review-row"><span>${escapeHtml(statusLabel(quote.status))}</span><b>${escapeHtml(quote.scope || "Quote ready")} · ${typeof money==="function"?money(quote.total_mwk):quote.total_mwk}</b></div>`).join("") || `<div class="service-notice">No quote yet.</div>`}
    <h4>Invoice</h4>${invoices.map((invoice)=>`<div class="service-review-row"><span>${escapeHtml(statusLabel(invoice.status))}</span><b>${escapeHtml(invoice.invoice_number || "Invoice")} · ${typeof money==="function"?money(invoice.total_mwk):invoice.total_mwk}</b></div>`).join("") || `<div class="service-notice">No invoice yet.</div>`}
    <h4>Messages / Updates</h4><div class="timeline">${updates.filter((row)=>row.visible_to_customer!==false).map((update)=>`<div class="timeline-step"><span class="timeline-dot"></span><div><b>${escapeHtml(update.message)}</b><br><small>${escapeHtml(cleanDate?.(update.created_at) || "")}</small></div></div>`).join("") || `<div class="service-notice">No updates yet.</div>`}</div>`;
  }
  async function uploadMoreFiles(requestId){
    const input = byId("serviceMoreFiles");
    const files = Array.from(input?.files || []);
    const panel = byId("serviceDetailPanel");
    if(!files.length){panel.insertAdjacentHTML("beforeend",`<div class="service-notice bad">Choose at least one file.</div>`);return}
    try{
      const session = authSession?.user ? authSession : await refreshAuthSession?.();
      if(!session?.user){requestSignIn?.("marketplace.html#account");return}
      const rows = [];
      for(const file of files){
        const err = fileAllowed(file);
        if(err)throw new Error(err);
        const temp = {file,id:crypto.randomUUID(),description:"Additional file"};
        const path = await uploadServiceFile(requestId,temp);
        rows.push({request_id:requestId,storage_bucket:"service-request-files",storage_path:path,file_name:file.name,file_type:file.type || "",file_size_bytes:file.size,file_description:"Additional file",uploaded_by:session.user.id});
      }
      const {error}=await db.from("service_request_files").insert(rows);
      if(error)throw error;
      await db.from("service_project_updates").insert({request_id:requestId,created_by:session.user.id,visible_to_customer:true,update_type:"file",message:`${rows.length} additional file${rows.length===1?"":"s"} uploaded.`});
      await viewServiceDetail(requestId);
      await loadMyServices();
    }catch(error){
      panel.insertAdjacentHTML("beforeend",`<div class="service-notice bad">${escapeHtml(friendlyServiceError(error))}</div>`);
    }
  }
  function bindEvents(){
    document.addEventListener("click",(event)=>{
      const start = event.target.closest("[data-service-start]");
      if(start){event.preventDefault();event.stopPropagation();serviceState=freshState();openServiceRequest(start.dataset.serviceStart,{restore:false});return}
      const option = event.target.closest("[data-service-option]");
      if(option){serviceState.serviceCode=option.dataset.serviceOption;serviceState.step=1;setNotice("","");saveDraft();renderServiceRequest();return}
      const step = event.target.closest("[data-service-step]");
      if(step){collectCurrentStep();const target=Number(step.dataset.serviceStep);if(target<=serviceState.step || validateStep()){serviceState.step=target;renderServiceRequest();}return}
      if(event.target.closest("#closeServiceRequestButton")){backFromHeader();return}
      if(event.target.closest("#serviceNextButton")){nextStep();return}
      if(event.target.closest("#serviceBackButton")){prevStep();return}
      const remove = event.target.closest("[data-remove-service-file]");
      if(remove){serviceState.files=serviceState.files.filter((row)=>row.id!==remove.dataset.removeServiceFile);renderServiceRequest();return}
      const tab = event.target.closest("[data-my-service-tab]");
      if(tab){activeServiceTab=tab.dataset.myServiceTab;renderMyServices();return}
      const detail = event.target.closest("[data-service-detail]");
      if(detail){viewServiceDetail(detail.dataset.serviceDetail);return}
      if(event.target.closest("#refreshMyServicesButton")){loadMyServices();return}
      const uploadMore = event.target.closest("[data-upload-more-service-files]");
      if(uploadMore){uploadMoreFiles(uploadMore.dataset.uploadMoreServiceFiles);return}
      if(event.target.closest("[data-view-my-services]")){closeServiceRequest();navigateRoute?.("account",{resetScroll:true});loadMyServices();return}
      if(event.target.id==="serviceRequestModal")closeServiceRequest();
    },true);
    document.addEventListener("change",(event)=>{
      if(event.target?.id==="serviceFilesInput")addFiles(event.target.files);
    });
    document.addEventListener("input",(event)=>{
      if(event.target.matches("[data-service-field],[data-service-file-note]"))collectCurrentStep();
    });
  }
  function init(){
    normalizePrintCards();
    injectHomeCards();
    injectAccountServices();
    injectModal();
    bindEvents();
    renderMyServicesTabs();
    restoreDraft();
    if(sessionStorage.getItem("lavida_pending_service_request")){
      sessionStorage.removeItem("lavida_pending_service_request");
      setTimeout(()=>openServiceRequest(serviceState.area || "digital",{restore:true}),300);
    }
    const originalShowPage = window.showPage;
    if(typeof originalShowPage === "function"){
      window.showPage = function(page,options){
        const result = originalShowPage.apply(this,arguments);
        if(page==="account")setTimeout(loadMyServices,0);
        return result;
      };
    }
    setTimeout(()=>{if(location.hash==="#account")loadMyServices();},500);
  }

  if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",init);
  else init();
})();
