const pairingCode = document.querySelector<HTMLElement>("#pairingCode");
const origin = document.querySelector<HTMLElement>("#origin");
const copy = document.querySelector<HTMLButtonElement>("#copy");
const status = document.querySelector<HTMLElement>("#status");

if (!pairingCode || !origin || !copy || !status) throw new Error("pairing_dom_invalid");

const value = new URLSearchParams(location.hash.slice(1)).get("pair");
const valid = typeof value === "string" && /^[A-Za-z0-9_-]{32}$/.test(value);
origin.textContent = location.origin;

if (valid) {
  pairingCode.textContent = value;
  copy.disabled = false;
  status.textContent = "This code expires after five minutes and can be used once.";
  history.replaceState(null, "", `${location.pathname}${location.search}`);
} else {
  status.textContent = "This link has no valid pairing code. Run the gateway’s --pair command for a fresh one.";
}

copy.addEventListener("click", async () => {
  if (!valid) return;
  try {
    await navigator.clipboard.writeText(`Gateway origin: ${location.origin}\nPairing code: ${value}`);
    status.textContent = "Setup details copied. Paste them into the Pi Voice native app.";
  } catch {
    status.textContent = "Copy was unavailable. Select the origin and code above manually.";
  }
});
