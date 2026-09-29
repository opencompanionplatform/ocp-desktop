
import { useEffect, useMemo, useRef, useState } from "react";
import StudioLanguageSwitch from "../../components/StudioLanguageSwitch.jsx";
import { getDesktopSigningIdentity, getDesktopStudioBridge, savePackageToDesktop, signPackageWithDesktop } from "../../desktop-bridge.js";
import { checkCreatorCloudPackageIdentity, reserveCreatorCloudPackageIdentity, submitCreatorCloudForReview, uploadSignedArchiveToCreatorCloud } from "../../creator-cloud.js";
import { EFFECT_BOND_RANKS, EFFECT_SLOT_META, EFFECT_SLOT_ORDER } from "./effect-pack-contract.js";
import {
  buildSpriteEffectPackDefinition,
  buildSpriteEffectPackPackageDraft,
  computeDominantAlphaBounds,
  computeSpriteSheetLayout,
  createDefaultSpriteFxPackProject,
  spriteFxPackProjectIssues,
} from "./sprite-sheet-effect-model.js";

const HELP = {
  bodyAura: "Loop around the companion. Keep the center empty.",
  groundRune: "Loop under the companion. Keep the center readable.",
  levelUpBurst: "One-shot celebration above and around the companion.",
};

function downloadBlob(blob, name) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(function () { URL.revokeObjectURL(url); }, 0);
}

function emptySource() {
  return { file: null, videoUrl: "", duration: 0, sheetBlob: null, sheetUrl: "", layout: null, progress: 0, status: "No source video" };
}

function createSources() {
  return Object.fromEntries(EFFECT_SLOT_ORDER.map(function (name) { return [name, emptySource()]; }));
}

function hexToRgb(hex) {
  const value = String(hex || "#00FF00").replace("#", "");
  return {
    r: Number.parseInt(value.slice(0, 2), 16) || 0,
    g: Number.parseInt(value.slice(2, 4), 16) || 255,
    b: Number.parseInt(value.slice(4, 6), 16) || 0,
  };
}

function mergeBounds(current, next) {
  if (!next) return current;
  if (!current) return next;
  const x = Math.min(current.x, next.x);
  const y = Math.min(current.y, next.y);
  const right = Math.max(current.x + current.width, next.x + next.width);
  const bottom = Math.max(current.y + current.height, next.y + next.height);
  return { x, y, width: right - x, height: bottom - y };
}

function chroma(ctx, size, color, threshold, softness, despill, smartBounds = false) {
  const image = ctx.getImageData(0, 0, size, size);
  const data = image.data;
  let minX = size;
  let minY = size;
  let maxX = -1;
  let maxY = -1;
  const key = hexToRgb(color);
  const hard = Number(threshold);
  const feather = Math.max(1, Number(softness));
  for (let i = 0; i < data.length; i += 4) {
    const dr = data[i] - key.r;
    const dg = data[i + 1] - key.g;
    const db = data[i + 2] - key.b;
    const distance = Math.sqrt(dr * dr + dg * dg + db * db);
    if (distance <= hard) data[i + 3] = 0;
    else if (distance < hard + feather) data[i + 3] = Math.round(data[i + 3] * ((distance - hard) / feather));
    if (despill && data[i + 1] > data[i] && data[i + 1] > data[i + 2]) {
      const neighbor = Math.max(data[i], data[i + 2]);
      data[i + 1] = Math.round(neighbor + (data[i + 1] - neighbor) * 0.18);
    }
    if (data[i + 3] > 8) {
      const pixel = i / 4;
      const x = pixel % size;
      const y = Math.floor(pixel / size);
      minX = Math.min(minX, x);
      minY = Math.min(minY, y);
      maxX = Math.max(maxX, x);
      maxY = Math.max(maxY, y);
    }
  }
  const visualBounds = maxX >= minX && maxY >= minY
    ? { x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1 }
    : null;
  const dominantBounds = smartBounds && visualBounds
    ? computeDominantAlphaBounds(data, size, size, visualBounds)
    : visualBounds;
  ctx.putImageData(image, 0, 0);
  return { visualBounds, dominantBounds };
}

function seek(video, time) {
  return new Promise(function (resolve, reject) {
    const done = function () { cleanup(); resolve(); };
    const fail = function () { cleanup(); reject(new Error("Video frame could not be decoded.")); };
    const cleanup = function () {
      video.removeEventListener("seeked", done);
      video.removeEventListener("error", fail);
    };
    video.addEventListener("seeked", done, { once: true });
    video.addEventListener("error", fail, { once: true });
    video.currentTime = time;
  });
}

function canvasBlob(canvas) {
  return new Promise(function (resolve, reject) {
    canvas.toBlob(function (blob) { blob ? resolve(blob) : reject(new Error("Could not encode PNG sheet.")); }, "image/png");
  });
}

