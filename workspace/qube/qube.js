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
  // A member's color is chosen once, at onboarding, and never changes.
  // Must match qube_colors() in the database.
  const COLORS = [
    ["#3a3df5", "Ultramarine"], ["#e0584a", "Coral"], ["#f08a24", "Tangerine"], ["#e8b817", "Sun"],
    ["#7cb518", "Lime"], ["#12a150", "Emerald"], ["#0fa3a3", "Teal"], ["#2d9cdb", "Sky"],
    ["#7b4ae2", "Violet"], ["#d63384", "Magenta"], ["#f06595", "Rose"], ["#3d3f46", "Graphite"],
  ];
  const KINDS = {
    residential: { label: "Residential", blurb: "Where your agent will live. Decorating comes later." },
    industrial: { label: "Industrial", blurb: "A points mine. Earns 1 point every day, forever." },
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
  function avatar(seed, color) {
    const rnd = seedRandom(String(seed));
    const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
    const g = pick(GROUNDS);
    const a = color || "#9aa0aa";
    const b = mix(a, g.bg, 0.55);
    const rings = 1 + Math.floor(rnd() * 3);
    const parts = [`<rect width="100" height="100" fill="${g.bg}"/>`];
    let r = 29 + rnd() * 3;
    for (let i = 0; i < rings; i++) {
      const w = 1.6 + rnd() * 1.4;
      const c = i === rings - 1 || rnd() < 0.5 ? a : g.ink;
      parts.push(`<circle cx="50" cy="50" r="${r.toFixed(2)}" fill="none" stroke="${c}" stroke-width="${w.toFixed(2)}"/>`);
      r -= w + 2 + rnd() * 3.5;
    }
    const core = Math.min(r - 3, 10 + rnd() * 5);
    const off = rnd() < 0.25 ? (rnd() - 0.5) * 6 : 0;
    const cx = (50 + off).toFixed(2), cy = (50 - off).toFixed(2);
    parts.push(`<circle cx="${cx}" cy="${cy}" r="${core.toFixed(2)}" fill="${g.ink}"/>`);
    if (rnd() < 0.7) parts.push(`<circle cx="${cx}" cy="${cy}" r="${(core * (0.28 + rnd() * 0.12)).toFixed(2)}" fill="${rnd() < 0.5 ? a : b}"/>`);
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
        return check(await sb.from("squares").select("row, col, kind, claimed_at, last_collected_at").eq("owner", await uid()).order("claimed_at"));
      },
      claimSquare: (row, col, kind) => rpc("claim_square", { p_row: row, p_col: col, p_kind: kind }),
      setSquareKind: (row, col, kind) => rpc("set_square_kind", { p_row: row, p_col: col, p_kind: kind }),
      buySquare: () => rpc("buy_square"),
      collectMines: () => rpc("collect_mines"),
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
      like: (id) => rpc("like_post", { p_id: id }),
      unlike: (id) => rpc("unlike_post", { p_id: id }),
      deletePost: (id) => rpc("delete_post", { p_id: id }),
    };
  }

  // Without Supabase settings the site can't sign anyone in; pages still render.
  function offlineApi() {
    const off = async () => { throw new Error("QÜBE isn't connected to its database yet."); };
    return new Proxy({ live: false, hasSession: async () => false, sfereSquares: async () => [], feed: async () => [], pointsStats: async () => null },
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

  // ------------------------------------------------------------------- nav
  // One nav for every page: a top bar on desktop, a bottom tab bar on phones.
  const ICONS = {
    points: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="3" fill="currentColor" stroke="none"/></svg>',
    line: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M4 6.5h16M4 12h16M4 17.5h9.5"/></svg>',
    squares: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="4" y="4" width="7" height="7" rx="0.5"/><rect x="13" y="4" width="7" height="7" rx="0.5"/><rect x="4" y="13" width="7" height="7" rx="0.5"/><rect x="13" y="13" width="7" height="7" rx="0.5" fill="currentColor"/></svg>',
    sfere: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="12" cy="12" r="8.5"/><ellipse cx="12" cy="12" rx="3.6" ry="8.5"/><path d="M3.5 12h17"/></svg>',
  };
  const TABS = [["points", "Points", "/points"], ["line", "Line", "/line"], ["squares", "Squares", "/squares"], ["sfere", "Sfere", "/sfere"]];

  function nav(active, opts = {}) {
    const header = document.createElement("header");
    header.className = "qn" + (opts.overlay ? " qn-overlay" : "");
    header.innerHTML = `
      <a class="qn-mark" href="/" aria-label="QÜBE home">Q<span class="qn-u">U</span>BE</a>
      <nav class="qn-tabs" aria-label="Main">
        ${TABS.map(([key, label, href]) => `<a href="${href}" class="qn-tab"${key === active ? ' aria-current="page"' : ""}>${ICONS[key]}<span>${label}</span></a>`).join("")}
      </nav>
      <div class="qn-me"><a class="qn-join" href="/join">Join</a></div>`;
    document.body.prepend(header);
    document.body.classList.add("has-qn");
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
  window.QUBE = { live, grid, COLORS, KINDS, avatar, mix, address, sha256, prepareMedia, nav, setNavUser, api };
})();
