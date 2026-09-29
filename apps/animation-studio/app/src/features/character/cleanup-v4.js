function clamp01(value) {
  return Math.max(0, Math.min(1, Number(value) || 0));
}

function saturation(red, green, blue) {
  const maxChannel = Math.max(red, green, blue);
  const minChannel = Math.min(red, green, blue);
  return maxChannel <= 0 ? 0 : (maxChannel - minChannel) / maxChannel;
}

function normalizedColorDistance(red, green, blue, keyColor) {
  const sum = Math.max(1, red + green + blue);
  const keySum = Math.max(1, keyColor.red + keyColor.green + keyColor.blue);
  const dr = red / sum - keyColor.red / keySum;
  const dg = green / sum - keyColor.green / keySum;
  const db = blue / sum - keyColor.blue / keySum;
  return Math.sqrt(dr * dr + dg * dg + db * db);
}

function forEachNeighbour(width, height, pixel, callback) {
  const x = pixel % width;
  const y = Math.floor(pixel / width);
  for (let oy = -1; oy <= 1; oy += 1) {
    const ny = y + oy;
    if (ny < 0 || ny >= height) continue;
    for (let ox = -1; ox <= 1; ox += 1) {
      if (ox === 0 && oy === 0) continue;
      const nx = x + ox;
      if (nx < 0 || nx >= width) continue;
      callback(ny * width + nx);
    }
  }
}

/**
 * Cleanup V4 adaptive shadow recovery.
 *
 * V3 deliberately protects dark foreground detail before the connected chroma key.
 * Compressed green-screen shadows can occasionally look dark enough to enter that
 * protection mask and survive as a green fringe. V4 starts only from transparency
 * that is connected to the canvas exterior, then walks a small bounded distance into
 * strongly green neighbours. A protected pixel can be overridden only by a stricter
 * green test, so neutral black/brown hair and clothing remain protected.
 *
 * FX/glow clips are intentionally excluded; their translucent green/cyan light must
 * keep the V3 preserveGlow path.
 */
