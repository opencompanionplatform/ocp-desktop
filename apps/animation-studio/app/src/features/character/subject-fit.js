export const SUBJECT_FIT_DEFAULTS = Object.freeze({
  targetWidthRatio: 0.88,
  targetHeightRatio: 0.92,
  paddingXRatio: 0.06,
  paddingTopRatio: 0.04,
  paddingBottomRatio: 0.025,
  maxUpscale: 2.5,
});

export const CHARACTER_STANDARDIZATION_DEFAULTS = Object.freeze({
  enabled: true,
  referenceAnimation: "idle",
  baselineRatio: 0.985,
  centerXRatio: 0.5,
  standingHeightTolerance: 0.035,
  minScaleCorrection: 0.78,
  maxScaleCorrection: 1.28,
  overflowAllowanceRatio: 0.04,
});

const STANDING_ANIMATIONS = new Set([
  "idle", "angry", "happy", "sad", "surprised", "speak", "think", "wake",
  "walk_left", "walk_right", "wave",
]);
const GROUND_ANIMATIONS = new Set(["sit", "sleep", "land"]);
const WALL_ANIMATIONS = new Set([
  "climb_up", "climb_down", "climb_top", "hang",
  "climb_up_left", "climb_up_right", "climb_down_left", "climb_down_right",
  "hang_left", "hang_right",
]);
const AIR_ANIMATIONS = new Set(["jump", "fall", "appear", "disappear"]);
const FX_CHARACTER_CORE_ANIMATIONS = new Set(["appear", "disappear"]);
const DISAPPEAR_MEASUREMENT_DEFAULTS = Object.freeze({
  startRatio: 0.10,
  endRatio: 0.40,
  minCoreAreaRatio: 0.70,
});
const CHARACTER_MEASUREMENT_OPTIONS_DEFAULTS = Object.freeze({
  minCoreAreaRatio: 0,
  sourceHeight: 0,
  referenceHeightRatio: 0,
});

export function poseGroupForAnimation(animationName) {
  if (GROUND_ANIMATIONS.has(animationName)) return "ground";
  if (WALL_ANIMATIONS.has(animationName)) return "wall";
  if (AIR_ANIMATIONS.has(animationName)) return "air";
  if (STANDING_ANIMATIONS.has(animationName)) return "standing";
  return "standing";
}

function finitePositive(value, fallback) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : fallback;
}

export function unionSubjectBounds(boundsList) {
  const valid = (boundsList ?? []).filter((bounds) => bounds
    && Number.isFinite(bounds.x)
    && Number.isFinite(bounds.y)
    && Number.isFinite(bounds.width)
    && Number.isFinite(bounds.height)
    && bounds.width > 0
    && bounds.height > 0);
  if (valid.length === 0) return null;

  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;
  for (const bounds of valid) {
    minX = Math.min(minX, bounds.x);
    minY = Math.min(minY, bounds.y);
    maxX = Math.max(maxX, bounds.x + bounds.width);
    maxY = Math.max(maxY, bounds.y + bounds.height);
  }
  return {
    x: minX,
    y: minY,
    width: Math.max(1, maxX - minX),
    height: Math.max(1, maxY - minY),
  };
}


export function usesCharacterCoreMeasurement(animationName) {
  return FX_CHARACTER_CORE_ANIMATIONS.has(String(animationName || "").toLowerCase());
}

export function measurementWindowForAnimation(animationName) {
  const normalizedName = String(animationName || "").toLowerCase();
  if (normalizedName === "disappear") {
    return {
      startRatio: DISAPPEAR_MEASUREMENT_DEFAULTS.startRatio,
      endRatio: DISAPPEAR_MEASUREMENT_DEFAULTS.endRatio,
    };
  }
  return { startRatio: 0, endRatio: 1 };
}

