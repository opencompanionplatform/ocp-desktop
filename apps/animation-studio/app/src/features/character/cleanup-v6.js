function clamp01(value) {
  return Math.max(0, Math.min(1, Number(value) || 0));
}

function rgbDistance(red, green, blue, key) {
  const dr = red - key.red;
  const dg = green - key.green;
  const db = blue - key.blue;
  return Math.sqrt(dr * dr + dg * dg + db * db);
}

function colorToAlpha(red, green, blue, key) {
  const channelAlpha = (channel, keyChannel) => {
    if (channel >= keyChannel) {
      return keyChannel >= 255 ? 0 : (channel - keyChannel) / Math.max(1, 255 - keyChannel);
    }
    return keyChannel <= 0 ? 0 : (keyChannel - channel) / Math.max(1, keyChannel);
  };
  return clamp01(Math.max(
    channelAlpha(red, key.red),
    channelAlpha(green, key.green),
    channelAlpha(blue, key.blue),
  ));
}

function recoverChannel(observed, key, alpha) {
  if (alpha <= 0.001) return 0;
  return Math.max(0, Math.min(255, Math.round((observed - key * (1 - alpha)) / alpha)));
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

export function estimateEdgeBackgroundKey(data, width, height, { edgeFraction = 0.18, bucketSize = 8 } = {}) {
  if (!data || !width || !height) return null;
  const edgeBand = Math.max(2, Math.round(Math.min(width, height) * edgeFraction));
  /** @type {Map<string, { count: number, red: number, green: number, blue: number }>} */
  const buckets = new Map();
  let eligible = 0;

  const sample = (x, y) => {
    const index = (y * width + x) * 4;
    if ((data[index + 3] ?? 255) < 200) return;
    const red = data[index];
    const green = data[index + 1];
    const blue = data[index + 2];
    const qr = Math.floor(red / bucketSize);
    const qg = Math.floor(green / bucketSize);
    const qb = Math.floor(blue / bucketSize);
    const key = `${qr}:${qg}:${qb}`;
    const bucket = buckets.get(key) ?? { count: 0, red: 0, green: 0, blue: 0 };
    bucket.count += 1;
    bucket.red += red;
    bucket.green += green;
    bucket.blue += blue;
    buckets.set(key, bucket);
    eligible += 1;
  };

  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (x >= edgeBand && x < width - edgeBand && y >= edgeBand && y < height - edgeBand) continue;
      sample(x, y);
    }
  }

  const rankedBuckets = [...buckets.values()].sort((left, right) => right.count - left.count);
  const best = rankedBuckets[0];
  if (!best || best.count < Math.max(8, eligible * 0.05)) return null;

  return {
    red: best.red / best.count,
    green: best.green / best.count,
    blue: best.blue / best.count,
    confidence: eligible > 0 ? best.count / eligible : 0,
  };
}

export function isClassicGreenKey(keyColor) {
  if (!keyColor) return false;
  const { red, green, blue } = keyColor;
  const maxRedBlue = Math.max(red, blue);
  const minChannel = Math.min(red, green, blue);
  const maxChannel = Math.max(red, green, blue);
  const saturation = maxChannel <= 0 ? 0 : (maxChannel - minChannel) / maxChannel;
  return green >= 45 && green - maxRedBlue >= 18 && green >= red * 1.28 && green >= blue * 1.22 && saturation >= 0.35;
}

/**
 * Auto matte for a flat solid background of any color (gray, white, blue, etc.).
 * It samples one solid key color, grows only from the exterior canvas border, then
 * uses color-to-alpha to recover antialiased hair/lace instead of treating every
 * foreground edge as opaque. This is intentionally skipped for FX/glow clips.
 */