function PreviewCanvas({ source, fps, slotName, tint, placement }) {
  const ref = useRef(null);
  useEffect(function () {
    if (!source.sheetUrl || !source.layout) return undefined;
    const image = new Image();
    let raf = 0;
    let stopped = false;
    let start = performance.now();
    image.onload = function () {
      const canvas = ref.current;
      const ctx = canvas && canvas.getContext("2d");
      if (!ctx) return;
      const draw = function (now) {
        if (stopped) return;
        const elapsed = (now - start) / 1000;
        const raw = Math.floor(elapsed * fps);
        const frame = slotName === "levelUpBurst" ? Math.min(source.layout.frameCount - 1, raw) : raw % source.layout.frameCount;
        const col = frame % source.layout.columns;
        const row = Math.floor(frame / source.layout.columns);
        ctx.clearRect(0, 0, 420, 420);
        const character = { x: 150, y: 126, width: 120, height: 168 };
        const anchorMode = String(placement?.anchor || (slotName === "groundRune" ? "character-feet" : slotName === "levelUpBurst" ? "character-feet-bottom" : "character-center"));
        const anchor = anchorMode === "character-feet" || anchorMode === "character-feet-bottom"
          ? { x: character.x + character.width / 2, y: character.y + character.height }
          : anchorMode === "character-above-head"
            ? { x: character.x + character.width / 2, y: character.y }
            : { x: character.x + character.width / 2, y: character.y + character.height / 2 };
        const frameWidth = source.layout.frameWidth;
        const frameHeight = source.layout.frameHeight;
        const content = source.layout.contentBounds || { x: 0, y: 0, width: frameWidth, height: frameHeight };
        const contentWidth = Math.max(1, Number(content.width) || frameWidth);
        const contentHeight = Math.max(1, Number(content.height) || frameHeight);
        const scaleValue = Number(placement?.scale ?? (slotName === "groundRune" ? 1.40 : slotName === "levelUpBurst" ? 1.10 : 1.12));
        const uniform = placement?.scaleMode === "character-width"
          ? character.width * scaleValue / contentWidth
          : placement?.scaleMode === "native-surface"
            ? 300 * scaleValue / Math.max(contentWidth, contentHeight)
            : character.height * scaleValue / contentHeight;
        let scaleX = uniform;
        let scaleY = uniform;
        if (slotName === "groundRune" && Number(placement?.maxHeightRatio) > 0) {
          scaleY = Math.min(scaleY, character.height * Number(placement.maxHeightRatio) / contentHeight);
        }

        const safeMargin = slotName === "groundRune" ? 4 : 2;
        const contentHalf = { x: contentWidth * scaleX / 2, y: contentHeight * scaleY / 2 };
        const userOffset = { x: Number(placement?.offsetX ?? 0), y: Number(placement?.offsetY ?? 0) };
        const contentCenter = { x: anchor.x + userOffset.x, y: anchor.y + userOffset.y };
        if (anchorMode === "character-feet-bottom") contentCenter.y -= contentHalf.y;
        if (contentHalf.x * 2 <= 420 - safeMargin * 2) {
          contentCenter.x = Math.max(contentHalf.x + safeMargin, Math.min(420 - contentHalf.x - safeMargin, contentCenter.x));
        }
        if (contentHalf.y * 2 <= 420 - safeMargin * 2 && slotName !== "groundRune") {
          contentCenter.y = Math.max(contentHalf.y + safeMargin, Math.min(420 - contentHalf.y - safeMargin, contentCenter.y));
        }

        const contentCenterOffset = {
          x: Number(content.x || 0) + contentWidth / 2 - frameWidth / 2,
          y: Number(content.y || 0) + contentHeight / 2 - frameHeight / 2,
        };
        const frameCenter = {
          x: contentCenter.x - contentCenterOffset.x * scaleX,
          y: contentCenter.y - contentCenterOffset.y * scaleY,
        };
        const drawWidth = frameWidth * scaleX;
        const drawHeight = frameHeight * scaleY;
        const drawX = frameCenter.x - drawWidth / 2;
        const drawY = frameCenter.y - drawHeight / 2;
        ctx.drawImage(image, col * frameWidth, row * frameHeight, frameWidth, frameHeight, drawX, drawY, drawWidth, drawHeight);
        if (tint !== "#FFFFFF") {
          ctx.globalCompositeOperation = "source-atop";
          ctx.globalAlpha = 0.76;
          ctx.fillStyle = tint;
          ctx.fillRect(0, 0, 420, 420);
          ctx.globalCompositeOperation = "source-over";
          ctx.globalAlpha = 1;
        }
        if (slotName === "levelUpBurst" && frame === source.layout.frameCount - 1 && elapsed > source.layout.frameCount / fps + 0.5) start = now;
        raf = requestAnimationFrame(draw);
      };
      raf = requestAnimationFrame(draw);
    };
    image.src = source.sheetUrl;
    return function () { stopped = true; cancelAnimationFrame(raf); };
  }, [source, fps, slotName, tint, placement]);
  return <canvas ref={ref} className={"sprite-pack-preview-canvas is-" + slotName} width="420" height="420" />;
}

function decodedMiB(layout) {
  if (!layout) return 0;
  return (Number(layout.sheetWidth || 0) * Number(layout.sheetHeight || 0) * 4) / (1024 * 1024);
}

function performanceRating(mib) {
  if (mib < 12) return { label: "Excellent", tone: "excellent" };
  if (mib <= 20) return { label: "Good", tone: "good" };
  if (mib <= 32) return { label: "Heavy", tone: "heavy" };
  return { label: "Too heavy", tone: "critical" };
}

