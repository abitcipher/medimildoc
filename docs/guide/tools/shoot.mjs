// Screenshots of the local copy for the user guide.
// node shoot.mjs <shots.json> <outdir>
// shots: [{file, email, path, width?, height?, full?, wait?, click?: [selector...], scroll?: selector}]
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import { createRequire } from "node:module"

const require = createRequire("/home/android/.npm/_npx/9833c18b2d85bc59/node_modules/")
const { chromium } = require("playwright")

const [, , shotsFile, outDir] = process.argv
const shots = JSON.parse(fs.readFileSync(shotsFile, "utf8"))
const base = "http://localhost:5085"
const cookies = {}
const cookie = (email) =>
  (cookies[email] ||= execFileSync(new URL("./cookie.sh", import.meta.url).pathname, [email])
    .toString()
    .trim())

const browser = await chromium.launch({ executablePath: "/home/android/.cache/ms-playwright/chromium-1243/chrome-linux64/chrome" })

for (const shot of shots) {
  const context = await browser.newContext({
    viewport: { width: shot.width || 1280, height: shot.height || 800 },
    deviceScaleFactor: 2,
    locale: "uk-UA",
    colorScheme: "light",
  })
  await context.addCookies([
    { name: "_app_key", value: cookie(shot.email), domain: "localhost", path: "/" },
  ])
  const page = await context.newPage()
  await page.goto(base + shot.path, { waitUntil: "load" })
  await page.waitForTimeout(shot.wait || 1200)
  for (const [sel, value] of shot.select || []) {
    await page.locator(sel).first().selectOption(value)
    await page.waitForTimeout(1500)
  }
  for (const sel of shot.click || []) {
    await page.locator(sel).first().click()
    await page.waitForTimeout(900)
  }
  if (shot.scroll) await page.locator(shot.scroll).first().scrollIntoViewIfNeeded()
  await page.screenshot({ path: `${outDir}/${shot.file}`, fullPage: !!shot.full })
  console.log("saved", shot.file)
  await context.close()
}

await browser.close()
