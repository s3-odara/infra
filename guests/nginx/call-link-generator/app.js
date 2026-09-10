"use strict";

const form = document.getElementById("generator");
const roomInput = document.getElementById("room");
const nameInput = document.getElementById("name");
const viaInput = document.getElementById("via");
const encryptedInput = document.getElementById("encrypted");
const result = document.getElementById("result");
const output = document.getElementById("output");
const openLink = document.getElementById("open");
const copyButton = document.getElementById("copy");
const error = document.getElementById("error");

function parseRoom(value) {
  const input = value.trim();
  if (input.startsWith("!")) return { roomId: input, via: null };

  let url;
  try {
    url = new URL(input);
  } catch {
    throw new Error("room IDまたは有効なmatrix.to URLを入力してください。");
  }

  if (url.hostname !== "matrix.to" || !url.hash.startsWith("#/")) {
    throw new Error("対応しているURLはmatrix.toリンクだけです。");
  }

  const fragment = url.hash.slice(2);
  const separator = fragment.indexOf("?");
  const encodedId = separator === -1 ? fragment : fragment.slice(0, separator);
  const query = separator === -1 ? "" : fragment.slice(separator + 1);
  const roomId = decodeURIComponent(encodedId);
  const via = new URLSearchParams(query).get("via");
  return { roomId, via };
}

function validateRoomId(roomId) {
  if (!roomId.startsWith("!") || !roomId.includes(":")) {
    throw new Error("room aliasではなく、!で始まる内部room IDを指定してください。");
  }
  if (/\s/.test(roomId)) {
    throw new Error("room IDに空白を含めることはできません。");
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  result.hidden = true;
  error.hidden = true;

  try {
    const parsed = parseRoom(roomInput.value);
    validateRoomId(parsed.roomId);

    const via = viaInput.value.trim() || parsed.via || parsed.roomId.split(":").slice(1).join(":");
    if (!via || /[\s/]/.test(via)) {
      throw new Error("有効なhomeserver名を指定してください。");
    }

    const params = new URLSearchParams();
    params.set("roomId", parsed.roomId);
    params.set("viaServers", via);
    if (encryptedInput.checked) params.set("perParticipantE2EE", "true");

    const target = new URL("/room/", window.location.origin);
    const displayName = nameInput.value.trim() || "通話";
    target.hash = `/${encodeURIComponent(displayName)}?${params.toString()}`;

    output.value = target.href;
    openLink.href = target.href;
    openLink.textContent = target.href;
    result.hidden = false;
  } catch (caught) {
    error.textContent = caught instanceof Error ? caught.message : "リンクを作成できませんでした。";
    error.hidden = false;
  }
});

copyButton.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(output.value);
    copyButton.textContent = "コピーしました";
    window.setTimeout(() => {
      copyButton.textContent = "コピー";
    }, 1500);
  } catch {
    output.select();
    document.execCommand("copy");
  }
});