function SlotCard(props) {
  const name = props.slotName;
  const source = props.source;
  const cfg = props.project.slots[name];
  const meta = EFFECT_SLOT_META[name];
  const converted = Boolean(source.sheetBlob && source.layout);
  const number = name === "bodyAura" ? "01" : name === "groundRune" ? "02" : "03";

  return <article className={"sprite-pack-card sprite-pack-card-" + name}>
    <header>
      <b>{number}</b>
      <div><h2>{meta.label}</h2><p>{HELP[name]}</p></div>
      <label><input type="checkbox" checked={cfg.enabled} onChange={function (e) { props.updateSlot(name, "enabled", e.target.checked); }} /><span>{cfg.enabled ? "ON" : "OFF"}</span></label>
    </header>

    <div className="sprite-pack-preview">
      {converted
        ? <PreviewCanvas source={source} fps={cfg.fps} slotName={name} tint={props.previewTint} placement={cfg} />
        : <div className="sprite-pack-preview-empty"><strong>{name === "bodyAura" ? "◯" : name === "groundRune" ? "◎" : "✦"}</strong><span>{meta.label}</span></div>}
      <div className="sprite-pack-character"><span>Character</span></div>
    </div>

    <label className="sprite-pack-upload">
      <input hidden type="file" accept="video/*" onChange={function (e) { props.selectVideo(name, e); }} />
      <strong>{source.file ? source.file.name : "Choose source video"}</strong>
      <span>{source.file ? (source.duration ? source.duration.toFixed(2) + "s" : "reading metadata") : "≤4s · 1024×1024 · #00FF00"}</span>
    </label>

    {source.videoUrl ? <video
      ref={props.videoRef}
      src={source.videoUrl}
      className="sprite-pack-video"
      muted
      controls
      playsInline
      onLoadedMetadata={function (e) { props.metadata(name, e.currentTarget.duration); }}
    /> : null}

    {converted ? (() => { const mib = decodedMiB(source.layout); const rating = performanceRating(mib); return <div className={`sprite-pack-performance is-${rating.tone}`}><span><b>Runtime budget</b><small>{source.layout.frameWidth}×{source.layout.frameHeight} · {source.layout.sheetWidth}×{source.layout.sheetHeight}</small></span><strong>{mib.toFixed(1)} MiB</strong><em>{rating.label}</em></div>; })() : null}

    <div className="sprite-pack-mini-controls">
      <label><span>FPS</span><select value={cfg.fps} onChange={function (e) { props.updateSlot(name, "fps", Number(e.target.value)); }}><option>8</option><option>10</option><option>12</option><option>15</option><option>20</option><option>24</option></select></label>
      <label><span>Frame</span><select value={cfg.frameSize} onChange={function (e) { props.updateSlot(name, "frameSize", Number(e.target.value)); }}><option>256</option><option>384</option><option>512</option><option>768</option></select></label>
      <label><span>Runtime cap</span><select value={cfg.runtimeExportCap ?? 384} onChange={function (e) { props.updateSlot(name, "runtimeExportCap", Number(e.target.value)); }}><option>256</option><option>320</option><option>384</option><option>512</option></select></label>
      <label><span>Cols</span><select value={cfg.columns} onChange={function (e) { props.updateSlot(name, "columns", Number(e.target.value)); }}><option>4</option><option>6</option><option>8</option><option>10</option><option>12</option></select></label>
      <label><span>Tint</span><input type="color" value={cfg.tint.slice(0, 7)} onChange={function (e) { props.updateSlot(name, "tint", e.target.value.toUpperCase()); }} /></label>
    </div>

    <details className="sprite-pack-key sprite-pack-placement" open>
      <summary>Runtime placement</summary>
      <div>
        <label><span>Anchor</span><select value={cfg.anchor} onChange={function (e) { props.updateSlot(name, "anchor", e.target.value); }}><option value="character-center">Body center</option><option value="character-feet">Feet center</option><option value="character-feet-bottom">Feet / ground (bottom aligned)</option><option value="character-above-head">Above head</option></select></label>
        <label><span>Scale mode</span><select value={cfg.scaleMode} onChange={function (e) { props.updateSlot(name, "scaleMode", e.target.value); }}><option value="character-width">Character width</option><option value="character-height">Character height</option><option value="native-surface">Native surface</option></select></label>
        <label><span>Scale {Number(cfg.scale).toFixed(2)}×</span><input type="range" min="0.5" max="2.5" step="0.05" value={cfg.scale} onChange={function (e) { props.updateSlot(name, "scale", Number(e.target.value)); }} /></label>
        <label><span>Offset X</span><input type="number" min="-256" max="256" value={cfg.offsetX} onChange={function (e) { props.updateSlot(name, "offsetX", Number(e.target.value)); }} /></label>
        <label><span>Offset Y</span><input type="number" min="-256" max="256" value={cfg.offsetY} onChange={function (e) { props.updateSlot(name, "offsetY", Number(e.target.value)); }} /></label>
        <label><span>Z index</span><input type="number" min="-100" max="100" value={cfg.zIndex} onChange={function (e) { props.updateSlot(name, "zIndex", Number(e.target.value)); }} /></label>
        {name === "groundRune" ? <label><span>Max height {Number(cfg.maxHeightRatio).toFixed(2)}× char</span><input type="range" min="0.20" max="0.60" step="0.01" value={cfg.maxHeightRatio} onChange={function (e) { props.updateSlot(name, "maxHeightRatio", Number(e.target.value)); }} /></label> : null}
        <label><span>Auto crop</span><input type="checkbox" checked={cfg.autoCrop} onChange={function (e) { props.updateSlot(name, "autoCrop", e.target.checked); }} /></label>
        <label><span>Crop padding</span><input type="number" min="0" max="64" value={cfg.cropPadding} onChange={function (e) { props.updateSlot(name, "cropPadding", Number(e.target.value)); }} /></label>
      </div>
      <small className="studio-note">{name === "groundRune" ? "Feet Center · behind character · width-driven scaling" : name === "bodyAura" ? "Body Center · behind character · smart core sizing · particles preserved" : cfg.anchor === "character-feet-bottom" ? "Ground baseline · bottom aligned · front effect · one-shot" : "Configurable anchor · front effect · one-shot"}</small>
    </details>

    <details className="sprite-pack-key">
      <summary>Chroma key</summary>
      <div>
        <label><span>Key</span><input type="color" value={cfg.keyColor} onChange={function (e) { props.updateSlot(name, "keyColor", e.target.value.toUpperCase()); }} /></label>
        <label><span>Threshold {cfg.threshold}</span><input type="range" min="20" max="180" value={cfg.threshold} onChange={function (e) { props.updateSlot(name, "threshold", Number(e.target.value)); }} /></label>
        <label><span>Softness {cfg.softness}</span><input type="range" min="1" max="140" value={cfg.softness} onChange={function (e) { props.updateSlot(name, "softness", Number(e.target.value)); }} /></label>
        <label><span>Despill</span><input type="checkbox" checked={cfg.despill} onChange={function (e) { props.updateSlot(name, "despill", e.target.checked); }} /></label>
      </div>
    </details>

    <button type="button" className="studio-button studio-primary sprite-pack-convert" disabled={!cfg.enabled || !source.file || props.busy} onClick={function () { props.convert(name); }}>
      {props.busy ? "Converting… " + source.progress + "%" : converted ? "Re-convert Video" : "Convert to Sprite Sheet"}
    </button>
    <div className="sprite-pack-progress"><i style={{ width: source.progress + "%" }} /></div>
    <footer><span>{source.status}</span>{source.layout ? <b>{source.layout.columns + "×" + source.layout.rows + " · " + source.layout.frameCount + " frames"}</b> : null}</footer>
  </article>;
}

