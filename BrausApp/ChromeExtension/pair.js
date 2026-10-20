// The pairing page of this profile's instance: the person confirms here under a name, or revokes.

const field = document.getElementById("label");
const status = document.getElementById("status");

async function show() {
  const answer = await chrome.runtime.sendMessage({ type: "status" });
  document.getElementById("instance").textContent = answer?.instanceId ?? "(not made yet)";
  if (answer?.label) field.value = answer.label;
  status.textContent = answer?.label
    ? `Paired as ${answer.label}; ${answer.connected ? "connected to Braus" : "Braus not reached"}`
    : "Not paired";
}

document.getElementById("confirm").addEventListener("click", async () => {
  const answer = await chrome.runtime.sendMessage({ type: "confirmPairing", label: field.value });
  status.textContent = answer?.ok ? `Paired as ${answer.label}` : `Not paired: ${answer?.error ?? "no answer"}`;
});

document.getElementById("revoke").addEventListener("click", async () => {
  const answer = await chrome.runtime.sendMessage({ type: "revokePairing" });
  status.textContent = answer?.ok ? "Revoked: Braus no longer acts in this profile" : `Not revoked: ${answer?.error}`;
});

show();
