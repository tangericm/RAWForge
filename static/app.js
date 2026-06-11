/* RAWForge web UI — vanilla JS, no build step. */

const $ = (id) => document.getElementById(id);
const state = {
  files: [],
  configs: [],
  selectedFile: null,
  selectedConfig: null,
  selectedJob: null,   // job_id
  jobMeta: null,       // metadata.json of selected job
  stageIdx: 0,
  compare: false,
  compareA: 0,
  compareB: 0,
  divider: 0.5,
  completedIds: new Set(),
};

const api = {
  get: async (path) => (await fetch(`/api${path}`)).json(),
  post: async (path, body) => {
    const r = await fetch(`/api${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!r.ok) throw new Error((await r.json()).detail || r.statusText);
    return r.json();
  },
  del: (path) => fetch(`/api${path}`, { method: "DELETE" }),
};

/* ---------- files & configs ---------- */

async function loadFiles(selectPath) {
  state.files = await api.get("/files");
  const ul = $("file-list");
  ul.innerHTML = "";
  for (const f of state.files) {
    const li = document.createElement("li");
    li.textContent = f.name;
    li.title = `${f.path} (${f.mb} MB)`;
    li.onclick = () => { state.selectedFile = f.path; render(); };
    li.dataset.path = f.path;
    ul.appendChild(li);
  }
  if (selectPath) state.selectedFile = selectPath;
  if (!state.selectedFile && state.files.length) state.selectedFile = state.files[0].path;
  render();
}

async function loadConfigs() {
  state.configs = await api.get("/configs");
  const sel = $("config-select");
  sel.innerHTML = "";
  for (const c of state.configs) {
    const opt = document.createElement("option");
    opt.value = c.file;
    opt.textContent = c.name;
    sel.appendChild(opt);
  }
  if (state.configs.length) state.selectedConfig = state.configs[0].file;
  sel.onchange = () => { state.selectedConfig = sel.value; render(); };
  render();
}

function setupUpload() {
  const dz = $("dropzone");
  const input = $("file-input");
  dz.onclick = () => input.click();
  input.onchange = () => input.files.length && uploadFile(input.files[0]);
  dz.ondragover = (e) => { e.preventDefault(); dz.classList.add("drag"); };
  dz.ondragleave = () => dz.classList.remove("drag");
  dz.ondrop = (e) => {
    e.preventDefault();
    dz.classList.remove("drag");
    if (e.dataTransfer.files.length) uploadFile(e.dataTransfer.files[0]);
  };
}

async function uploadFile(file) {
  const dz = $("dropzone");
  dz.textContent = `uploading ${file.name}…`;
  const form = new FormData();
  form.append("file", file);
  try {
    const r = await fetch("/api/uploads", { method: "POST", body: form });
    if (!r.ok) throw new Error((await r.json()).detail || r.statusText);
    const entry = await r.json();
    await loadFiles(entry.path);
  } catch (err) {
    alert(`Upload failed: ${err.message}`);
  } finally {
    dz.innerHTML = 'drop a RAW file here<br><span class="muted">or click to browse</span>';
  }
}

/* ---------- jobs ---------- */

async function runJob() {
  if (!state.selectedFile || !state.selectedConfig) return;
  $("run-btn").disabled = true;
  try {
    await api.post("/jobs", { file: state.selectedFile, config: state.selectedConfig });
  } catch (err) {
    alert(`Run failed: ${err.message}`);
  }
  pollJobs();
}

let pollTimer = null;
let firstPoll = true;

async function pollJobs() {
  const { active, completed } = await api.get("/jobs");
  state.lastCompleted = completed;
  renderActive(active);
  renderCompleted(completed);

  // Auto-open a job that just finished (but not the backlog on page load).
  const fresh = completed.filter((j) => !state.completedIds.has(j.job_id));
  completed.forEach((j) => state.completedIds.add(j.job_id));
  if (!firstPoll && fresh.length && !document.hidden) selectJob(fresh[0].job_id);
  firstPoll = false;

  const busy = active.some((a) => a.status === "queued" || a.status === "running");
  $("queue-status").textContent = busy
    ? `processing… (${active.filter((a) => a.status !== "error").length} in queue)`
    : "";
  clearTimeout(pollTimer);
  pollTimer = setTimeout(pollJobs, busy ? 700 : 4000);
}

function renderActive(active) {
  const box = $("active-jobs");
  box.innerHTML = "";
  for (const a of active) {
    const div = document.createElement("div");
    div.className = `active-card${a.status === "error" ? " error" : ""}`;
    if (a.status === "error") {
      div.innerHTML = `<button class="dismiss">✕</button><b>${a.file}</b> — <span style="color:var(--err)">${a.error}</span>`;
      div.querySelector(".dismiss").onclick = async () => {
        await api.del(`/active/${a.ticket}`);
        pollJobs();
      };
    } else {
      const pct = Math.round(a.progress * 100);
      div.innerHTML = `<b>${a.file}</b> × ${a.config} — ${a.status === "queued" ? "queued" : `${a.stage} ${pct}%`}
        <div class="progress"><div style="width:${a.status === "queued" ? 0 : pct}%"></div></div>`;
    }
    box.appendChild(div);
  }
}

function renderCompleted(completed) {
  const box = $("job-list");
  box.innerHTML = "";
  if (!completed.length) {
    box.innerHTML = '<div class="empty">No jobs yet — pick a file and a pipeline, then Run.</div>';
    return;
  }
  for (const j of completed) {
    const card = document.createElement("div");
    card.className = `card${j.job_id === state.selectedJob ? " selected" : ""}`;
    card.innerHTML = `
      <div class="title">${j.source}</div>
      <div class="sub">${j.pipeline} · ${j.seconds}s · ${j.created_at.replace("T", " ")}</div>
      <button class="del" title="Delete job">✕</button>`;
    card.onclick = () => selectJob(j.job_id);
    card.querySelector(".del").onclick = async (e) => {
      e.stopPropagation();
      await api.del(`/jobs/${j.job_id}`);
      if (state.selectedJob === j.job_id) { state.selectedJob = null; $("detail").hidden = true; }
      pollJobs();
    };
    box.appendChild(card);
  }
}

/* ---------- job detail / stage viewer ---------- */

async function selectJob(jobId) {
  state.selectedJob = jobId;
  state.jobMeta = await api.get(`/jobs/${jobId}`);
  const previews = stagePreviews();
  state.stageIdx = previews.length - 1;          // land on the final result
  state.compare = false;
  state.compareA = 0;
  state.compareB = previews.length - 1;
  state.divider = 0.5;
  renderDetail();
  renderCompleted(state.lastCompleted || []);
}

function stagePreviews() {
  const m = state.jobMeta;
  if (!m) return [];
  if (m.stage_previews && m.stage_previews.length) {
    return m.stage_previews.map((p) => ({ name: p.name, url: `/runs/${m.job_id}/${p.preview}` }));
  }
  return [{ name: "Output", url: `/runs/${m.job_id}/output.png` }];
}

function renderDetail() {
  const m = state.jobMeta;
  if (!m) { $("detail").hidden = true; return; }
  $("detail").hidden = false;
  $("detail-title").textContent = `${m.source.split(/[\\/]/).pop()} × ${m.pipeline.name}`;
  $("fullres-link").href = `/runs/${m.job_id}/output.png`;

  const previews = stagePreviews();

  // Filmstrip
  const strip = $("filmstrip");
  strip.innerHTML = "";
  previews.forEach((p, i) => {
    const t = document.createElement("div");
    t.className = "thumb";
    if (!state.compare && i === state.stageIdx) t.classList.add("selected");
    if (state.compare && i === state.compareA) t.classList.add("selected", "is-a");
    if (state.compare && i === state.compareB) t.classList.add("selected", "is-b");
    t.innerHTML = `<img loading="lazy" src="${p.url}">
      <div class="cap"><span class="badge a">A</span><span class="badge b">B</span>${i}. ${p.name}</div>`;
    t.onclick = () => {
      if (state.compare) { state.compareB = i; } else { state.stageIdx = i; }
      renderDetail();
    };
    strip.appendChild(t);
  });

  // Compare bar
  $("compare-bar").hidden = !state.compare;
  $("compare-btn").classList.toggle("active", state.compare);
  if (state.compare) {
    for (const [sel, key] of [[$("select-a"), "compareA"], [$("select-b"), "compareB"]]) {
      sel.innerHTML = "";
      previews.forEach((p, i) => {
        const o = document.createElement("option");
        o.value = i;
        o.textContent = `${i}. ${p.name}`;
        sel.appendChild(o);
      });
      sel.value = state[key];
      sel.onchange = () => { state[key] = Number(sel.value); renderDetail(); };
    }
  }

  // Viewer
  const imgA = $("img-a"), imgB = $("img-b"), divider = $("divider");
  if (state.compare) {
    imgA.src = previews[state.compareA].url;
    imgB.src = previews[state.compareB].url;
    imgB.hidden = false;
    divider.hidden = false;
    applyDivider();
    $("stage-label").textContent =
      `A: ${previews[state.compareA].name}  |  B: ${previews[state.compareB].name}`;
  } else {
    imgA.src = previews[state.stageIdx].url;
    imgB.hidden = true;
    divider.hidden = true;
    $("stage-label").textContent = `${state.stageIdx}. ${previews[state.stageIdx].name}`;
  }

  // Timings
  const tbox = $("timings");
  tbox.innerHTML = "";
  const timings = m.timings || [];
  const maxT = Math.max(...timings.map((t) => t.seconds), 0.001);
  for (const t of timings) {
    const row = document.createElement("div");
    row.className = "tbar";
    row.innerHTML = `<span class="name">${t.stage}</span>
      <span class="bar" style="width:${Math.max(2, (t.seconds / maxT) * 160)}px"></span>
      <span class="val">${t.seconds.toFixed(2)}s</span>`;
    tbox.appendChild(row);
  }

  // Frame info
  const f = m.input_frame || {};
  $("frame-info").innerHTML = `
    <tr><td>CFA</td><td>${f.cfa_pattern}</td></tr>
    <tr><td>Size</td><td>${(f.shape || []).join(" × ")}</td></tr>
    <tr><td>Black / white</td><td>${(f.black_level || []).join(", ")} / ${f.white_level}</td></tr>
    <tr><td>As-shot WB</td><td>${(f.wb_gains || []).map((g) => g.toFixed(2)).join(", ")}</td></tr>
    <tr><td>CCM</td><td>${f.ccm ? "present" : "—"}</td></tr>`;
}

/* compare slider */

function applyDivider() {
  const pct = state.divider * 100;
  $("img-b").style.clipPath = `inset(0 ${100 - pct}% 0 0)`;
  $("divider").style.left = `calc(${pct}% - 1px)`;
}

function setupViewer() {
  const viewer = $("stage-viewer");
  let dragging = false;
  const move = (e) => {
    if (!dragging || !state.compare) return;
    const rect = viewer.getBoundingClientRect();
    state.divider = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
    applyDivider();
  };
  viewer.addEventListener("pointerdown", (e) => {
    if (!state.compare) return;
    dragging = true;
    viewer.setPointerCapture(e.pointerId);
    move(e);
  });
  viewer.addEventListener("pointermove", move);
  viewer.addEventListener("pointerup", () => (dragging = false));

  $("compare-btn").onclick = () => { state.compare = !state.compare; renderDetail(); };

  document.addEventListener("keydown", (e) => {
    if (!state.jobMeta || state.compare) return;
    if (e.target.tagName === "SELECT" || e.target.tagName === "INPUT") return;
    const n = stagePreviews().length;
    if (e.key === "ArrowRight") { state.stageIdx = (state.stageIdx + 1) % n; renderDetail(); }
    if (e.key === "ArrowLeft") { state.stageIdx = (state.stageIdx - 1 + n) % n; renderDetail(); }
  });
}

/* ---------- shared render ---------- */

function render() {
  for (const li of $("file-list").children) {
    li.classList.toggle("selected", li.dataset.path === state.selectedFile);
  }
  const cfg = state.configs.find((c) => c.file === state.selectedConfig);
  $("config-stages").innerHTML = (cfg ? cfg.stages : [])
    .map((s) => `<span>${s}</span>`)
    .join("");
  $("run-btn").disabled = !(state.selectedFile && state.selectedConfig);
}

/* ---------- init ---------- */

$("run-btn").onclick = runJob;
setupUpload();
setupViewer();
loadFiles();
loadConfigs();
pollJobs();