export function measureCharacterCoreAlphaBounds(imageData, {
  alphaThreshold = 48,
  rowMassRatio = 0.055,
  colMassRatio = 0.07,
  paddingRatio = 0.07,
  brightNeutralLuma = 210,
  brightNeutralSaturation = 0.24,
} = {}) {
  const pixels = imageData?.data;
  const width = Math.max(0, Math.round(Number(imageData?.width) || 0));
  const height = Math.max(0, Math.round(Number(imageData?.height) || 0));
  if (!pixels || width <= 0 || height <= 0 || pixels.length < width * height * 4) return null;

  const safeAlphaThreshold = Math.max(0, Math.min(254, Number(alphaThreshold) || 48));
  const safeRowMassRatio = Math.max(0.01, Math.min(0.5, Number(rowMassRatio) || 0.055));
  const safeColMassRatio = Math.max(0.01, Math.min(0.5, Number(colMassRatio) || 0.07));
  const safePaddingRatio = Math.max(0, Math.min(0.25, Number(paddingRatio) || 0.07));
  const safeBrightNeutralLuma = Math.max(0, Math.min(255, Number(brightNeutralLuma) || 210));
  const safeBrightNeutralSaturation = Math.max(0, Math.min(1, Number(brightNeutralSaturation) || 0.24));

  const rowMass = new Float64Array(height);
  const colMass = new Float64Array(width);
  let peakRow = 0;
  let peakCol = 0;

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      const index = (y * width + x) * 4;
      const alpha = pixels[index + 3];
      if (alpha <= safeAlphaThreshold) continue;

      const red = pixels[index];
      const green = pixels[index + 1];
      const blue = pixels[index + 2];
      const channelMax = Math.max(red, green, blue);
      const channelMin = Math.min(red, green, blue);
      const saturation = channelMax <= 0 ? 0 : (channelMax - channelMin) / channelMax;
      const luma = red * 0.2126 + green * 0.7152 + blue * 0.0722;
      const brightNeutralGlow = luma >= safeBrightNeutralLuma && saturation <= safeBrightNeutralSaturation;
      const veryBrightGlow = luma >= 232;
      const translucentLight = alpha < 220 && luma >= 150;
      const glowWeight = brightNeutralGlow ? 0.035 : (veryBrightGlow ? 0.08 : (translucentLight ? 0.18 : 1));
      const opacity = alpha / 255;
      const weight = alpha * opacity * glowWeight;

      rowMass[y] += weight;
      colMass[x] += weight;
    }
    peakRow = Math.max(peakRow, rowMass[y]);
  }
  for (let x = 0; x < width; x += 1) peakCol = Math.max(peakCol, colMass[x]);
  if (peakRow <= 0 || peakCol <= 0) return null;

  const significantSpan = (masses, peak, ratio) => {
    const threshold = peak * ratio;
    let first = -1;
    let last = -1;
    for (let index = 0; index < masses.length; index += 1) {
      if (masses[index] < threshold) continue;
      if (first < 0) first = index;
      last = index;
    }
    return first < 0 ? null : { start: first, end: last + 1 };
  };

  const xSpan = significantSpan(colMass, peakCol, safeColMassRatio);
  const ySpan = significantSpan(rowMass, peakRow, safeRowMassRatio);
  if (!xSpan || !ySpan) return null;

  const padX = Math.max(1, Math.round((xSpan.end - xSpan.start) * safePaddingRatio));
  const padY = Math.max(1, Math.round((ySpan.end - ySpan.start) * safePaddingRatio));
  const left = Math.max(0, xSpan.start - padX);
  const top = Math.max(0, ySpan.start - padY);
  const right = Math.min(width, xSpan.end + padX);
  const bottom = Math.min(height, ySpan.end + padY);

  return {
    x: left,
    y: top,
    width: Math.max(1, right - left),
    height: Math.max(1, bottom - top),
  };
}

/**
 * @param {Array<object | null | undefined>} boundsList
 * @param {string} animationName
 * @param {{ minCoreAreaRatio?: number, sourceHeight?: number, referenceHeightRatio?: number }} [options]
 */