export function adaptiveConnectedGreenShadowCleanup(
  image,
  preset,
  { foregroundCoreMask = null } = {},
) {
  if (!image?.data || !Number.isFinite(image.width) || !Number.isFinite(image.height)) {
    return { removedPixels: 0, softenedPixels: 0, maxDistance: 0 };
  }
  if (!preset?.keyColor || preset.preserveGlow || preset.presetName !== "normal") {
    return { removedPixels: 0, softenedPixels: 0, maxDistance: 0 };
  }

  const shadowStrength = clamp01((Number(preset.shadowCut) || 0) / 100);
  if (shadowStrength < 0.25) return { removedPixels: 0, softenedPixels: 0, maxDistance: 0 };

  const { data, width, height } = image;
  const pixelCount = width * height;
  const exterior = new Uint8Array(pixelCount);
  const distanceFromExterior = new Int16Array(pixelCount);
  distanceFromExterior.fill(-1);
  const queue = new Int32Array(pixelCount);
  let head = 0;
  let tail = 0;

  const enqueueExterior = (pixel) => {
    if (pixel < 0 || pixel >= pixelCount || exterior[pixel]) return;
    const alpha = data[pixel * 4 + 3];
    if (alpha > 20) return;
    exterior[pixel] = 1;
    distanceFromExterior[pixel] = 0;
    queue[tail++] = pixel;
  };

  for (let x = 0; x < width; x += 1) {
    enqueueExterior(x);
    enqueueExterior((height - 1) * width + x);
  }
  for (let y = 0; y < height; y += 1) {
    enqueueExterior(y * width);
    enqueueExterior(y * width + width - 1);
  }

  // First establish only genuinely exterior transparent background. Enclosed holes
  // are not seeds, preventing V4 from spreading out of a keyed hole into green
  // clothing/accessories inside the silhouette.
  while (head < tail) {
    const pixel = queue[head++];
    forEachNeighbour(width, height, pixel, (next) => enqueueExterior(next));
  }

  const maxDistance = 2 + Math.round(shadowStrength * 4); // 3..6 px, bounded.
  const baseTolerance = 0.04 + clamp01((Number(preset.keyTolerance) || 0) / 100) * 0.26;
  const relaxedTolerance = baseTolerance * (1.7 + shadowStrength * 1.1);
  const minGreenShare = 0.42 - shadowStrength * 0.045;
  const minDominance = 5 - shadowStrength * 3;
  const minSaturation = Math.max(0.08, (Number(preset.minKeySaturation) || 0.1) * 0.34);

  // Reuse the queue, now as a breadth-first frontier from exterior transparency.
  head = 0;
  tail = 0;
  for (let pixel = 0; pixel < pixelCount; pixel += 1) {
    if (exterior[pixel]) queue[tail++] = pixel;
  }

  let removedPixels = 0;
  let softenedPixels = 0;
  while (head < tail) {
    const sourcePixel = queue[head++];
    const sourceDistance = distanceFromExterior[sourcePixel];
    if (sourceDistance >= maxDistance) continue;

    forEachNeighbour(width, height, sourcePixel, (pixel) => {
      if (distanceFromExterior[pixel] >= 0) return;
      const index = pixel * 4;
      const alpha = data[index + 3];
      if (alpha <= 20) {
        distanceFromExterior[pixel] = sourceDistance;
        queue[tail++] = pixel;
        return;
      }

      const red = data[index];
      const green = data[index + 1];
      const blue = data[index + 2];
      const maxRedBlue = Math.max(red, blue);
      const dominance = green - maxRedBlue;
      const sum = Math.max(1, red + green + blue);
      const greenShare = green / sum;
      const pixelSaturation = saturation(red, green, blue);
      if (dominance < minDominance || greenShare < minGreenShare || pixelSaturation < minSaturation) return;
      if (green <= red * 1.08 || green <= blue * 1.045) return;

      const colorDistance = normalizedColorDistance(red, green, blue, preset.keyColor);
      const compressedDarkGreen = greenShare >= 0.47
        && dominance >= 5
        && green > red * 1.18
        && green > blue * 1.08;
      if (!compressedDarkGreen && colorDistance > relaxedTolerance) return;

      // V3's foreground protection may have caught a dark screen shadow. Override it
      // only when the pixel is unmistakably green and immediately reachable from the
      // exterior matte; neutral/brown/black foreground remains protected.
      if (foregroundCoreMask?.[pixel]) {
        const safeOverride = greenShare >= 0.50
          && dominance >= 7
          && green > red * 1.22
          && green > blue * 1.10;
        if (!safeOverride) return;
      }

      let exteriorNeighbours = 0;
      forEachNeighbour(width, height, pixel, (neighbour) => {
        const neighbourDistance = distanceFromExterior[neighbour];
        if (neighbourDistance >= 0 && neighbourDistance <= sourceDistance) exteriorNeighbours += 1;
      });
      if (exteriorNeighbours <= 0) return;

      const shareWeight = clamp01((greenShare - minGreenShare) / 0.20);
      const dominanceWeight = clamp01((dominance - minDominance) / 24);
      const colorWeight = compressedDarkGreen
        ? Math.max(0.72, clamp01(1 - colorDistance / Math.max(0.001, relaxedTolerance)))
        : clamp01(1 - colorDistance / Math.max(0.001, relaxedTolerance));
      const supportWeight = clamp01(exteriorNeighbours / 3);
      const confidence = Math.max(shareWeight, dominanceWeight) * colorWeight * (0.55 + supportWeight * 0.45);
      if (confidence < 0.24) return;

      const nextDistance = sourceDistance + 1;
      const hardRemove = (compressedDarkGreen && exteriorNeighbours >= 2 && confidence >= 0.38)
        || confidence >= 0.62;
      let nextAlpha = hardRemove
        ? 0
        : Math.round(alpha * (1 - Math.min(0.88, (0.28 + shadowStrength * 0.42) * confidence)));
      if (nextAlpha < 24) nextAlpha = 0;
      if (nextAlpha >= alpha) return;

      data[index + 3] = nextAlpha;
      if (nextAlpha === 0) {
        data[index] = 0;
        data[index + 1] = 0;
        data[index + 2] = 0;
        removedPixels += 1;
      } else {
        softenedPixels += 1;
      }

      // Only sufficiently background-like pixels may become a growth frontier. A
      // partially softened hair edge therefore cannot pull V4 farther into the model.
      if (nextAlpha <= 72 || (hardRemove && compressedDarkGreen)) {
        distanceFromExterior[pixel] = nextDistance;
        queue[tail++] = pixel;
      }
    });
  }

  return { removedPixels, softenedPixels, maxDistance };
}
