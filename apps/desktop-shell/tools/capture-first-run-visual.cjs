/* eslint-disable @typescript-eslint/no-require-imports, no-undef, no-empty */
const fs = require('node:fs');
const path = require('node:path');
const { app, BrowserWindow } = require('electron');

function fail(message) {
  console.error(message);
  app.exit(1);
}

const [htmlPath, screenshotPath, widthRaw, heightRaw, scaleRaw = '1'] = process.argv.slice(2);
const width = Number(widthRaw);
const height = Number(heightRaw);
const scaleFactor = Number(scaleRaw);
if (!htmlPath || !screenshotPath || !Number.isFinite(width) || !Number.isFinite(height) || !Number.isFinite(scaleFactor) || scaleFactor < 1 || scaleFactor > 3) {
  console.error('usage: electron capture-first-run-visual.cjs <html> <png> <width> <height> [deviceScaleFactor]');
  process.exit(2);
}

if (process.env.OCP_VISUAL_USER_DATA) {
  fs.mkdirSync(path.resolve(process.env.OCP_VISUAL_USER_DATA), { recursive: true });
  app.setPath('userData', path.resolve(process.env.OCP_VISUAL_USER_DATA));
}
app.disableHardwareAcceleration();
app.commandLine.appendSwitch('force-device-scale-factor', String(scaleFactor));
app.commandLine.appendSwitch('disable-extensions');
app.commandLine.appendSwitch('no-first-run');

app.whenReady().then(async () => {
  const win = new BrowserWindow({
    show: false,
    frame: false,
    useContentSize: true,
    width,
    height,
    backgroundColor: '#020812',
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      offscreen: true,
      backgroundThrottling: false,
    },
  });

  try {
    await win.loadFile(path.resolve(htmlPath));
    await new Promise((resolve) => setTimeout(resolve, 120));
    const reportText = await win.webContents.executeJavaScript(
      "document.getElementById('ocp-visual-report')?.textContent || ''",
      true,
    );
    if (!reportText) throw new Error('visual report was not found in the fixture DOM');
    const image = await win.webContents.capturePage();
    fs.mkdirSync(path.dirname(path.resolve(screenshotPath)), { recursive: true });
    fs.writeFileSync(path.resolve(screenshotPath), image.toPNG());
    process.stdout.write(`OCP_VISUAL_REPORT=${reportText}\n`);
    process.stdout.write(`OCP_VISUAL_SCALE=${scaleFactor}\n`);
    process.stdout.write(`OCP_VISUAL_SCREENSHOT=${path.resolve(screenshotPath)}\n`);
    win.destroy();
    app.quit();
  } catch (error) {
    try { win.destroy(); } catch {}
    fail(error instanceof Error ? error.stack || error.message : String(error));
  }
}).catch((error) => fail(error instanceof Error ? error.stack || error.message : String(error)));
