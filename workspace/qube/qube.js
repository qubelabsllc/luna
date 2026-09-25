// Shared by every QÜBE page: the Sfere grid, avatars, and the data layer.
// Load after config.js (and after supabase-js, where a page uses it).
(() => {
  const cfg = window.QUBE_CONFIG || {};
  const live = Boolean(cfg.supabaseUrl && cfg.supabaseAnonKey && window.supabase);

  // ------------------------------------------------------------------ grid
  // Must match sfere_rows() / sfere_cols() in supabase/002_sfere_invites.sql.
  // 1,243 bands of latitude, 10 miles tall; each band cut into ~10-mile Squares.
  const ROWS = 1243;
  const EQUATOR_MI = 24901;
  const DLAT = 180 / ROWS;
  const colsCache = new Int32Array(ROWS);
  for (let r = 0; r < ROWS; r++) {
    const lat = -90 + (r + 0.5) * DLAT;
    colsCache[r] = Math.max(1, Math.round((EQUATOR_MI * Math.cos((lat * Math.PI) / 180)) / 10));
  }
  const grid = {
    ROWS,
    DLAT,
    TOTAL: colsCache.reduce((a, b) => a + b, 0),
    cols: (r) => colsCache[r],
    cellAt(lat, lon) {
      const row = Math.min(ROWS - 1, Math.max(0, Math.floor((lat + 90) / DLAT)));
      const n = colsCache[row];
      const col = Math.min(n - 1, Math.max(0, Math.floor((((lon + 180) % 360) + 360) % 360 / (360 / n))));
      return { row, col };
    },
    bounds(row, col) {
      const n = colsCache[row], w = 360 / n;
      return { lat0: -90 + row * DLAT, lat1: -90 + (row + 1) * DLAT, lon0: -180 + col * w, lon1: -180 + (col + 1) * w };
    },
    center(row, col) {
      const b = grid.bounds(row, col);
      return { lat: (b.lat0 + b.lat1) / 2, lon: (b.lon0 + b.lon1) / 2 };
    },
    label: (row, col) => `SQ ${String(row).padStart(4, "0")}·${String(col).padStart(4, "0")}`,
    coords(row, col) {
      const { lat, lon } = grid.center(row, col);
      return `${Math.abs(lat).toFixed(2)}°${lat >= 0 ? "N" : "S"} ${Math.abs(lon).toFixed(2)}°${lon >= 0 ? "E" : "W"}`;
    },
    hash: (row, col) => `${row}.${col}`,
    parseHash(h) {
      const m = /^#?(\d{1,4})\.(\d{1,4})$/.exec(h || "");
      if (!m) return null;
      const row = +m[1], col = +m[2];
      return row < ROWS && col < colsCache[row] ? { row, col } : null;
    },
  };

  // --------------------------------------------------------------- avatars
  // Concentric rings around a solid core, from a seed (the user's id).
  // Same seed → same avatar, forever.
  const PALETTES = [
    { bg: "#f7f3ea", ink: "#4a454d", a: "#e0584a", b: "#ff6a6a" },
    { bg: "#e0584a", ink: "#4a454d", a: "#f7f3ea", b: "#ffb4a8" },
    { bg: "#eceefe", ink: "#111216", a: "#3a3df5", b: "#9fa2ff" },
    { bg: "#3a3df5", ink: "#111216", a: "#f4f4ff", b: "#ffcf5a" },
    { bg: "#eef0e8", ink: "#2f3a33", a: "#6f8f5e", b: "#d9a441" },
    { bg: "#1d1b26", ink: "#f1ede4", a: "#e0584a", b: "#8f8cff" },
    { bg: "#efe6d8", ink: "#3b3530", a: "#c7773f", b: "#5f7fa8" },
    { bg: "#e9eef3", ink: "#26303a", a: "#4b7bd1", b: "#f07a5f" },
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
  function avatar(seed) {
    const rnd = seedRandom(String(seed));
    const pick = (arr) => arr[Math.floor(rnd() * arr.length)];
    const p = pick(PALETTES);
    const rings = 1 + Math.floor(rnd() * 3);
    const parts = [`<rect width="100" height="100" fill="${p.bg}"/>`];
    let r = 29 + rnd() * 3;
    for (let i = 0; i < rings; i++) {
      const w = 1.6 + rnd() * 1.4;
      const color = i === rings - 1 && rnd() < 0.7 ? p.a : pick([p.ink, p.ink, p.a]);
      parts.push(`<circle cx="50" cy="50" r="${r.toFixed(2)}" fill="none" stroke="${color}" stroke-width="${w.toFixed(2)}"/>`);
      r -= w + 2 + rnd() * 3.5;
    }
    const core = Math.min(r - 3, 10 + rnd() * 5);
    const off = rnd() < 0.25 ? (rnd() - 0.5) * 6 : 0;
    parts.push(`<circle cx="${(50 + off).toFixed(2)}" cy="${(50 - off).toFixed(2)}" r="${core.toFixed(2)}" fill="${p.ink}"/>`);
    if (rnd() < 0.6) parts.push(`<circle cx="${(50 + off).toFixed(2)}" cy="${(50 - off).toFixed(2)}" r="${(core * (0.25 + rnd() * 0.12)).toFixed(2)}" fill="${p.b}"/>`);
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" role="img" aria-hidden="true">${parts.join("")}</svg>`;
  }

  async function sha256(text) {
    const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return Array.from(new Uint8Array(buf), (x) => x.toString(16).padStart(2, "0")).join("");
  }
  // A wallet-style address for display: stable, derived from the user id.
  async function address(id) {
    const h = await sha256("qube:" + id);
    return "qb1" + h.slice(0, 38);
  }

  // ------------------------------------------------------------------- api
  // One interface, two backends: Supabase when configured, otherwise a
  // single invite-only preview account kept in this browser.
  const PRIZES = [[5, 350], [10, 250], [25, 180], [50, 120], [100, 70], [250, 25], [1000, 5]];

  function supabaseApi() {
    const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey);
    const check = ({ data, error }) => { if (error) throw new Error(error.message); return data; };
    return {
      live: true,
      async hasSession() { return Boolean(check(await sb.auth.getSession()).session); },
      async checkInvite(code) { return check(await sb.rpc("check_invite", { p_code: code })); },
      async sendCode(email) { check(await sb.auth.signInWithOtp({ email, options: { shouldCreateUser: true, emailRedirectTo: location.origin + "/wallet" } })); },
      async verify(email, token) { check(await sb.auth.verifyOtp({ email, token, type: "email" })); },
      async wallet() { const rows = check(await sb.rpc("my_wallet")); return rows && rows[0] ? rows[0] : null; },
      async claimHandle(handle, invite) { check(await sb.rpc("claim_handle", { p_handle: handle, p_invite: invite || "" })); },
      async spin() { return check(await sb.rpc("spin"))[0]; },
      async activity() { return check(await sb.from("ledger").select("amount, kind, note, created_at").order("created_at", { ascending: false }).limit(25)); },
      async invites() { return check(await sb.rpc("my_invites")); },
      async network() { return check(await sb.rpc("my_network")); },
      async mySquares() {
        const { data: s } = await sb.auth.getSession();
        const uid = s.session && s.session.user.id;
        return check(await sb.from("squares").select('"row", col, claimed_at').eq("owner", uid).order("claimed_at"));
      },
      async claimSquare(row, col) { return check(await sb.rpc("claim_square", { p_row: row, p_col: col })); },
      async sfereSquares() { return check(await sb.rpc("sfere_squares")); },
      async signOut() { await sb.auth.signOut(); },
    };
  }

  function previewApi() {
    const invite = cfg.preview || {};
    const KEY = "qube-preview-wallet";
    const load = () => { try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch { return {}; } };
    const save = () => { try { localStorage.setItem(KEY, JSON.stringify(s)); } catch {} };
    let s = load();
    const today = () => new Date().toISOString().slice(0, 10);
    const tomorrow = () => { const d = new Date(); d.setUTCHours(24, 0, 0, 0); return d.toISOString(); };
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));
    const refresh = () => { s = load(); };
    const ensure = () => {
      s.id = s.id || (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2));
      s.ledger = s.ledger || [];
      s.squares = s.squares || [];
      if (!s.invites) {
        s.invites = Array.from({ length: 10 }, () => Math.random().toString(16).slice(2, 10).toUpperCase().padEnd(8, "0"));
      }
    };
    const balance = () => s.ledger.reduce((a, r) => a + r.amount, 0);
    return {
      live: false,
      async hasSession() { refresh(); return Boolean(s.email && s.handle); },
      async checkInvite() { return false; },
      async sendCode(email) {
        await wait(400);
        if ((await sha256(email.trim().toLowerCase())) !== invite.emailSha256) {
          throw new Error("QÜBE is invite-only for now. Public signups open soon.");
        }
      },
      async verify(email, token) {
        await wait(300);
        if ((await sha256(token)) !== invite.codeSha256) throw new Error("That code isn't right.");
        refresh();
        s.email = email;
        if (!s.handle) { s.handle = invite.handle; s.joined = new Date().toISOString(); }
        ensure();
        save();
      },
      async wallet() {
        refresh();
        if (!s.handle) return null;
        ensure(); save();
        return {
          id: s.id, handle: s.handle, balance: balance(), joined_at: s.joined,
          spun_today: s.spinDay === today() ? s.spinAmount : null, next_spin_at: tomorrow(),
          squares_owned: s.squares.length, squares_available: 1 - s.squares.length, invited_by_handle: null,
        };
      },
      async claimHandle() { throw new Error("Your account is already set up."); },
      async spin() {
        await wait(300);
        refresh();
        if (s.spinDay === today()) throw new Error("You already spun today");
        const total = PRIZES.reduce((a, p) => a + p[1], 0);
        let roll = Math.floor(Math.random() * total), amount = 5;
        for (const [a, w] of PRIZES) { if (roll < w) { amount = a; break; } roll -= w; }
        s.spinDay = today(); s.spinAmount = amount;
        s.ledger.unshift({ amount, kind: "spin", note: "Daily spin", created_at: new Date().toISOString() });
        save();
        return { amount, balance: balance() };
      },
      async activity() { refresh(); return s.ledger || []; },
      async invites() { refresh(); ensure(); save(); return s.invites.map((code) => ({ code, used_by_handle: null, used_at: null })); },
      async network() { return [1, 2, 3].map((level) => ({ level, people: 0, earned_points: 0, earned_squares: 0 })); },
      async mySquares() { refresh(); return (s.squares || []).map((q) => ({ row: q.row, col: q.col, claimed_at: q.claimed_at })); },
      async claimSquare(row, col) {
        await wait(300);
        refresh(); ensure();
        if (!s.handle || !s.email) throw new Error("Sign in to claim a Square.");
        if (s.squares.length >= 1) throw new Error("You have no Squares left to place. Invite someone to earn one.");
        if (row < 0 || row >= ROWS || col < 0 || col >= colsCache[row]) throw new Error("That Square is off the grid");
        s.squares.push({ row, col, claimed_at: new Date().toISOString() });
        save();
        return { row, col };
      },
      async sfereSquares() { refresh(); return (s.squares || []).map((q) => ({ row: q.row, col: q.col, handle: s.handle, claimed_at: q.claimed_at })); },
      async signOut() { refresh(); delete s.email; save(); },
    };
  }

  window.QUBE = { live, grid, avatar, address, sha256, api: live ? supabaseApi() : previewApi() };
})();