export default function SpriteSheetEffectStudio({ onCharacter, access, creatorSession, creatorProfile, locale = "en", onLocaleChange }) {
  const [project, setProject] = useState(function () { return createDefaultSpriteFxPackProject(); });
  const [sources, setSources] = useState(function () { return createSources(); });
  const [busySlot, setBusySlot] = useState("");
  const [buildBusy, setBuildBusy] = useState(false);
  const [cloudBusy, setCloudBusy] = useState(false);
  const [cloudState, setCloudState] = useState({ stage: "idle", percent: 0, message: "Creator Cloud is ready for an admin Effect Pack acceptance run.", submissionId: null });
  const [previewRank, setPreviewRank] = useState("stranger");
  const [status, setStatus] = useState("A complete Effect Pack normally uses three source videos.");
  const [signer, setSigner] = useState(null);
  const bridge = useMemo(function () { return getDesktopStudioBridge(); }, []);
  const videoRefs = useRef({});
  const issues = useMemo(function () { return spriteFxPackProjectIssues(project); }, [project]);

  useEffect(function () {
    let active = true;
    async function load() {
      try {
        const desktop = await getDesktopSigningIdentity(bridge);
        if (active) setSigner(desktop ? { ...desktop, source: "desktop" } : null);
      } catch { if (active) setSigner(null); }
    }
    void load();
    return function () { active = false; };
  }, [bridge]);

  function updateProject(key, value) {
    setProject(function (current) { return { ...current, [key]: value }; });
  }
  function updateSlot(name, key, value) {
    setProject(function (current) {
      return { ...current, slots: { ...current.slots, [name]: { ...current.slots[name], [key]: value } } };
    });
  }
  function updateRank(rank, key, value) {
    setProject(function (current) {
      return { ...current, rankStyles: { ...current.rankStyles, [rank]: { ...current.rankStyles[rank], [key]: value } } };
    });
  }
  function patchSource(name, patch) {
    setSources(function (current) { return { ...current, [name]: { ...current[name], ...patch } }; });
  }

  function selectVideo(name, event) {
    const file = event.target.files && event.target.files[0];
    event.target.value = "";
    if (!file) return;
    const current = sources[name];
    if (current.videoUrl) URL.revokeObjectURL(current.videoUrl);
    if (current.sheetUrl) URL.revokeObjectURL(current.sheetUrl);
    patchSource(name, { file, videoUrl: URL.createObjectURL(file), duration: 0, sheetBlob: null, sheetUrl: "", layout: null, progress: 0, status: "Reading metadata…" });
  }

  function metadata(name, duration) {
    const value = Number.isFinite(duration) ? duration : 0;
    patchSource(name, { duration: value, status: value > 4.05 ? "First 4.00s will be used" : "Source ready" });
  }

  async function convert(name) {
    const video = videoRefs.current[name];
    const source = sources[name];
    const cfg = project.slots[name];
    if (!video || !source.file || !video.duration) return;
    const used = Math.min(video.duration, 4);
    const count = Math.max(1, Math.min(120, Math.round(used * cfg.fps)));
    const sourceLayout = computeSpriteSheetLayout(count, cfg.frameSize, cfg.columns);
    if (sourceLayout.sheetWidth > 8192 || sourceLayout.sheetHeight > 8192) { patchSource(name, { status: "Sheet too large; reduce FPS/frame size." }); return; }

    setBusySlot(name);
    patchSource(name, { progress: 0, status: "Sampling " + count + " frames…" });
    const frame = document.createElement("canvas");
    frame.width = cfg.frameSize; frame.height = cfg.frameSize;
    const fctx = frame.getContext("2d", { willReadFrequently: true });
    const sheet = document.createElement("canvas");
    sheet.width = sourceLayout.sheetWidth; sheet.height = sourceLayout.sheetHeight;
    const sctx = sheet.getContext("2d");
    let union = null;
    let dominantUnion = null;
    try {
      video.pause();
      for (let i = 0; i < count; i += 1) {
        const time = count === 1 ? 0 : Math.min(used - 0.001, (i / count) * used);
        await seek(video, Math.max(0, time));
        fctx.clearRect(0, 0, cfg.frameSize, cfg.frameSize);
        const scale = Math.min(cfg.frameSize / video.videoWidth, cfg.frameSize / video.videoHeight);
        const w = video.videoWidth * scale;
        const h = video.videoHeight * scale;
        fctx.drawImage(video, (cfg.frameSize - w) / 2, (cfg.frameSize - h) / 2, w, h);
        const keyed = chroma(fctx, cfg.frameSize, cfg.keyColor, cfg.threshold, cfg.softness, cfg.despill, name === "bodyAura");
        union = mergeBounds(union, keyed.visualBounds);
        dominantUnion = mergeBounds(dominantUnion, keyed.dominantBounds);
        sctx.drawImage(frame, (i % sourceLayout.columns) * cfg.frameSize, Math.floor(i / sourceLayout.columns) * cfg.frameSize);
        patchSource(name, { progress: Math.round(((i + 1) / count) * 100) });
      }
      let outputCanvas = sheet;
      let layout = sourceLayout;
      if (cfg.autoCrop && union) {
        const padding = Math.max(0, Math.min(64, Number(cfg.cropPadding) || 0));
        const cropX = Math.max(0, union.x - padding);
        const cropY = Math.max(0, union.y - padding);
        const cropRight = Math.min(cfg.frameSize, union.x + union.width + padding);
        const cropBottom = Math.min(cfg.frameSize, union.y + union.height + padding);
        const cropWidth = Math.max(1, cropRight - cropX);
        const cropHeight = Math.max(1, cropBottom - cropY);
        const cropped = document.createElement("canvas");
        cropped.width = sourceLayout.columns * cropWidth;
        cropped.height = sourceLayout.rows * cropHeight;
        const cctx = cropped.getContext("2d");
        if (!cctx) throw new Error("Crop renderer unavailable.");
        for (let i = 0; i < count; i += 1) {
          const sourceX = (i % sourceLayout.columns) * cfg.frameSize + cropX;
          const sourceY = Math.floor(i / sourceLayout.columns) * cfg.frameSize + cropY;
          const destX = (i % sourceLayout.columns) * cropWidth;
          const destY = Math.floor(i / sourceLayout.columns) * cropHeight;
          cctx.drawImage(sheet, sourceX, sourceY, cropWidth, cropHeight, destX, destY, cropWidth, cropHeight);
        }
        outputCanvas = cropped;
        const dominant = name === "bodyAura" && dominantUnion ? dominantUnion : union;
        const contentLeft = Math.max(0, Math.min(cropWidth - 1, Number(dominant?.x ?? cropX) - cropX));
        const contentTop = Math.max(0, Math.min(cropHeight - 1, Number(dominant?.y ?? cropY) - cropY));
        const contentRight = Math.max(contentLeft + 1, Math.min(cropWidth, Number(dominant?.x ?? cropX) + Number(dominant?.width ?? cropWidth) - cropX));
        const contentBottom = Math.max(contentTop + 1, Math.min(cropHeight, Number(dominant?.y ?? cropY) + Number(dominant?.height ?? cropHeight) - cropY));
        layout = {
          ...sourceLayout,
          frameWidth: cropWidth,
          frameHeight: cropHeight,
          sheetWidth: cropped.width,
          sheetHeight: cropped.height,
          contentBounds: { x: contentLeft, y: contentTop, width: contentRight - contentLeft, height: contentBottom - contentTop },
          sourceCrop: { x: cropX, y: cropY, width: cropWidth, height: cropHeight },
        };
      } else {
        const dominant = name === "bodyAura" && dominantUnion
          ? dominantUnion
          : { x: 0, y: 0, width: cfg.frameSize, height: cfg.frameSize };
        layout = {
          ...sourceLayout,
          contentBounds: {
            x: Math.max(0, Math.min(cfg.frameSize - 1, dominant.x)),
            y: Math.max(0, Math.min(cfg.frameSize - 1, dominant.y)),
            width: Math.max(1, Math.min(cfg.frameSize - Math.max(0, dominant.x), dominant.width)),
            height: Math.max(1, Math.min(cfg.frameSize - Math.max(0, dominant.y), dominant.height)),
          },
          sourceCrop: { x: 0, y: 0, width: cfg.frameSize, height: cfg.frameSize },
        };
      }
      const runtimeCap = Math.max(128, Math.min(512, Number(cfg.runtimeExportCap) || 384));
      const authoredMax = Math.max(layout.frameWidth, layout.frameHeight);
      if (authoredMax > runtimeCap) {
        const factor = runtimeCap / authoredMax;
        const exportWidth = Math.max(1, Math.round(layout.frameWidth * factor));
        const exportHeight = Math.max(1, Math.round(layout.frameHeight * factor));
        const runtimeCanvas = document.createElement("canvas");
        runtimeCanvas.width = layout.columns * exportWidth;
        runtimeCanvas.height = layout.rows * exportHeight;
        const rctx = runtimeCanvas.getContext("2d");
        if (!rctx) throw new Error("Runtime export renderer unavailable.");
        rctx.imageSmoothingEnabled = true;
        rctx.imageSmoothingQuality = "high";
        for (let i = 0; i < count; i += 1) {
          const sourceX = (i % layout.columns) * layout.frameWidth;
          const sourceY = Math.floor(i / layout.columns) * layout.frameHeight;
          const destX = (i % layout.columns) * exportWidth;
          const destY = Math.floor(i / layout.columns) * exportHeight;
          rctx.drawImage(outputCanvas, sourceX, sourceY, layout.frameWidth, layout.frameHeight, destX, destY, exportWidth, exportHeight);
        }
        outputCanvas = runtimeCanvas;
        const authoredContent = layout.contentBounds || { x: 0, y: 0, width: layout.frameWidth, height: layout.frameHeight };
        const contentLeft = Math.max(0, Math.min(exportWidth - 1, Math.floor(authoredContent.x * factor)));
        const contentTop = Math.max(0, Math.min(exportHeight - 1, Math.floor(authoredContent.y * factor)));
        const contentRight = Math.max(contentLeft + 1, Math.min(exportWidth, Math.ceil((authoredContent.x + authoredContent.width) * factor)));
        const contentBottom = Math.max(contentTop + 1, Math.min(exportHeight, Math.ceil((authoredContent.y + authoredContent.height) * factor)));
        layout = {
          ...layout,
          frameWidth: exportWidth,
          frameHeight: exportHeight,
          sheetWidth: runtimeCanvas.width,
          sheetHeight: runtimeCanvas.height,
          contentBounds: { x: contentLeft, y: contentTop, width: contentRight - contentLeft, height: contentBottom - contentTop },
          runtimeExportCap: runtimeCap,
          runtimeScale: factor,
        };
      } else {
        layout = { ...layout, runtimeExportCap: runtimeCap, runtimeScale: 1 };
      }
      if (layout.sheetWidth > 8192 || layout.sheetHeight > 8192) throw new Error("Runtime sheet still exceeds 8192px; reduce FPS/frame size.");
      const blob = await canvasBlob(outputCanvas);
      if (source.sheetUrl) URL.revokeObjectURL(source.sheetUrl);
      patchSource(name, { sheetBlob: blob, sheetUrl: URL.createObjectURL(blob), layout, progress: 100, status: "Ready · " + layout.sheetWidth + "×" + layout.sheetHeight + "px · frame " + layout.frameWidth + "×" + layout.frameHeight });
      setStatus(EFFECT_SLOT_META[name].label + " converted.");
    } catch (error) {
      patchSource(name, { status: error instanceof Error ? error.message : "Conversion failed." });
    } finally { setBusySlot(""); }
  }

  const artifacts = useMemo(function () {
    const result = {};
    EFFECT_SLOT_ORDER.forEach(function (name) {
      const source = sources[name];
      if (source.sheetBlob && source.layout && project.slots[name].enabled) {
        result[name] = { blob: source.sheetBlob, frameCount: source.layout.frameCount, frameWidth: source.layout.frameWidth, frameHeight: source.layout.frameHeight, contentBounds: source.layout.contentBounds, assetPath: "assets/" + name + ".png" };
      }
    });
    return result;
  }, [sources, project.slots]);

  const definition = useMemo(function () {
    if (!Object.keys(artifacts).length) return null;
    try { return buildSpriteEffectPackDefinition(project, artifacts); } catch { return null; }
  }, [project, artifacts]);

  const previewTint = project.progressionMode === "bond-rank" ? project.rankStyles[previewRank].tint : "#FFFFFF";
  const count = Object.keys(artifacts).length;

  async function build() {
    if (!definition) { setStatus("Convert at least one slot first."); return; }
    if (!signer) { setStatus("Signer unavailable; PNG and JSON export still work."); return; }
    setBuildBusy(true);
    try {
      const draft = await buildSpriteEffectPackPackageDraft(project, artifacts, signer);
      const signed = await signPackageWithDesktop(draft.blob, bridge);
      const name = project.id + "-v" + project.version + ".ocp";
      await savePackageToDesktop(signed, name, bridge);
      setStatus("Signed Effect Pack ready: " + name);
    } catch (error) { setStatus(error instanceof Error ? error.message : "Build failed."); }
    finally { setBuildBusy(false); }
  }

  async function ensureCloudIdentity() {
    const accessToken = creatorSession?.accessToken;
    if (!accessToken || !creatorProfile?.publisherId) throw new Error("Sign in to Creator Cloud before publishing Sprite Sheet FX.");
    const packageId = project.id.trim().toLowerCase();
    const displayName = project.name.trim().replace(/s+/g, " ");
    let identity = await checkCreatorCloudPackageIdentity(accessToken, packageId, displayName);
    if (["available", "reserved-by-you", "owned-submission"].includes(identity.decision)) {
      identity = await reserveCreatorCloudPackageIdentity(accessToken, packageId, displayName);
    }
    if (identity.decision !== "reserved-by-you" && identity.decision !== "owned-published") {
      throw new Error("Marketplace Package ID is not publishable: " + identity.decision + ".");
    }
    return identity;
  }

  async function publishCloud() {
    if (!access?.cloudPublishEnabled) { setCloudState({ stage: "blocked", percent: 0, message: "Creator Cloud publication is not enabled for this account.", submissionId: null }); return; }
    if (!definition || issues.length) { setCloudState({ stage: "blocked", percent: 0, message: "Resolve Effect Pack validation issues before publishing.", submissionId: null }); return; }
    if (!signer) { setCloudState({ stage: "blocked", percent: 0, message: "Desktop signing identity is unavailable.", submissionId: null }); return; }
    if (!creatorSession?.accessToken || !creatorProfile?.publisherId) { setCloudState({ stage: "blocked", percent: 0, message: "Sign in to Creator Cloud before publishing.", submissionId: null }); return; }
    if (signer.publisherId !== creatorProfile.publisherId) {
      setCloudState({ stage: "blocked", percent: 0, message: "Desktop signer publisher does not match the Creator Cloud profile.", submissionId: null });
      return;
    }
    const activeKey = Array.isArray(creatorProfile.keys) && creatorProfile.keys.some(function (key) { return key?.status === "active" && key?.keyId === signer.keyId; });
    if (!activeKey) {
      setCloudState({ stage: "blocked", percent: 0, message: "This Desktop signing key is not active in Creator Cloud. Re-link the PC from Character Animation first.", submissionId: null });
      return;
    }

    setCloudBusy(true);
    let submissionId = null;
    const updateProgress = function (progress) {
      if (progress?.submissionId) submissionId = progress.submissionId;
      setCloudState({
        stage: progress?.stage || "working",
        percent: Number(progress?.percent) || 0,
        message: progress?.message || "Creator Cloud operation in progress...",
        submissionId: progress?.submissionId || submissionId,
      });
    };
    try {
      updateProgress({ stage: "identity", percent: 2, message: "Checking Marketplace Package ID..." });
      await ensureCloudIdentity();
      updateProgress({ stage: "building", percent: 4, message: "Building Effect Pack package..." });
      const draft = await buildSpriteEffectPackPackageDraft(project, artifacts, signer);
      updateProgress({ stage: "signing", percent: 6, message: "Signing Effect Pack with Desktop protected key..." });
      const signed = await signPackageWithDesktop(draft.blob, bridge);
      const submission = await uploadSignedArchiveToCreatorCloud(creatorSession.accessToken, {
        blob: signed,
        packageId: project.id.trim().toLowerCase(),
        version: project.version.trim(),
        onProgress: updateProgress,
      });
      submissionId = submission.submissionId;
      const review = await submitCreatorCloudForReview(creatorSession.accessToken, submission.submissionId, updateProgress);
      setCloudState({
        stage: "review-ready",
        percent: 100,
        message: "Submitted for C8 moderation · " + review.packageId + " v" + review.version,
        submissionId: review.submissionId,
      });
      setStatus("Creator Cloud submission ready for Operations review.");
    } catch (error) {
      const message = error instanceof Error ? error.message : "Creator Cloud publish failed.";
      setCloudState({ stage: "error", percent: 0, message, submissionId: error?.submissionId || submissionId });
      setStatus("Creator Cloud publish failed: " + message);
    } finally {
      setCloudBusy(false);
    }
  }

  return <div className="studio-shell sprite-pack-shell">
    <header className="studio-topbar">
      <div className="studio-brand"><span className="studio-orb sprite-fx-orb" />OCP Animation Studio</div>
      <div className="effect-studio-switch">
        <button type="button" onClick={onCharacter}>Character Animation</button>
        <button type="button" className="is-active">Sprite Sheet FX · Beta</button>
      </div>
      <div className="studio-topbar-right"><StudioLanguageSwitch locale={locale} onChange={onLocaleChange} /><div className="studio-meta">3-slot Effect Pack Composer · {access?.cloudPublishEnabled ? "Admin Cloud beta" : "Admin local beta"}</div></div>
    </header>

    <main className="sprite-pack-main">
      <div className="studio-heading">
        <div><h1>Sprite Sheet FX Pack Composer</h1><p>Three independent videos, three runtime slots, one signed Effect Pack.</p></div>
        <div><span className="studio-badge">Beta · Admin</span><div className="sprite-pack-count"><strong>{count + "/3"}</strong><span>converted</span></div></div>
      </div>

      <div className="sprite-pack-guide">
        <span><b>3 videos recommended</b> Body Aura + Ground Rune + Level-Up Burst</span>
        <span><b>Generate white/neutral FX</b> Runtime tint can then recolor cleanly by Bond Rank</span>
        <span><b>Source</b> ≤4s · 1024×1024 · locked camera · solid #00FF00 · effect only</span>
      </div>

      <section className="sprite-pack-grid">
        {EFFECT_SLOT_ORDER.map(function (name) {
          return <SlotCard
            key={name}
            slotName={name}
            project={project}
            source={sources[name]}
            videoRef={function (node) { videoRefs.current[name] = node; }}
            selectVideo={selectVideo}
            metadata={metadata}
            updateSlot={updateSlot}
            convert={convert}
            busy={busySlot === name}
            previewTint={previewTint}
          />;
        })}
      </section>

      <section className="sprite-pack-footer-grid">
        <article className="studio-panel">
          <div className="studio-panel-heading"><h2>Bond Rank Colors</h2><span>Runtime tint</span></div>
          <div className="effect-mode-options sprite-pack-mode">
            <button type="button" className={project.progressionMode === "none" ? "is-active" : ""} onClick={function () { updateProject("progressionMode", "none"); }}><strong>Static</strong><small>Use base tint</small></button>
            <button type="button" className={project.progressionMode === "bond-rank" ? "is-active" : ""} onClick={function () { updateProject("progressionMode", "bond-rank"); }}><strong>Bond Rank</strong><small>Cyan → Blue → Purple → Gold</small></button>
          </div>
          {project.progressionMode === "bond-rank" ? <div className="sprite-pack-ranks">
            {EFFECT_BOND_RANKS.map(function (rank) {
              return <label key={rank} className={previewRank === rank ? "is-active" : ""} onClick={function () { setPreviewRank(rank); }}>
                <input type="color" value={project.rankStyles[rank].tint.slice(0, 7)} onChange={function (e) { updateRank(rank, "tint", e.target.value.toUpperCase()); }} />
                <span><strong>{rank}</strong><small>{project.rankStyles[rank].tint}</small></span>
              </label>;
            })}
          </div> : null}
          <p className="studio-note">Important: use white/near-white source FX for clean recoloring. A cyan baked source cannot become clean gold with multiply tint.</p>
        </article>

        <article className="studio-panel">
          <div className="studio-panel-heading"><h2>Pack Identity</h2><span>effect-pack/1</span></div>
          <div className="studio-fields">
            <label className="studio-field"><span>Package ID</span><input value={project.id} onChange={function (e) { updateProject("id", e.target.value.trim()); }} /></label>
            <label className="studio-field"><span>Name</span><input value={project.name} onChange={function (e) { updateProject("name", e.target.value); }} /></label>
            <label className="studio-field"><span>Version</span><input value={project.version} onChange={function (e) { updateProject("version", e.target.value.trim()); }} /></label>
            <label className="studio-field"><span>License</span><input value={project.license} onChange={function (e) { updateProject("license", e.target.value); }} /></label>
          </div>
          {issues.length ? <div className="effect-validation-list">{issues.map(function (issue) { return <div key={issue}>× {issue}</div>; })}</div> : null}
        </article>

        <article className="studio-panel sprite-pack-build">
          <div className="studio-panel-heading"><h2>Build Pack</h2><span>{definition ? Object.keys(definition.slots).length + " slot(s)" : "Waiting"}</span></div>
          <div className="studio-actions">
            <button className="studio-button" type="button" disabled={!count} onClick={function () {
              EFFECT_SLOT_ORDER.forEach(function (name) { if (sources[name].sheetBlob) downloadBlob(sources[name].sheetBlob, project.id + "-" + name + "-sheet.png"); });
            }}>Export PNG Sheets</button>
            <button className="studio-button" type="button" disabled={!definition} onClick={function () { downloadBlob(new Blob([JSON.stringify(definition, null, 2)], { type: "application/json" }), "effect.json"); }}>Export effect.json</button>
            <button className="studio-button studio-primary" type="button" disabled={!definition || !signer || buildBusy || cloudBusy || issues.length} onClick={build}>{buildBusy ? "Building…" : "Build signed .ocp"}</button>
            {access?.cloudPublishEnabled && <button className="studio-button studio-primary" type="button" disabled={!definition || !signer || !creatorSession?.accessToken || !creatorProfile || buildBusy || cloudBusy || issues.length} onClick={publishCloud}>{cloudBusy ? "Publishing… " + cloudState.percent + "%" : "Publish to Creator Cloud"}</button>}
          </div>
          {!access?.cloudPublishEnabled && <p className="studio-note">Cloud publish remains closed for this account. Admin/Beta creators can build/sign locally and validate in Runtime.</p>}
          {access?.cloudPublishEnabled && <p className="studio-note">Admin/Beta Cloud publication is enabled for {creatorProfile?.publisherId || "this creator"}. The package is signed locally, validated privately, then submitted to Operations for C8 moderation.</p>}
          <div className="effect-build-status">{status}</div>
          {access?.cloudPublishEnabled && <div className="effect-build-status">Cloud · {cloudState.stage} · {cloudState.message}{cloudState.submissionId ? " · " + cloudState.submissionId : ""}</div>}
        </article>

        <article className="studio-panel sprite-pack-contract">
          <div className="studio-panel-heading"><h2>Generated Contract</h2><span>Read-only</span></div>
          <pre className="effect-json-preview">{definition ? JSON.stringify(definition, null, 2) : "// Convert one or more slots first"}</pre>
        </article>
      </section>
    </main>
  </div>;
}