export function selectCharacterMeasurementBounds(
  boundsList,
  animationName,
  options = CHARACTER_MEASUREMENT_OPTIONS_DEFAULTS,
) {
  const samples = boundsList ?? [];
  const valid = samples
    .map((bounds, sampleIndex) => ({ bounds, sampleIndex }))
    .filter(({ bounds }) => bounds
      && Number.isFinite(bounds.x)
      && Number.isFinite(bounds.y)
      && Number.isFinite(bounds.width)
      && Number.isFinite(bounds.height)
      && bounds.width > 0
      && bounds.height > 0);
  if (valid.length === 0) return null;
  if (!usesCharacterCoreMeasurement(animationName)) return unionSubjectBounds(valid.map(({ bounds }) => bounds));

  const normalizedName = String(animationName || "").toLowerCase();
  const maxArea = Math.max(...valid.map(({ bounds }) => bounds.width * bounds.height));
  const safeMinCoreAreaRatio = normalizedName === "disappear"
    ? Math.max(0, Math.min(1, Number(options.minCoreAreaRatio) || DISAPPEAR_MEASUREMENT_DEFAULTS.minCoreAreaRatio))
    : 0;
  const candidates = normalizedName === "disappear"
    ? valid.filter(({ bounds }) => bounds.width * bounds.height >= maxArea * safeMinCoreAreaRatio)
    : valid;

  const safeSourceHeight = finitePositive(options.sourceHeight, 0);
  const safeReferenceHeightRatio = finitePositive(options.referenceHeightRatio, 0);
  const hasReferenceHeight = normalizedName === "disappear"
    && safeSourceHeight > 0
    && safeReferenceHeightRatio > 0;
  const lastSampleIndex = Math.max(1, samples.length - 1);

  let best = candidates[0];
  let bestScore = -Infinity;
  for (const candidate of candidates) {
    const { bounds, sampleIndex } = candidate;
    const area = bounds.width * bounds.height;
    const areaScore = maxArea > 0 ? area / maxArea : 0;
    const aspect = bounds.height / Math.max(1, bounds.width);
    const shapeScore = Math.max(0.65, Math.min(1.35, aspect)) / 1.35;
    const earlyScore = 1 - (sampleIndex / lastSampleIndex);
    let score = areaScore * 0.78 + shapeScore * 0.12 + earlyScore * 0.10;

    if (hasReferenceHeight) {
      const currentHeightRatio = bounds.height / safeSourceHeight;
      const relativeDeviation = Math.abs(currentHeightRatio - safeReferenceHeightRatio) / safeReferenceHeightRatio;
      const referenceScore = 1 - Math.min(1, relativeDeviation);
      score = areaScore * 0.38 + referenceScore * 0.42 + earlyScore * 0.15 + shapeScore * 0.05;
    }

    if (score <= bestScore) continue;
    best = candidate;
    bestScore = score;
  }

  return {
    x: best.bounds.x,
    y: best.bounds.y,
    width: best.bounds.width,
    height: best.bounds.height,
  };
}

export function computeSubjectPlacement(bounds, frameWidth, frameHeight, options = {}) {
  if (!bounds) return null;
  const width = finitePositive(frameWidth, 512);
  const height = finitePositive(frameHeight, 512);
  const settings = { ...SUBJECT_FIT_DEFAULTS, ...options };

  const padX = bounds.width * settings.paddingXRatio;
  const padTop = bounds.height * settings.paddingTopRatio;
  const padBottom = bounds.height * settings.paddingBottomRatio;
  const cropX = Math.max(0, bounds.x - padX);
  const cropY = Math.max(0, bounds.y - padTop);
  const cropRight = Math.min(width, bounds.x + bounds.width + padX);
  const cropBottom = Math.min(height, bounds.y + bounds.height + padBottom);
  const cropWidth = Math.max(1, cropRight - cropX);
  const cropHeight = Math.max(1, cropBottom - cropY);

  const widthScale = (width * settings.targetWidthRatio) / cropWidth;
  const heightScale = (height * settings.targetHeightRatio) / cropHeight;
  const fitScale = Math.min(widthScale, heightScale);
  // Portrait sources that already fill the 512x512 authoring cell should keep
  // their current character size. Only small subjects are enlarged.
  const scale = Math.min(settings.maxUpscale, Math.max(1, fitScale));
  const drawWidth = cropWidth * scale;
  const drawHeight = cropHeight * scale;

  return {
    cropX,
    cropY,
    cropWidth,
    cropHeight,
    drawX: (width - drawWidth) / 2,
    drawY: height - drawHeight,
    drawWidth,
    drawHeight,
    scale,
    applied: scale > 1.01,
  };
}

