function clamp01(value) {
  return Math.max(0, Math.min(1, Number(value) || 0));
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

function channelToAlpha(channel, keyChannel) {
  const value = clamp01(channel / 255);
  const key = clamp01(keyChannel / 255);
  if (Math.abs(value - key) < 1e-6) return 0;
  if (value < key) return key <= 1e-6 ? 0 : (key - value) / key;
  return key >= 1 - 1e-6 ? 0 : (value - key) / (1 - key);
}

export function estimateColorToAlpha(red, green, blue, keyColor) {
  if (!keyColor) return 1;
  return clamp01(Math.max(
    channelToAlpha(red, Number(keyColor.red) || 0),
    channelToAlpha(green, Number(keyColor.green) || 0),
    channelToAlpha(blue, Number(keyColor.blue) || 0),
  ));
}

function recoverForegroundChannel(observed, key, alpha) {
  if (alpha <= 0.015) return 0;
  const recovered = (observed - key * (1 - alpha)) / alpha;
  return Math.max(0, Math.min(255, Math.round(recovered)));
}

/**
 * Cleanup V5 screen-color unmix.
 *
 * A threshold key can remove clean backdrop pixels, but generated/compressed video
 * often bakes the green screen into semi-transparent black hair, lace and motion-blur
 * edges. Those pixels are neither pure foreground nor pure background. V5 solves the
 * compositing equation per channel against the sampled key color to recover a new
 * foreground alpha/color, but only along a bounded frontier grown from true exterior
 * transparency. Genuine interior green details are therefore not globally keyed.
 *
 * This is intentionally skipped for FX/glow clips, whose colored translucent edges
 * must stay on the preserveGlow pipeline.
 */
export function unmixConnectedScreenColor(
  image,
  preset,
  { maxDistance = null } = {},
) {
  if (!image?.data || !Number.isFinite(image.width) || !Number.isFinite(image.height)) {
    return { unmixedPixels: 0, transparentPixels: 0, maxDistance: 0 };
  }
  if (!preset?.keyColor || preset.preserveGlow || preset.presetName !== "normal") {
    return { unmixedPixels: 0, transparentPixels: 0, maxDistance: 0 };
  }

  const { data, width, height } = image;
  const pixelCount = width * height;
  const exterior = new Uint8Array(pixelCount);
  const distance = new Int16Array(pixelCount);
  distance.fill(-1);
  const queue = new Int32Array(pixelCount);
  let head = 0;
  let tail = 0;

  const enqueueExterior = (pixel) => {
    if (pixel < 0 || pixel >= pixelCount || exterior[pixel]) return;
    if (data[pixel * 4 + 3] > 20) return;
    exterior[pixel] = 1;
    distance[pixel] = 0;
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

  while (head < tail) {
    const pixel = queue[head++];
    forEachNeighbour(width, height, pixel, (next) => enqueueExterior(next));
  }

  const shadowStrength = clamp01((Number(preset.shadowCut) || 0) / 100);
  const configuredDistance = Number.isFinite(Number(maxDistance))
    ? Math.max(1, Math.min(16, Math.round(Number(maxDistance))))
    : 5 + Math.round(shadowStrength * 5); // 6..10 px for normal tuning.
  const key = {
    red: Math.max(0, Math.min(255, Number(preset.keyColor.red) || 0)),
    green: Math.max(0, Math.min(255, Number(preset.keyColor.green) || 255)),
    blue: Math.max(0, Math.min(255, Number(preset.keyColor.blue) || 0)),
  };

  // Reuse the queue as a frontier. Only exterior transparency and pixels that become
  // sufficiently transparent after unmixing are allowed to propagate farther inward.
  head = 0;
  tail = 0;
  for (let pixel = 0; pixel < pixelCount; pixel += 1) {
    if (exterior[pixel]) queue[tail++] = pixel;
  }

  let unmixedPixels = 0;
  let transparentPixels = 0;
  while (head < tail) {
    const sourcePixel = queue[head++];
    const sourceDistance = distance[sourcePixel];
    if (sourceDistance >= configuredDistance) continue;

    forEachNeighbour(width, height, sourcePixel, (pixel) => {
      if (distance[pixel] >= 0) return;
      const index = pixel * 4;
      const currentAlpha = data[index + 3];
      if (currentAlpha <= 20) {
        distance[pixel] = sourceDistance;
        queue[tail++] = pixel;
        return;
      }

      const red = data[index];
      const green = data[index + 1];
      const blue = data[index + 2];
      const estimatedForegroundAlpha = estimateColorToAlpha(red, green, blue, key);
      const currentOpacity = currentAlpha / 255;
      const screenContribution = 1 - estimatedForegroundAlpha;

      // Ignore colors that do not contain a meaningful amount of the sampled screen.
      // This protects genuine green/brown/black opaque details whose other channels
      // differ strongly from the key color.
      if (screenContribution < 0.055) return;
      if (estimatedForegroundAlpha >= currentOpacity - 0.025) return;

      let supportingExteriorNeighbours = 0;
      forEachNeighbour(width, height, pixel, (neighbour) => {
        const neighbourDistance = distance[neighbour];
        if (neighbourDistance >= 0 && neighbourDistance <= sourceDistance) supportingExteriorNeighbours += 1;
      });
      if (supportingExteriorNeighbours <= 0) return;

      // A small support bias makes one-pixel hair strands conservative while allowing
      // larger green-contaminated lace/background pockets to be reconstructed.
      const support = clamp01(supportingExteriorNeighbours / 3);
      const confidence = clamp01((screenContribution - 0.04) / 0.66) * (0.55 + support * 0.45);
      if (confidence < 0.05) return;

      const targetOpacity = Math.max(
        0,
        Math.min(currentOpacity, estimatedForegroundAlpha + (currentOpacity - estimatedForegroundAlpha) * (1 - confidence)),
      );
      const targetAlpha = targetOpacity < 0.045 ? 0 : Math.round(targetOpacity * 255);
      if (targetAlpha >= currentAlpha) return;

      const solveAlpha = Math.max(0.01, targetOpacity);
      data[index] = recoverForegroundChannel(red, key.red, solveAlpha);
      data[index + 1] = recoverForegroundChannel(green, key.green, solveAlpha);
      data[index + 2] = recoverForegroundChannel(blue, key.blue, solveAlpha);
      data[index + 3] = targetAlpha;
      unmixedPixels += 1;

      if (targetAlpha === 0) {
        data[index] = 0;
        data[index + 1] = 0;
        data[index + 2] = 0;
        transparentPixels += 1;
      }

      // Permit propagation through confidently reconstructed semi-transparent screen
      // contamination, but never through mostly-opaque model detail.
      if (targetAlpha <= 132 && confidence >= 0.14) {
        distance[pixel] = sourceDistance + 1;
        queue[tail++] = pixel;
      }
    });
  }

  return { unmixedPixels, transparentPixels, maxDistance: configuredDistance };
}
