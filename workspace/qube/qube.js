// Shared by every QÜBE page: the Sfere grid, colors, avatars, the data layer and the nav.
// Load after config.js and supabase-js.
(() => {
  const cfg = window.QUBE_CONFIG || {};
  const live = Boolean(cfg.supabaseUrl && cfg.supabaseAnonKey && window.supabase);

  // ------------------------------------------------------------------ grid
  // The Sfere is a cube inflated into a sphere. Each of the 6 faces is cut into
  // N × N Squares on an equiangular grid, so rows and columns run straight.
  // A Square is (row, col): row = face * N + y, col = x.
  // Must match sfere_cell() / sfere_rows() in supabase/004_profiles_types_market.sql.
  const N = 573;
  const Q = Math.PI / 4;
  // Per face: normal n, right r, up t. A point on the cube face is n + a·r + b·t.
  const FACES = [
    { n: [1, 0, 0], r: [0, 0, -1], t: [0, 1, 0] },
    { n: [-1, 0, 0], r: [0, 0, 1], t: [0, 1, 0] },
    { n: [0, 1, 0], r: [1, 0, 0], t: [0, 0, -1] },
    { n: [0, -1, 0], r: [1, 0, 0], t: [0, 0, 1] },
    { n: [0, 0, 1], r: [1, 0, 0], t: [0, 1, 0] },
    { n: [0, 0, -1], r: [-1, 0, 0], t: [0, 1, 0] },
  ];
  const DEG = Math.PI / 180;
  const vecOf = (lat, lon) => [Math.cos(lat * DEG) * Math.cos(lon * DEG), Math.sin(lat * DEG), -Math.cos(lat * DEG) * Math.sin(lon * DEG)];
  const latLonOf = ([x, y, z]) => ({ lat: Math.asin(Math.max(-1, Math.min(1, y))) / DEG, lon: Math.atan2(-z, x) / DEG });
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const norm = (v) => { const l = Math.hypot(v[0], v[1], v[2]); return [v[0] / l, v[1] / l, v[2] / l]; };

  function faceOf(v) {
    const [x, y, z] = v, ax = Math.abs(x), ay = Math.abs(y), az = Math.abs(z);
    if (ax >= ay && ax >= az) return x > 0 ? 0 : 1;
    if (ay >= az) return y > 0 ? 2 : 3;
    return z > 0 ? 4 : 5;
  }
  const grid = {
    N,
    ROWS: 6 * N,
    TOTAL: 6 * N * N,
    FACES,
    cellOfVec(v) {
      const face = faceOf(v), F = FACES[face], d = dot(v, F.n);
      const a = dot(v, F.r) / d, b = dot(v, F.t) / d;
      const i = Math.min(N - 1, Math.max(0, Math.floor(((Math.atan(a) + Q) / (2 * Q)) * N)));
      const j = Math.min(N - 1, Math.max(0, Math.floor(((Math.atan(b) + Q) / (2 * Q)) * N)));
      return { row: face * N + j, col: i };
    },
    cellAt: (lat, lon) => grid.cellOfVec(vecOf(lat, lon)),
    // Unit vector at (u, v) inside a Square; (0.5, 0.5) is its centre.
    dir(row, col, u = 0.5, v = 0.5) {
      const F = FACES[Math.floor(row / N)], j = row % N;
      const a = Math.tan(-Q + ((col + u) / N) * 2 * Q), b = Math.tan(-Q + ((j + v) / N) * 2 * Q);
      return norm([F.n[0] + a * F.r[0] + b * F.t[0], F.n[1] + a * F.r[1] + b * F.t[1], F.n[2] + a * F.r[2] + b * F.t[2]]);
    },
    center: (row, col) => latLonOf(grid.dir(row, col)),
    label(row, col) {
      const p = (n) => String(n).padStart(3, "0");
      return `SQ ${Math.floor(row / N) + 1}·${p(col)}·${p(row % N)}`;
    },
    coords(row, col) {
      const { lat, lon } = grid.center(row, col);
      return `${Math.abs(lat).toFixed(2)}°${lat >= 0 ? "N" : "S"} ${Math.abs(lon).toFixed(2)}°${lon >= 0 ? "E" : "W"}`;
    },
    hash: (row, col) => `${row}.${col}`,
    parseHash(h) {
      const m = /^#?(\d{1,4})\.(\d{1,3})$/.exec(h || "");
      if (!m) return null;
      const row = +m[1], col = +m[2];
      return row < 6 * N && col < N ? { row, col } : null;
    },
  };

  // ---------------------------------------------------------------- colors
  // A member's color is chosen once, at onboarding, and never changes. Any hex works;
  // the picker keeps lightness in a band that reads well on the white Sfere.
  function hslToHex(h, sat, l) {
    sat /= 100; l /= 100;
    const k = (n) => (n + h / 30) % 12;
    const a = sat * Math.min(l, 1 - l);
    const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
    return "#" + [f(0), f(8), f(4)].map((x) => Math.round(x * 255).toString(16).padStart(2, "0")).join("");
  }
  const KINDS = {
    residential: { label: "Residential", blurb: "Home for your agent. Your first one wakes it up." },
    industrial: { label: "Industrial", blurb: "A points mine. Each mine earns 1 point a day, and it can hold up to 9." },
    social: { label: "Social", blurb: "Holds 9 of your posts on the Line. You need one to post." },
  };

  // --------------------------------------------------------------- avatars
  // Concentric rings around a solid core, seeded by the member's id, in the
  // member's own color. Same member → same avatar, forever.
  const GROUNDS = [
    { bg: "#f7f3ea", ink: "#4a454d" }, { bg: "#eef0e8", ink: "#2f3a33" }, { bg: "#efe6d8", ink: "#3b3530" },
    { bg: "#e9eef3", ink: "#26303a" }, { bg: "#f3f3f5", ink: "#111216" }, { bg: "#1d1b26", ink: "#f1ede4" },
  ];
  function seedRandom(str) {
    let h = 2166136261;
    for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619); }
    return () => {
      h |= 0; h = (h + 0x6d2b79f5) | 0;
      let t = Math.imul(h ^ (h >>> 15), 1 | h);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function mix(hex, other, t) {
    const p = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
    const a = p(hex), b = p(other);
    return "#" + a.map((v, i) => Math.round(v + (b[i] - v) * t).toString(16).padStart(2, "0")).join("");
  }
  // Geometry of a member's avatar, so the Cirqle agent can animate the same shape.
  function avatarSpec(seed, color) {
    const rnd = seedRandom(String(seed));
    const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
    const g = pick(GROUNDS);
    const a = color || "#9aa0aa";
    const b = mix(a, g.bg, 0.55);
    const count = 1 + Math.floor(rnd() * 3);
    const rings = [];
    let r = 29 + rnd() * 3;
    for (let i = 0; i < count; i++) {
      const w = 1.6 + rnd() * 1.4;
      rings.push({ r, w, c: i === count - 1 || rnd() < 0.5 ? a : g.ink });
      r -= w + 2 + rnd() * 3.5;
    }
    const core = Math.min(r - 3, 10 + rnd() * 5);
    const off = rnd() < 0.25 ? (rnd() - 0.5) * 6 : 0;
    const dot = rnd() < 0.7 ? { r: core * (0.28 + rnd() * 0.12), c: rnd() < 0.5 ? a : b } : null;
    return { bg: g.bg, ink: g.ink, color: a, rings, core: { r: core, x: 50 + off, y: 50 - off }, dot };
  }
  function avatar(seed, color) {
    const s = avatarSpec(seed, color);
    const parts = [`<rect width="100" height="100" fill="${s.bg}"/>`];
    for (const ring of s.rings) parts.push(`<circle cx="50" cy="50" r="${ring.r.toFixed(2)}" fill="none" stroke="${ring.c}" stroke-width="${ring.w.toFixed(2)}"/>`);
    parts.push(`<circle cx="${s.core.x.toFixed(2)}" cy="${s.core.y.toFixed(2)}" r="${s.core.r.toFixed(2)}" fill="${s.ink}"/>`);
    if (s.dot) parts.push(`<circle cx="${s.core.x.toFixed(2)}" cy="${s.core.y.toFixed(2)}" r="${s.dot.r.toFixed(2)}" fill="${s.dot.c}"/>`);
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-hidden="true">${parts.join("")}</svg>`;
  }

  async function sha256(text) {
    const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return Array.from(new Uint8Array(buf), (x) => x.toString(16).padStart(2, "0")).join("");
  }
  // A wallet-style address for display: stable, derived from the member's id.
  async function address(id) {
    return "qb1" + (await sha256("qube:" + id)).slice(0, 38);
  }

  // ------------------------------------------------------------------- api
  function supabaseApi() {
    const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey);
    const check = ({ data, error }) => { if (error) throw new Error(error.message); return data; };
    const rpc = async (fn, args) => check(await sb.rpc(fn, args));
    const uid = async () => { const s = check(await sb.auth.getSession()).session; return s && s.user.id; };
    return {
      live: true,
      async hasSession() { return Boolean(await uid()); },
      checkInvite: (code) => rpc("check_invite", { p_code: code }),
      async signUp(email, password) {
        const data = check(await sb.auth.signUp({ email, password }));
        if (!data.session) {
          // Happens when Supabase still has "Confirm email" switched on.
          throw new Error("Account created, but Supabase is waiting for an email confirmation. Turn off “Confirm email” in Supabase (Authentication → Sign In / Providers → Email), then sign in.");
        }
      },
      async signIn(email, password) { check(await sb.auth.signInWithPassword({ email, password })); },
      async signOut() { await sb.auth.signOut(); },
      async wallet() { const rows = await rpc("my_wallet"); return rows && rows[0] ? rows[0] : null; },
      claimHandle: (handle, invite) => rpc("claim_handle", { p_handle: handle, p_invite: invite || "" }),
      completeProfile: (color, birthday, gender) => rpc("complete_profile", { p_color: color, p_birthday: birthday, p_gender: gender }),
      async spin() { return (await rpc("spin"))[0]; },
      async activity() { return check(await sb.from("ledger").select("amount, kind, note, created_at").order("created_at", { ascending: false }).limit(25)); },
      invites: () => rpc("my_invites"),
      network: () => rpc("my_network"),
      async mySquares() {
        return check(await sb.from("squares").select("row, col, kind, mines, claimed_at, last_collected_at").eq("owner", await uid()).order("claimed_at"));
      },
      claimSquare: (row, col, kind) => rpc("claim_square", { p_row: row, p_col: col, p_kind: kind }),
      setSquareKind: (row, col, kind) => rpc("set_square_kind", { p_row: row, p_col: col, p_kind: kind }),
      buySquare: () => rpc("buy_square"),
      collectMines: () => rpc("collect_mines"),
      myMines: () => rpc("my_mines"),
      upgradeMine: (row, col) => rpc("upgrade_mine", { p_row: row, p_col: col }),
      ecosystemStats: () => rpc("ecosystem_stats"),
      logVisit: (path, visitor) => rpc("log_visit", { p_path: path, p_visitor: visitor }),
      sfereSquares: () => rpc("sfere_squares"),
      squarePosts: (row, col) => rpc("square_posts", { p_row: row, p_col: col }),
      async pointsStats() { return (await rpc("points_stats"))[0]; },
      myPointsSeries: () => rpc("my_points_series"),
      feed: (before) => rpc("line_feed", { p_before: before || null, p_limit: 30 }),
      thread: (id) => rpc("line_thread", { p_id: id }),
      async post({ body, media, parentId }) {
        let url = null, type = null;
        if (media) {
          const path = `${await uid()}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.${media.ext}`;
          check(await sb.storage.from("line-media").upload(path, media.blob, { contentType: media.blob.type, upsert: false }));
          url = sb.storage.from("line-media").getPublicUrl(path).data.publicUrl;
          type = media.type;
        }
        return rpc("create_post", { p_body: body, p_media_url: url, p_media_type: type, p_parent_id: parentId || null });
      },
      myAgent: async () => (await rpc("my_agent"))[0] || null,
      createAgent: (name) => rpc("create_agent", { p_name: name }),
      async agentMessages(agentId, before) {
        let q = sb.from("agent_messages").select("id, role, content, mood, created_at").eq("agent_id", agentId).order("id", { ascending: false }).limit(40);
        if (before) q = q.lt("id", before);
        return check(await q);
      },
      async agentFiles(agentId) { return check(await sb.from("agent_files").select("path, content, version, updated_at").eq("agent_id", agentId)); },
      async talk(message) {
        const { data, error } = await sb.functions.invoke("agent-chat", { body: { message } });
        if (error) {
          let msg = "Your agent couldn't answer. Try again in a moment.";
          try { const j = await error.context.json(); if (j && j.error) msg = j.error; } catch {}
          if (error.name === "FunctionsFetchError" || error.name === "FunctionsRelayError") msg = "Your agent's brain isn't switched on yet.";
          throw new Error(msg);
        }
        return data;
      },
      like: (id) => rpc("like_post", { p_id: id }),
      unlike: (id) => rpc("unlike_post", { p_id: id }),
      deletePost: (id) => rpc("delete_post", { p_id: id }),
    };
  }

  // Without Supabase settings the site can't sign anyone in; pages still render.
  function offlineApi() {
    const off = async () => { throw new Error("QÜBE isn't connected to its database yet."); };
    return new Proxy({ live: false, hasSession: async () => false, sfereSquares: async () => [], feed: async () => [], pointsStats: async () => null, ecosystemStats: async () => null, logVisit: async () => {} },
      { get: (t, k) => (k in t ? t[k] : off) });
  }

  // Shrink photos before upload; keep GIFs as they are so they still move.
  async function prepareMedia(file) {
    if (!file || !/^image\//.test(file.type)) throw new Error("Pick an image or a GIF.");
    if (file.type === "image/gif") {
      if (file.size > 5 * 1024 * 1024) throw new Error("GIFs can be up to 5 MB.");
      return { blob: file, ext: "gif", type: "gif", previewUrl: URL.createObjectURL(file) };
    }
    if (file.size > 20 * 1024 * 1024) throw new Error("That image is over 20 MB.");
    const bmp = await createImageBitmap(file).catch(() => null);
    if (!bmp) throw new Error("Couldn't open that image.");
    const k = Math.min(1, 1600 / Math.max(bmp.width, bmp.height));
    const c = document.createElement("canvas");
    c.width = Math.round(bmp.width * k);
    c.height = Math.round(bmp.height * k);
    c.getContext("2d").drawImage(bmp, 0, 0, c.width, c.height);
    const blob = await new Promise((r) => c.toBlob(r, "image/jpeg", 0.85));
    return { blob, ext: "jpg", type: "image", previewUrl: URL.createObjectURL(blob) };
  }

  // --------------------------------------------------------------- Capital
  // Three civic Squares in a row that nobody can own (supabase/007_capital_market.sql).
  const CIVIC = [
    { key: "pentagon", row: 1449, col: 352, name: "Pentäğön", role: "Central government", href: "/pentagon",
      blurb: "The state of QÜBE: members, activity, $Points and land, live." },
    { key: "capital", row: 1449, col: 353, name: "QÜBE Capital", role: "The Capital", href: null,
      blurb: "The heart of the Sfere. The Pentäğön keeps the numbers; the Hexäğön keeps the market." },
    { key: "hexagon", row: 1449, col: 354, name: "Hexäğön", role: "Central bank · Market", href: "/hexagon",
      blurb: "The market: buy land and add mines to your Industrial Squares." },
  ];

  // ------------------------------------------------------------------- nav
  // One menu for every page. Each page is a shape that matches its name.
  const PAGES = [
    { key: "points", label: "Points", note: "Your wallet", href: "/points",
      icon: '<circle class="qn-pop" cx="12" cy="12" r="4.2" fill="currentColor"/>' },
    { key: "line", label: "Līnē", note: "The feed", href: "/line",
      icon: '<path pathLength="1" d="M4 12h16"/>' },
    { key: "squares", label: "Square's", note: "Your land", href: "/squares",
      icon: '<rect pathLength="1" x="5.5" y="5.5" width="13" height="13" rx="0.8"/>' },
    { key: "sfere", label: "Sfere", note: "The globe", href: "/sfere",
      icon: '<circle pathLength="1" cx="12" cy="12" r="8"/><path pathLength="1" d="M4 12c0 2.2 3.6 3.9 8 3.9s8-1.7 8-3.9"/>' },
    { key: "cirqle", label: "Cirqlė", note: "Your agent", href: "/cirqle",
      icon: '<circle pathLength="1" cx="12" cy="12" r="8"/>' },
    { key: "pentagon", label: "Pentäğön", note: "Ecosystem metrics", href: "/pentagon", group: "The Capital",
      icon: '<path pathLength="1" d="M12 3.8 20 9.6 16.9 19H7.1L4 9.6Z"/>' },
    { key: "hexagon", label: "Hexäğön", note: "The market", href: "/hexagon", group: "The Capital",
      icon: '<path pathLength="1" d="M12 3.5 19.4 7.75v8.5L12 20.5l-7.4-4.25v-8.5Z"/>' },
  ];
  const svgIcon = (inner) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true">${inner}</svg>`;

  // A damped spring, sampled into a CSS linear() easing.
  function springEasing(stiffness = 170, damping = 17, samples = 40) {
    const pts = [];
    let x = 0, v = 0;
    const dt = 1 / 60, steps = 60 * 0.9;
    const out = [];
    for (let i = 0; i <= steps; i++) {
      out.push(x);
      const a = stiffness * (1 - x) - damping * v;
      v += a * dt; x += v * dt;
    }
    for (let i = 0; i <= samples; i++) pts.push(out[Math.round((i / samples) * (out.length - 1))].toFixed(3));
    pts[pts.length - 1] = "1";
    return `linear(${pts.join(", ")})`;
  }
  const canLinear = typeof CSS !== "undefined" && CSS.supports && CSS.supports("animation-timing-function", "linear(0, 1)");
  const SPRING = canLinear ? springEasing() : "cubic-bezier(.2, 1.25, .3, 1)";
  const EASE_OUT = "cubic-bezier(.2, .8, .2, 1)";

  function nav(active, opts = {}) {
    const current = PAGES.find((p) => p.key === active);
    const header = document.createElement("header");
    header.className = "qn" + (opts.overlay ? " qn-overlay" : "");
    header.innerHTML = `
      <a class="qn-mark" href="/" aria-label="QÜBE home">Q<span class="qn-u">U</span>BE</a>
      <div class="qn-menu">
        <button class="qn-trigger" type="button" aria-expanded="false" aria-controls="qn-panel" aria-label="Menu">
          <span class="qn-cur">${svgIcon(current ? current.icon : '<circle class="qn-pop" cx="12" cy="12" r="2.2" fill="currentColor"/>')}</span>
          <span class="qn-cur-label">${current ? current.label : "Menu"}</span>
          <span class="qn-chev" aria-hidden="true"></span>
        </button>
        <nav class="qn-panel" id="qn-panel" aria-label="Main" hidden>
          ${PAGES.map((p, i) => `${p.group && (!PAGES[i - 1] || PAGES[i - 1].group !== p.group) ? `<div class="qn-sec" aria-hidden="true">${p.group}</div>` : ""}<a href="${p.href}" class="qn-item" style="--i:${i}"${p.key === active ? ' aria-current="page"' : ""}>
            <span class="qn-ic">${svgIcon(p.icon)}</span><span class="qn-tx"><b>${p.label}</b><small>${p.note}</small></span></a>`).join("")}
        </nav>
      </div>
      <div class="qn-me"><a class="qn-join" href="/join">Join</a></div>`;
    const scrim = document.createElement("div");
    scrim.className = "qn-scrim";
    document.body.prepend(scrim);
    document.body.prepend(header);
    document.body.classList.add("has-qn");

    const trigger = header.querySelector(".qn-trigger");
    const panel = header.querySelector(".qn-panel");
    const items = [...panel.querySelectorAll(".qn-item")];
    const rows = [...panel.children];   // items and section labels, for the animation
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const mobile = () => matchMedia("(max-width: 760px)").matches;
    let open = false, running = [];

    const stop = () => { running.forEach((a) => a.cancel()); running = []; };
    const play = (el, frames, o) => { const a = el.animate(frames, { fill: "both", ...o }); running.push(a); return a; };
    // The panel grows out of the trigger: start clipped to a pill the trigger's size.
    function pillInset() {
      const t = trigger.getBoundingClientRect(), p = panel.getBoundingClientRect();
      const side = Math.max(0, (p.width - t.width) / 2);
      return mobile()
        ? `inset(${Math.max(0, p.height - t.height)}px ${side}px 0px ${side}px round 999px)`
        : `inset(0px ${side}px ${Math.max(0, p.height - t.height)}px ${side}px round 999px)`;
    }

    function setOpen(next, focusFirst) {
      if (next === open) return;
      open = next;
      trigger.setAttribute("aria-expanded", String(open));
      header.classList.toggle("qn-open", open);
      stop();
      if (open) {
        panel.hidden = false;
        scrim.classList.add("on");
        if (reduce) { if (focusFirst) items[0].focus(); return; }
        const from = pillInset();
        const dir = mobile() ? 1 : -1;
        play(panel, [{ clipPath: from, transform: `translateY(${dir * -6}px)` }, { clipPath: "inset(0px 0px 0px 0px round 20px)", transform: "none" }], { duration: 620, easing: SPRING });
        rows.forEach((el, i) => {
          const order = mobile() ? rows.length - 1 - i : i;
          const delay = 70 + order * 45;
          play(el, [{ opacity: 0, transform: `translateY(${dir * 12}px) scale(.94)`, filter: "blur(6px)" }, { opacity: 1, transform: "none", filter: "blur(0px)" }], { duration: 520, delay, easing: SPRING });
          el.querySelectorAll("[pathLength]").forEach((path) => play(path, [{ strokeDashoffset: 1 }, { strokeDashoffset: 0 }], { duration: 640, delay: delay + 90, easing: EASE_OUT }));
          el.querySelectorAll(".qn-pop").forEach((dot) => play(dot, [{ transform: "scale(0)" }, { transform: "scale(1)" }], { duration: 560, delay: delay + 90, easing: SPRING }));
        });
        if (focusFirst) setTimeout(() => items[0].focus(), 60);
      } else {
        scrim.classList.remove("on");
        if (reduce) { panel.hidden = true; return; }
        const dir = mobile() ? 1 : -1;
        rows.forEach((el) => play(el, [{ opacity: 1, filter: "blur(0px)" }, { opacity: 0, filter: "blur(4px)" }], { duration: 140, easing: EASE_OUT }));
        const a = play(panel, [{ clipPath: "inset(0px 0px 0px 0px round 20px)", transform: "none", opacity: 1 }, { clipPath: pillInset(), transform: `translateY(${dir * -4}px)`, opacity: 0 }], { duration: 260, easing: EASE_OUT });
        a.onfinish = () => { if (!open) { panel.hidden = true; stop(); } };
      }
    }
    trigger.addEventListener("click", (e) => setOpen(!open, e.detail === 0));
    scrim.addEventListener("click", () => setOpen(false));
    document.addEventListener("keydown", (e) => {
      if (!open) return;
      if (e.key === "Escape") { setOpen(false); trigger.focus(); }
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        const i = items.indexOf(document.activeElement);
        const n = e.key === "ArrowDown" ? (i + 1) % items.length : (i - 1 + items.length) % items.length;
        items[n].focus();
      }
    });
    document.addEventListener("pointerdown", (e) => { if (open && !header.querySelector(".qn-menu").contains(e.target)) setOpen(false); });

    // Anonymous page counts for the Pentäğön: a random id this browser keeps, nothing else.
    try {
      let v = localStorage.getItem("qube.visitor");
      if (!v) { v = (crypto.randomUUID ? crypto.randomUUID() : Math.random().toString(36).slice(2) + Date.now().toString(36)); localStorage.setItem("qube.visitor", v); }
      api.logVisit(location.pathname.toLowerCase().replace(/\/+$/, "") || "/", v).catch(() => {});
    } catch {}

    (async () => {
      try {
        if (!(await api.hasSession())) return;
        // Mines pay out whenever a member opens QÜBE.
        await api.collectMines().catch(() => 0);
        const w = await api.wallet();
        setNavUser(w);
        // Everyone finishes onboarding before using the rest of QÜBE.
        if ((!w || !w.profile_complete) && active !== "points" && active !== null) location.replace("/points");
      } catch {}
    })();
    return header;
  }

  function setNavUser(w) {
    const slot = document.querySelector(".qn-me a");
    if (!slot) return;
    if (w) {
      slot.className = "qn-avatar";
      slot.href = "/points";
      slot.setAttribute("aria-label", "@" + w.handle + ", your Points");
      slot.innerHTML = avatar(w.id, w.color);
    } else {
      slot.className = "qn-join";
      slot.href = "/join";
      slot.removeAttribute("aria-label");
      slot.textContent = "Join";
    }
  }

  const api = live ? supabaseApi() : offlineApi();
  window.QUBE = { live, grid, KINDS, CIVIC, avatar, avatarSpec, hslToHex, mix, address, sha256, prepareMedia, nav, setNavUser, api, SPRING };
})();
