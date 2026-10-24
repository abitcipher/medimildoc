// Raw CDP helper for the visible Chromium (port 9333).
// node cdp.mjs <target-url-substring> <command> [arg]
//   eval '<js>'            evaluate in the target, print the result
//   shot <file.png>        screenshot of the target
//   click '<selector|text>' click the first element matching selector (and text)
//   xy 'x,y'               mouse click at page coordinates
//   type '<text>'          insert text
//   key '<Key>'            press a key (Enter, Escape, Tab)
//   list                   list targets
import fs from "node:fs"

const [, , match, cmd, arg] = process.argv
const targets = await (await fetch("http://127.0.0.1:9333/json/list")).json()

if (match === "newwin") {
  // node cdp.mjs newwin <url> <w>x<h>: a new browser window; prints its target id.
  const version = await (await fetch("http://127.0.0.1:9333/json/version")).json()
  const bws = new WebSocket(version.webSocketDebuggerUrl)
  await new Promise((r) => (bws.onopen = r))
  const [w, h] = (arg || "1600x960").split("x").map(Number)
  bws.send(JSON.stringify({ id: 1, method: "Target.createTarget", params: { url: cmd, newWindow: true, width: w, height: h } }))
  const reply = await new Promise((r) => (bws.onmessage = (e) => r(JSON.parse(e.data))))
  console.log(reply.result?.targetId || JSON.stringify(reply))
  bws.close()
  process.exit(0)
}

if (cmd === "list" || match === "list") {
  for (const t of targets) console.log(t.type, t.id, t.url.slice(0, 140))
  process.exit(0)
}

// "id:<targetId>" picks a target by id (a window opened with newwin).
const target = match.startsWith("id:")
  ? targets.find((t) => t.id === match.slice(3))
  : targets.find((t) => t.url.includes(match) && t.webSocketDebuggerUrl)
if (!target) {
  console.error("no target matching", match)
  process.exit(2)
}

const ws = new WebSocket(target.webSocketDebuggerUrl)
let id = 0
const pending = new Map()
ws.onmessage = (e) => {
  const msg = JSON.parse(e.data)
  if (msg.id && pending.has(msg.id)) {
    pending.get(msg.id)(msg)
    pending.delete(msg.id)
  }
}
await new Promise((r) => (ws.onopen = r))
const send = (method, params = {}) =>
  new Promise((resolve) => {
    const n = ++id
    pending.set(n, resolve)
    ws.send(JSON.stringify({ id: n, method, params }))
  })

const evaluate = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })
  if (r.result?.exceptionDetails) return "EXC: " + JSON.stringify(r.result.exceptionDetails).slice(0, 400)
  return r.result?.result?.value
}

const clickAt = async (x, y) => {
  for (const type of ["mouseMoved", "mousePressed", "mouseReleased"])
    await send("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1 })
}

if (cmd === "eval") {
  const v = await evaluate(arg)
  console.log(typeof v === "string" ? v : JSON.stringify(v, null, 1))
} else if (cmd === "shot") {
  const r = await send("Page.captureScreenshot", { format: "png" })
  fs.writeFileSync(arg, Buffer.from(r.result.data, "base64"))
  console.log("saved", arg)
} else if (cmd === "click") {
  const [sel, text] = arg.split("|")
  const box = await evaluate(`(() => {
    const els = [...document.querySelectorAll(${JSON.stringify(sel)})]
    const el = els.find(e => ${JSON.stringify(text || "")} === "" || (e.innerText || e.textContent || "").includes(${JSON.stringify(text || "")}))
    if (!el) return null
    el.scrollIntoView({block: "center"})
    const r = el.getBoundingClientRect()
    return [r.x + r.width / 2, r.y + r.height / 2]
  })()`)
  if (!box) {
    console.log("not found")
  } else {
    await clickAt(box[0], box[1])
    console.log("clicked", box.map(Math.round).join(","))
  }
} else if (cmd === "xy") {
  const [x, y] = arg.split(",").map(Number)
  await clickAt(x, y)
  console.log("clicked", x, y)
} else if (cmd === "type") {
  await send("Input.insertText", { text: arg })
  console.log("typed")
} else if (cmd === "keys") {
  for (const ch of arg) {
    await send("Input.dispatchKeyEvent", { type: "keyDown", key: ch, text: ch, unmodifiedText: ch })
    await send("Input.dispatchKeyEvent", { type: "keyUp", key: ch })
  }
  console.log("keys typed")
} else if (cmd === "key") {
  const codes = { Enter: 13, Escape: 27, Tab: 9, ArrowDown: 40, ArrowUp: 38, Delete: 46, Backspace: 8 }
  for (const type of ["rawKeyDown", "keyUp"])
    await send("Input.dispatchKeyEvent", { type, key: arg, code: arg, windowsVirtualKeyCode: codes[arg] || 0, text: type === "rawKeyDown" && arg === "Enter" ? "\r" : undefined })
  console.log("key", arg)
}
ws.close()
process.exit(0)