export function computeSourceCropPlacement(bounds, sourceWidth, sourceHeight, targetWidth, targetHeight, options = {}) {
  if (!bounds) return null;
  const sourceW = finitePositive(sourceWidth, targetWidth || 512);
  const sourceH = finitePositive(sourceHeight, targetHeight || 512);
  const targetW = finitePositive(targetWidth, 512);
  const targetH = finitePositive(targetHeight, 512);
  const settings = {
    targetWidthRatio: 0.92,
    targetHeightRatio: 0.96,
    paddingXRatio: 0.02,
    paddingTopRatio: 0.012,
    paddingBottomRatio: 0.01,
    maxUpscale: 4,
    ...options,
  };

  const padX = bounds.width * settings.paddingXRatio;
  const padTop = bounds.height * settings.paddingTopRatio;
  const padBottom = bounds.height * settings.paddingBottomRatio;
  const cropX = Math.max(0, bounds.x - padX);
  const cropY = Math.max(0, bounds.y - padTop);
  const cropRight = Math.min(sourceW, bounds.x + bounds.width + padX);
  const cropBottom = Math.min(sourceH, bounds.y + bounds.height + padBottom);
  const cropWidth = Math.max(1, cropRight - cropX);
  const cropHeight = Math.max(1, cropBottom - cropY);

  const scale = Math.min(
    settings.maxUpscale,
    (targetW * settings.targetWidthRatio) / cropWidth,
    (targetH * settings.targetHeightRatio) / cropHeight,
  );
  const drawWidth = cropWidth * scale;
  const drawHeight = cropHeight * scale;

  return {
    cropX,
    cropY,
    cropWidth,
    cropHeight,
    drawX: (targetW - drawWidth) / 2,
    drawY: targetH - drawHeight,
    drawWidth,
    drawHeight,
    scale,
    sourceWidth: sourceW,
    sourceHeight: sourceH,
    applied: true,
  };
}


export function createCharacterMasterProfile(
  referenceBounds,
  sourceWidth,
  sourceHeight,
  targetWidth = 512,
  targetHeight = 512,
  options = {},
) {
  if (!referenceBounds) return null;
  const sourceW = finitePositive(sourceWidth, targetWidth);
  const sourceH = finitePositive(sourceHeight, targetHeight);
  const targetW = finitePositive(targetWidth, 512);
  const targetH = finitePositive(targetHeight, 512);
  const settings = { ...CHARACTER_STANDARDIZATION_DEFAULTS, ...options };
  const placement = computeSourceCropPlacement(referenceBounds, sourceW, sourceH, targetW, targetH, options);
  if (!placement) return null;

  return {
    version: 1,
    referenceAnimation: String(settings.referenceAnimation || "idle"),
    referenceWidthRatio: referenceBounds.width / sourceW,
    referenceHeightRatio: referenceBounds.height / sourceH,
    normalizedSourceScale: placement.scale * sourceH / targetH,
    baselineRatio: Number(settings.baselineRatio),
    centerXRatio: Number(settings.centerXRatio),
    standingHeightTolerance: Number(settings.standingHeightTolerance),
    minScaleCorrection: Number(settings.minScaleCorrection),
    maxScaleCorrection: Number(settings.maxScaleCorrection),
    overflowAllowanceRatio: Number(settings.overflowAllowanceRatio),
  };
}