export function autoSolidBackgroundMatte(image, preset) {
  if (!image?.data || !preset?.keyColor) {
    return { removedPixels: 0, softenedPixels: 0, keyColor: preset?.keyColor ?? null };
  }

  const { data, width, height } = image;
  const key = preset.keyColor;
  const pixelCount = width * height;
  const distance = new Int16Array(pixelCount);
  distance.fill(-1);
  const queue = new Int32Array(pixelCount);
  let head = 0;
  let tail = 0;

  const cut = clamp01((Number(preset.chromaSensitivity) || 50) / 100);
  const tolerance = clamp01((Number(preset.keyTolerance) || 45) / 100);
  const preserveGlow = Boolean(preset.preserveGlow || preset.presetName === "fx");
  const hardDistance = 5 + cut * 10 + tolerance * 4;
  const softDistance = hardDistance + 10 + tolerance * 18;
  const maxDistance = 4 + Math.round(tolerance * 3);
  // FX sources such as Appear/Disappear often contain pale semi-transparent light
  // over a neutral gray/white backdrop. Keep much fainter color-to-alpha edges
  // than a normal character matte while still removing pixels that match the key.
  const hardAlphaCut = preserveGlow ? 0.045 : 0.18;
  const softAlphaCut = preserveGlow ? 0.995 : 0.94;
  const propagationAlpha = preserveGlow ? 0.08 : 0.30;
  const opaqueStopAlpha = preserveGlow ? 0.985 : 0.90;

  const qualifiesAsSeed = (pixel) => {
    const index = pixel * 4;
    if (data[index + 3] <= 20) return true;
    return rgbDistance(data[index], data[index + 1], data[index + 2], key) <= softDistance;
  };

  const enqueueSeed = (pixel) => {
    if (pixel < 0 || pixel >= pixelCount || distance[pixel] >= 0 || !qualifiesAsSeed(pixel)) return;
    distance[pixel] = 0;
    queue[tail++] = pixel;
  };

  for (let x = 0; x < width; x += 1) {
    enqueueSeed(x);
    enqueueSeed((height - 1) * width + x);
  }
  for (let y = 0; y < height; y += 1) {
    enqueueSeed(y * width);
    enqueueSeed(y * width + width - 1);
  }

  let removedPixels = 0;
  let softenedPixels = 0;
  while (head < tail) {
    const pixel = queue[head++];
    const pixelDistance = distance[pixel];
    const index = pixel * 4;
    const currentAlpha = data[index + 3];
    const red = data[index];
    const green = data[index + 1];
    const blue = data[index + 2];
    const distanceToKey = rgbDistance(red, green, blue, key);
    const estimatedAlpha = colorToAlpha(red, green, blue, key);

    let targetAlpha = currentAlpha;
    if (distanceToKey <= hardDistance || estimatedAlpha <= hardAlphaCut) {
      targetAlpha = 0;
    } else if (distanceToKey <= softDistance || estimatedAlpha < softAlphaCut) {
      targetAlpha = Math.min(currentAlpha, Math.round(estimatedAlpha * 255));
    }

    if (targetAlpha < currentAlpha) {
      if (targetAlpha <= 10) {
        data[index] = 0;
        data[index + 1] = 0;
        data[index + 2] = 0;
        data[index + 3] = 0;
        removedPixels += 1;
      } else {
        const alpha = targetAlpha / 255;
        data[index] = recoverChannel(red, key.red, alpha);
        data[index + 1] = recoverChannel(green, key.green, alpha);
        data[index + 2] = recoverChannel(blue, key.blue, alpha);
        data[index + 3] = targetAlpha;
        softenedPixels += 1;
      }
    }

    forEachNeighbour(width, height, pixel, (next) => {
      if (distance[next] >= 0) return;
      const nextIndex = next * 4;
      const nextAlpha = data[nextIndex + 3];
      const nextDistanceToKey = rgbDistance(data[nextIndex], data[nextIndex + 1], data[nextIndex + 2], key);
      const nextEstimatedAlpha = colorToAlpha(data[nextIndex], data[nextIndex + 1], data[nextIndex + 2], key);

      // Background core propagates without a distance limit. Only the transition
      // from background into semi-transparent subject edges is bounded.
      const backgroundCore = nextAlpha <= 20
        || nextDistanceToKey <= softDistance
        || nextEstimatedAlpha <= propagationAlpha;
      if (backgroundCore) {
        distance[next] = 0;
        queue[tail++] = next;
        return;
      }

      if (pixelDistance >= maxDistance || nextEstimatedAlpha > opaqueStopAlpha) return;
      distance[next] = pixelDistance + 1;
      queue[tail++] = next;
    });
  }

  // Remove completely flat enclosed background holes only when they are essentially
  // identical to the sampled key. This keeps gray/white costume details intact.
  const enclosedCut = clamp01((Number(preset.interiorCut) || 0) / 100);
  if (enclosedCut > 0) {
    const enclosedDistance = Math.max(2.5, hardDistance * 0.45);
    for (let pixel = 0; pixel < pixelCount; pixel += 1) {
      const index = pixel * 4;
      if (data[index + 3] <= 20) continue;
      if (rgbDistance(data[index], data[index + 1], data[index + 2], key) > enclosedDistance) continue;
      const nextAlpha = Math.round(data[index + 3] * (1 - enclosedCut));
      data[index + 3] = nextAlpha < 12 ? 0 : nextAlpha;
      if (data[index + 3] === 0) {
        data[index] = 0;
        data[index + 1] = 0;
        data[index + 2] = 0;
        removedPixels += 1;
      }
    }
  }

  return { removedPixels, softenedPixels, keyColor: key };
}
