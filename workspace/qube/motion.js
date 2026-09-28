// QÜBE motion: the film on the landing page, drawn live on a canvas.
// A point becomes a line, a square, a cube, the Sfere and an agent; then the eight
// shapes line up and gather into the wordmark. 1920 × 1080 drawing space, 19.5 s.
//
//   const film = QubeMotion.mount(canvas);   film.play(), film.pause(), film.seek(t)
(() => {
  function mount(cv, { onState } = {}) {

    // ------------------------------------------------------------------ setup
    const W = 1920, H = 1080, CX = W / 2, CY = H / 2 - 10;
    const ctx = cv.getContext("2d");
    // The film is drawn in a 1920 × 1080 space and scaled to the canvas's real pixels.
    // Small screens get thicker lines and skip the small type (compact).
    let K = 1, LW = 1, compact = false;
    const INK = "#111216", MUTED = "#6b6f78", LINE = "#e4e6ea", ACCENT = "#3a3df5", SOFT = "#e9eafe";
    const DUR = 19.5;

    const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
    const lerp = (a, b, t) => a + (b - a) * t;
    const seg = (t, a, b) => clamp((t - a) / (b - a));          // 0→1 across [a, b]
    const ease = (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
    const easeOut = (x) => 1 - Math.pow(1 - x, 3);
    const easeIn = (x) => x * x * x;
    // A damped spring, 0 → 1 with a little overshoot.
    const spring = (x) => (x <= 0 ? 0 : x >= 1 ? 1 : 1 - Math.exp(-6 * x) * Math.cos(10 * x));
    const smooth = (a, b, x) => { const t = clamp((x - a) / (b - a)); return t * t * (3 - 2 * t); };
    const rgba = (hex, a) => { const n = parseInt(hex.slice(1), 16); return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`; };

    // ------------------------------------------------------------------ 3D
    const U = 210, D = 7;
    let yaw = 0, pitch = 0;
    function rot([x, y, z]) {
      const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
      const x1 = x * cy + z * sy, z1 = -x * sy + z * cy;
      const y2 = y * cp - z1 * sp, z2 = y * sp + z1 * cp;
      return [x1, y2, z2];
    }
    function proj(p) {
      const [x, y, z] = rot(p), s = D / (D - z);
      return [CX + x * s * U, CY - y * s * U, z];
    }
    const norm = (v) => { const l = Math.hypot(v[0], v[1], v[2]) || 1; return [v[0] / l, v[1] / l, v[2] / l]; };

    // The cube-sphere: six faces, each a grid on [-1, 1]². A point is pushed from the
    // cube toward the sphere by `inflate`; `depth` squashes the cube from a flat square.
    const FACES = [
      { n: [0, 0, 1], r: [1, 0, 0], t: [0, 1, 0] },
      { n: [0, 0, -1], r: [-1, 0, 0], t: [0, 1, 0] },
      { n: [1, 0, 0], r: [0, 0, -1], t: [0, 1, 0] },
      { n: [-1, 0, 0], r: [0, 0, 1], t: [0, 1, 0] },
      { n: [0, 1, 0], r: [1, 0, 0], t: [0, 0, -1] },
      { n: [0, -1, 0], r: [1, 0, 0], t: [0, 0, 1] },
    ];
    const R = 1.32, GRID = 24;
    function surface(F, a, b, depth, inflate) {
      const c = [F.n[0] + a * F.r[0] + b * F.t[0], F.n[1] + a * F.r[1] + b * F.t[1], F.n[2] + a * F.r[2] + b * F.t[2]];
      const s = norm(c);
      let p = [lerp(c[0], s[0] * R, inflate), lerp(c[1], s[1] * R, inflate), lerp(c[2], s[2] * R, inflate)];
      p[2] = 1 - (1 - p[2]) * depth;   // extrusion from the front face
      const nrm = norm([lerp(F.n[0], s[0], inflate), lerp(F.n[1], s[1], inflate), lerp(F.n[2], s[2], inflate)]);
      return { p, nrm };
    }
    // Which grid lines show: every 8th from the start (a 3 × 3 cube), then finer as it inflates.
    function lineWeight(k, fine) {
      if (k % 24 === 0) return { w: 1, edge: true };
      if (k % 8 === 0) return { w: 1, edge: false };
      if (k % 4 === 0) return { w: smooth(0, 0.6, fine), edge: false };
      if (k % 2 === 0) return { w: smooth(0.4, 1, fine), edge: false };
      return { w: 0, edge: false };
    }
    function drawGlobe({ depth, inflate, gridA, fine, fade = 1, backA = 0.1 }) {
      ctx.lineCap = "round";
      const STEPS = 40;
      for (const F of FACES) {
        // While the cube is still nearly flat, only the front face shows: the rest lie on top of it.
        const faceA = F.n[2] === 1 ? 1 : smooth(0.02, 0.2, depth);
        if (faceA <= 0) continue;
        for (let dir = 0; dir < 2; dir++) {
          for (let k = 0; k <= GRID; k++) {
            const { w, edge } = lineWeight(k, fine);
            const alpha = (edge ? 1 : w * gridA) * fade * faceA;
            if (alpha < 0.01) continue;
            const u = (k / GRID) * 2 - 1;
            let prev = null;
            for (let i = 0; i <= STEPS; i++) {
              const v = (i / STEPS) * 2 - 1;
              const { p, nrm } = dir ? surface(F, u, v, depth, inflate) : surface(F, v, u, depth, inflate);
              const sp = proj(p), nz = rot(nrm)[2];
              if (prev) {
                const face = smooth(-0.12, 0.12, (nz + prev.nz) / 2);
                const a = alpha * lerp(backA, 1, face) * (edge ? 1 : 0.55);
                ctx.strokeStyle = rgba(INK, a);
                ctx.lineWidth = (edge ? 3 : 1.6) * LW;
                ctx.beginPath(); ctx.moveTo(prev.x, prev.y); ctx.lineTo(sp[0], sp[1]); ctx.stroke();
              }
              prev = { x: sp[0], y: sp[1], nz };
            }
          }
        }
      }
    }

    // ------------------------------------------------------------------ 2D helpers
    function partialPath(pts, p, close) {
      const all = close ? [...pts, pts[0]] : pts;
      let total = 0; const lens = [];
      for (let i = 1; i < all.length; i++) { const l = Math.hypot(all[i][0] - all[i - 1][0], all[i][1] - all[i - 1][1]); lens.push(l); total += l; }
      let left = total * clamp(p);
      ctx.beginPath(); ctx.moveTo(all[0][0], all[0][1]);
      for (let i = 1; i < all.length && left > 0; i++) {
        const l = lens[i - 1], f = Math.min(1, left / l);
        ctx.lineTo(lerp(all[i - 1][0], all[i][0], f), lerp(all[i - 1][1], all[i][1], f));
        left -= l;
      }
      ctx.stroke();
    }
    const polygon = (n, r, x, y, rot0 = -Math.PI / 2) => Array.from({ length: n }, (_, i) => [x + r * Math.cos(rot0 + (i / n) * 2 * Math.PI), y + r * Math.sin(rot0 + (i / n) * 2 * Math.PI)]);

    // The eight shapes, drawn small in the lineup. p: 0 → 1 draws the shape in.
    const SHAPES = [
      { label: "$Points", draw: (x, y, s, p) => { ctx.fillStyle = INK; ctx.beginPath(); ctx.arc(x, y, 11 * s * spring(p), 0, 7); ctx.fill(); } },
      { label: "Līnē", draw: (x, y, s, p) => partialPath([[x - 46 * s, y], [x + 46 * s, y]], easeOut(p)) },
      { label: "Square's", draw: (x, y, s, p) => partialPath([[x - 38 * s, y + 38 * s], [x - 38 * s, y - 38 * s], [x + 38 * s, y - 38 * s], [x + 38 * s, y + 38 * s]], easeOut(p), true) },
      { label: "QÜBE", draw: (x, y, s, p) => {
        const h = polygon(6, 46 * s, x, y);
        partialPath(h, easeOut(p), true);
        const q = easeOut(seg(p, 0.35, 1));
        partialPath([[x, y], h[0]], q); partialPath([[x, y], h[2]], q); partialPath([[x, y], h[4]], q);
      } },
      { label: "Sfere", draw: (x, y, s, p) => {
        const q = easeOut(p);
        ctx.beginPath(); ctx.arc(x, y, 44 * s, -Math.PI / 2, -Math.PI / 2 + q * 2 * Math.PI); ctx.stroke();
        const e = easeOut(seg(p, 0.4, 1));
        ctx.beginPath(); ctx.ellipse(x, y, 44 * s, 14 * s, 0, Math.PI - e * Math.PI, Math.PI); ctx.stroke();
      } },
      { label: "Cirqlė", draw: (x, y, s, p) => { drawAgent(x, y, 44 * s, p, 0, 1); } },
      { label: "Pentäğön", draw: (x, y, s, p) => partialPath(polygon(5, 48 * s, x, y + 3 * s), easeOut(p), true) },
      { label: "Hexäğön", draw: (x, y, s, p) => partialPath(polygon(6, 46 * s, x, y, -Math.PI / 2), easeOut(p), true) },
    ];

    // Cirqlė: a round agent with eyes. blink: 0 open → 1 shut.
    function drawAgent(x, y, r, fillA, blink, eyesA, squash = 0) {
      ctx.save();
      ctx.translate(x, y + r * squash * 0.5);
      ctx.scale(1 + squash * 0.5, 1 - squash * 0.5);
      ctx.fillStyle = rgba(ACCENT, fillA);
      ctx.beginPath(); ctx.arc(0, 0, r, 0, 7); ctx.fill();
      ctx.strokeStyle = rgba(ACCENT, 1);
      ctx.lineWidth = (Math.max(2, r * 0.03)) * LW;
      ctx.beginPath(); ctx.arc(0, 0, r * 1.18, 0, 7); ctx.globalAlpha = 0.25 * fillA; ctx.stroke(); ctx.globalAlpha = 1;
      if (eyesA > 0) {
        ctx.fillStyle = rgba("#ffffff", eyesA);
        const ey = -r * 0.08, ex = r * 0.26, ew = r * 0.085, eh = r * 0.13 * (1 - blink * 0.9);
        for (const sx of [-1, 1]) { ctx.beginPath(); ctx.ellipse(sx * ex, ey, ew, Math.max(1.5, eh), 0, 0, 7); ctx.fill(); }
      }
      ctx.restore();
    }

    // ------------------------------------------------------------------ type
    function mono(text, x, y, a, align = "left", size = 17, color = MUTED) {
      if (a <= 0) return;
      ctx.font = `400 ${size}px "JetBrains Mono"`;
      ctx.letterSpacing = "0.14em";
      ctx.textAlign = align; ctx.textBaseline = "alphabetic";
      ctx.fillStyle = rgba(color, a);
      ctx.fillText(text.toUpperCase(), x, y);
      ctx.letterSpacing = "0px";
    }
    function display(text, x, y, size, weight, a, color = INK, align = "center", spacing = "0em") {
      if (a <= 0) return;
      ctx.font = `${weight} ${size}px "Unbounded"`;
      ctx.letterSpacing = spacing;
      ctx.textAlign = align; ctx.textBaseline = "alphabetic";
      ctx.fillStyle = rgba(color, a);
      ctx.fillText(text, x, y);
      ctx.letterSpacing = "0px";
    }

    // Scene captions, lower left: number, name, what it is.
    const CAPS = [
      [0.4, 1.6, "01", "$Points", "The currency"],
      [1.6, 3.0, "02", "Līnē", "The feed"],
      [3.0, 4.6, "03", "Square's", "Your land"],
      [4.6, 7.2, "04", "QÜBE", "The world"],
      [7.2, 9.8, "05", "Sfere", "A cube, inflated into a globe"],
      [9.8, 12.2, "06", "Cirqlė", "Your agent"],
      [12.2, 15.2, "07", "Eight shapes", "One world, and its Capital"],
    ];
    function captions(t) {
      for (const [a, b, n, name, what] of CAPS) {
        const inA = smooth(a, a + 0.35, t), outA = 1 - smooth(b - 0.3, b, t);
        const al = Math.min(inA, outA);
        if (al <= 0) continue;
        const rise = (1 - easeOut(inA)) * 12;
        mono(`${n} / 07`, 120, 942 + rise, al);
        display(name, 120, 990 + rise, 34, 300, al, INK, "left");
        mono(what, 120 + measure(name) + 22, 990 + rise, al * 0.9, "left", 17, MUTED);
      }
    }
    function measure(name) { ctx.font = `300 34px "Unbounded"`; return ctx.measureText(name).width; }

    // ------------------------------------------------------------------ frame
    function render(t) {
      ctx.setTransform(K, 0, 0, K, 0, 0);
      ctx.fillStyle = "#fff"; ctx.fillRect(0, 0, W, H);

      // Frame chrome: the mark top left, a thin progress line, the site bottom right.
      const chromeA = compact ? 0 : smooth(0.1, 0.6, t) * (1 - smooth(15.0, 15.6, t));
      if (chromeA > 0) {
        display("QUBE", 120, 132, 22, 300, chromeA, INK, "left", "0.18em");
        umlaut(120, 132, 22, chromeA, "QUBE", "0.18em", 300);
        mono("qubelabs.org", W - 120, 132, chromeA, "right");
        ctx.fillStyle = rgba(LINE, chromeA); ctx.fillRect(120, 1030, W - 240, 1);
        ctx.fillStyle = rgba(INK, chromeA); ctx.fillRect(120, 1030, (W - 240) * clamp(t / 15.2), 1);
      }

      ctx.strokeStyle = INK; ctx.lineCap = "round"; ctx.lineJoin = "round";

      // 01 · a point pops in, 02 · stretches into a line, 03 · opens into a square
      if (t < 4.6) {
        yaw = 0; pitch = 0;
        const pop = spring(seg(t, 0.3, 1.2));
        const stretch = ease(seg(t, 1.6, 2.6));
        const open = ease(seg(t, 3.0, 4.3));
        const w = stretch, e = open;
        const [lx, ly] = proj([-w, 0, 1]), [rx] = proj([w, 0, 1]);
        if (e <= 0) {
          ctx.lineWidth = (lerp(24 * pop, 3, easeOut(stretch))) * LW;
          ctx.beginPath(); ctx.moveTo(lx, ly); ctx.lineTo(rx + 0.01, ly); ctx.stroke();
        } else {
          ctx.lineWidth = (3) * LW;
          const pts = (y) => [proj([-1, y, 1]), proj([1, y, 1])];
          for (const y of [e, -e]) { const [a, b] = pts(y); ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke(); }
          for (const x of [-1, 1]) { const a = proj([x, -e, 1]), b = proj([x, e, 1]); ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke(); }
        }
      }

      // 04 · the square extrudes into a cube, 05 · the cube inflates into the Sfere
      if (t >= 4.6 && t < 10.6) {
        const k = ease(seg(t, 4.6, 5.9));
        const turn = ease(seg(t, 4.6, 6.4));
        yaw = lerp(0, -0.62, turn) - Math.max(0, t - 6.4) * 0.21;
        pitch = lerp(0, 0.4, turn);
        const inflate = ease(seg(t, 7.2, 8.9));
        const gridA = smooth(5.4, 6.3, t);
        const fade = 1 - smooth(9.8, 10.5, t);
        drawGlobe({ depth: k, inflate, gridA, fine: inflate, fade, backA: lerp(0.1, 0.06, inflate) });
      }

      // 06 · the Sfere's outline becomes Cirqlė
      const r0 = U * R * D / Math.sqrt(D * D - R * R);
      if (t >= 9.6 && t < 12.9) {
        const ring = smooth(9.6, 10.2, t), fill = ease(seg(t, 10.2, 10.9));
        const eyes = spring(seg(t, 10.8, 11.4));
        const bl = seg(t, 11.55, 11.75), blink = bl > 0 && bl < 1 ? Math.sin(bl * Math.PI) : 0;
        const hop = seg(t, 11.0, 11.6), squash = hop > 0 && hop < 1 ? Math.sin(hop * Math.PI * 2) * 0.06 * (1 - hop) : 0;
        // then it shrinks into its place in the lineup
        const go = ease(seg(t, 12.2, 12.9));
        const slot = slotX(5), r = lerp(r0, 44, go);
        const x = lerp(CX, slot, go), y = lerp(CY, ROW_Y, go);
        if (fill < 1) { ctx.lineWidth = (3) * LW; ctx.strokeStyle = rgba(INK, ring * (1 - fill)); ctx.beginPath(); ctx.arc(x, y, r, 0, 7); ctx.stroke(); }
        drawAgent(x, y, r, fill, blink, eyes, squash);
      }

      // 07 · all eight shapes in a row
      if (t >= 12.2 && t < 16.4) {
        ctx.strokeStyle = INK; ctx.lineWidth = (3) * LW;
        SHAPES.forEach((sh, i) => {
          const p = i === 5 ? (t >= 12.9 ? 1 : 0) : seg(t, 12.3 + i * 0.12, 13.2 + i * 0.12);
          if (p <= 0) return;
          // 08 · they gather into one point
          const g = easeIn(seg(t, 15.2 + Math.abs(i - 3.5) * 0.05, 15.9 + Math.abs(i - 3.5) * 0.05));
          const x = lerp(slotX(i), CX, g), y = lerp(ROW_Y, CY - 40, g), s = 1 - g;
          if (s <= 0.02) return;
          ctx.globalAlpha = 1 - g * 0.6;
          sh.draw(x, y, s, p);
          ctx.globalAlpha = 1;
          const la = seg(t, 12.7 + i * 0.12, 13.2 + i * 0.12) * (1 - smooth(15.0, 15.3, t));
          if (!compact) mono(sh.label, slotX(i), ROW_Y + 110, la, "center", 16, i >= 6 ? ACCENT : MUTED);
        });
        const brace = compact ? 0 : smooth(13.6, 14.1, t) * (1 - smooth(15.0, 15.3, t));
        if (brace > 0) {
          ctx.strokeStyle = rgba(ACCENT, brace); ctx.lineWidth = (1.5) * LW;
          ctx.beginPath(); ctx.moveTo(slotX(6) - 60, ROW_Y + 136); ctx.lineTo(slotX(7) + 60, ROW_Y + 136); ctx.stroke();
          mono("The Capital", (slotX(6) + slotX(7)) / 2, ROW_Y + 166, brace, "center", 14, ACCENT);
        }
      }

      // 08 · QÜBE
      if (t >= 15.7) finale(t);

      if (!compact) captions(t);
    }

    const ROW_Y = CY - 20;
    const slotX = (i) => CX + (i - 3.5) * 196;

    function umlaut(x, y, size, a, word, spacing, weight) {
      // Two accent dots over the U, as on the site's wordmark.
      ctx.font = `${weight} ${size}px "Unbounded"`;
      ctx.letterSpacing = spacing;
      const q = ctx.measureText(word[0]).width, u = ctx.measureText("U").width;
      ctx.letterSpacing = "0px";
      const d = Math.max(4, size * 0.12), top = y - size * 0.73 - size * 0.16;
      ctx.fillStyle = rgba(ACCENT, a);
      const ux = x + q, uw = u - parseFloat(spacing) * size;
      for (const cx of [ux + uw * 0.22 + d / 2, ux + uw * 0.78 - d / 2]) { ctx.beginPath(); ctx.arc(cx, top, d / 2, 0, 7); ctx.fill(); }
    }

    function finale(t) {
      const size = 250, word = "QUBE", sp = 0.02;
      ctx.font = `200 ${size}px "Unbounded"`;
      const widths = [...word].map((ch) => ctx.measureText(ch).width);
      const total = widths.reduce((a, b) => a + b, 0) + sp * size * (word.length - 1);
      let x = CX - total / 2;
      const base = CY + 70;
      // The gathered point splits into the umlaut's two dots.
      const split = ease(seg(t, 15.95, 16.6));
      const uX = x + widths[0] + sp * size, uW = widths[1];
      const d = size * 0.088, dotY = lerp(CY - 40, base - size * 0.73 - size * 0.1, split);
      const pop = spring(seg(t, 15.7, 16.0));
      ctx.fillStyle = ACCENT;
      for (const [side, cx] of [[-1, uX + uW * 0.22 + d / 2], [1, uX + uW * 0.78 - d / 2]]) {
        const px = lerp(CX, cx, split), r = lerp(12 * pop, d / 2, split);
        ctx.beginPath(); ctx.arc(px, dotY, r, 0, 7); ctx.fill();
      }
      [...word].forEach((ch, i) => {
        const a = easeOut(seg(t, 16.2 + i * 0.08, 16.9 + i * 0.08));
        if (a > 0) {
          ctx.save();
          ctx.beginPath(); ctx.rect(0, 0, W, base + 20); ctx.clip();
          display(ch, x + widths[i] / 2, base + (1 - a) * 60, size, 200, a);
          ctx.restore();
        }
        x += widths[i] + sp * size;
      });
      if (compact) return;
      const tag = easeOut(seg(t, 17.0, 17.8));
      display("Minds that remember, and the worlds they live in.", CX, base + 120 + (1 - tag) * 14, 34, 300, tag, INK);
      const url = easeOut(seg(t, 17.5, 18.2));
      mono("qubelabs.org", CX, base + 190, url, "center", 18, MUTED);
    }

    // ---------------------------------------------------------------- playback
    let at = 0, playing = false, last = 0, raf = 0;
    const tick = (now) => {
      if (!playing) return;
      at += Math.min(0.05, (now - last) / 1000);
      last = now;
      if (at >= DUR) at = 0;   // loop; the last frames hold on the wordmark
      render(at);
      raf = requestAnimationFrame(tick);
    };
    const film = {
      get time() { return at; },
      get playing() { return playing; },
      duration: DUR,
      play() { if (playing) return; playing = true; last = performance.now(); raf = requestAnimationFrame(tick); onState && onState(true); },
      pause() { playing = false; cancelAnimationFrame(raf); onState && onState(false); },
      seek(t) { at = clamp(t, 0, DUR); render(at); },
    };
    function fit() {
      const css = cv.clientWidth || W, dpr = Math.min(window.devicePixelRatio || 1, 2);
      cv.width = Math.round(css * dpr); cv.height = Math.round((css * dpr * H) / W);
      K = cv.width / W;
      const cssScale = css / W;
      LW = Math.max(1, 1.3 / (3 * cssScale));   // main strokes stay at least 1.3 css px
      compact = css < 640;
      render(at);
    }
    if (window.ResizeObserver) new ResizeObserver(fit).observe(cv);
    fit();
    return film;
  }
  window.QubeMotion = { mount };
})();