export function computeStandardizedSourcePlacement(
  bounds,
  sourceWidth,
  sourceHeight,
  targetWidth,
  targetHeight,
  masterProfile,
  animationName,
  options = {},
) {
  if (!bounds || !masterProfile) return null;
  const sourceW = finitePositive(sourceWidth, targetWidth || 512);
  const sourceH = finitePositive(sourceHeight, targetHeight || 512);
  const targetW = finitePositive(targetWidth, 512);
  const targetH = finitePositive(targetHeight, 512);
  const settings = { ...CHARACTER_STANDARDIZATION_DEFAULTS, ...masterProfile, ...options };
  const normalizedName = String(animationName || "").toLowerCase();
  const poseGroup = poseGroupForAnimation(animationName);

  const lockedNormalizedSourceScale = finitePositive(options.lockedNormalizedSourceScale, 0);
  const pairScaleLocked = lockedNormalizedSourceScale > 0;
  let scale = (pairScaleLocked ? lockedNormalizedSourceScale : finitePositive(settings.normalizedSourceScale, 1)) * targetH / sourceH;
  let correction = 1;
  const currentHeightRatio = Math.max(1 / sourceH, bounds.height / sourceH);
  const referenceHeightRatio = finitePositive(settings.referenceHeightRatio, currentHeightRatio);
  const useReferenceHeightCorrection = !pairScaleLocked && (poseGroup === "standing"
    || poseGroup === "wall"
    || normalizedName === "disappear");
  if (useReferenceHeightCorrection) {
    const rawCorrection = referenceHeightRatio / currentHeightRatio;
    const tolerance = Math.max(0, Number(settings.standingHeightTolerance) || 0);
    if (Math.abs(rawCorrection - 1) > tolerance) {
      correction = Math.max(
        finitePositive(settings.minScaleCorrection, 0.78),
        Math.min(finitePositive(settings.maxScaleCorrection, 1.28), rawCorrection),
      );
      scale *= correction;
    }
  }

  const overflowAllowance = Math.max(0, Number(settings.overflowAllowanceRatio) || 0);
  const safetyWidth = targetW * (1 + overflowAllowance);
  const safetyHeight = targetH * (1 + overflowAllowance);
  const safetyScale = Math.min(
    safetyWidth / Math.max(1, bounds.width),
    safetyHeight / Math.max(1, bounds.height),
  );
  const safetyLimited = scale > safetyScale;
  scale = Math.min(scale, safetyScale);

  const sourceAnchorX = bounds.x + bounds.width / 2;
  const sourceAnchorY = bounds.y + bounds.height;
  const targetAnchorX = targetW * Number(settings.centerXRatio || 0.5);
  const targetAnchorY = targetH * Number(settings.baselineRatio || 0.985);
  const drawWidth = sourceW * scale;
  const drawHeight = sourceH * scale;

  return {
    cropX: 0,
    cropY: 0,
    cropWidth: sourceW,
    cropHeight: sourceH,
    drawX: targetAnchorX - sourceAnchorX * scale,
    drawY: targetAnchorY - sourceAnchorY * scale,
    drawWidth,
    drawHeight,
    scale,
    sourceWidth: sourceW,
    sourceHeight: sourceH,
    applied: true,
    standardized: true,
    poseGroup,
    correction,
    pairScaleLocked,
    safetyLimited,
    referenceAnimation: settings.referenceAnimation || "idle",
  };
}


export function characterScaleDeviation(placement, masterProfile, sourceHeight, targetHeight = 512) {
  if (!placement || !masterProfile) return null;
  const sourceH = finitePositive(sourceHeight, targetHeight);
  const targetH = finitePositive(targetHeight, 512);
  const expected = finitePositive(masterProfile.normalizedSourceScale, 1) * targetH / sourceH;
  if (expected <= 0) return null;
  return (Number(placement.scale) / expected) - 1;
}
