// The pairing page of one instance: the person confirms here, in this profile, under a name they give. A `label`
// in the address only prefills the field; nothing is paired until Confirm is pressed.

const field = document.getElementById("label");
const status = document.getElementById("status");
field.value = new URLSearchParams(location.search).get("label") ?? "";

chrome.storage.local.get("instanceId").then(({ instanceId }) => {
  document.getElementById("instance").textContent = instanceId ?? "(not made yet)";
});

document.getElementById("confirm").addEventListener("click", async () => {
  const answer = await chrome.runtime.sendMessage({ type: "confirmPairing", label: field.value });
  status.textContent = answer?.ok ? `Paired as ${answer.label}` : `Not paired: ${answer?.error ?? "no answer"}`;
});
