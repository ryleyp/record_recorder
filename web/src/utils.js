export function clamp(value, low, high) {
  return Math.min(Math.max(value, low), high);
}

export function formatTime(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) {
    return "00:00";
  }
  const rounded = Math.round(seconds);
  const hours = Math.floor(rounded / 3600);
  const minutes = Math.floor((rounded % 3600) / 60);
  const secs = rounded % 60;
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
  }
  return `${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
}

export function formatDB(value) {
  if (!Number.isFinite(value) || value <= -119) {
    return "-inf dB";
  }
  return `${value.toFixed(1)} dB`;
}

export function dbFromPeak(peak) {
  if (!Number.isFinite(peak) || peak <= 0) {
    return -120;
  }
  return Math.max(-120, 20 * Math.log10(peak));
}

export function meterPercent(db) {
  return clamp((db + 60) / 60, 0, 1) * 100;
}

export function sanitizeFileName(name, fallback = "Untitled") {
  const cleaned = String(name || fallback)
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[<>:"/\\|?*\x00-\x1f]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 120);
  return cleaned || fallback;
}

export function cleanTrackTitle(name, fallback = "Untitled Track", trackNumber = null) {
  const cleaned = String(name ?? "")
    .replace(/\s+/g, " ")
    .trim();
  const title = stripLeadingTrackNumber(cleaned, trackNumber);
  return title || fallback;
}

function stripLeadingTrackNumber(title, trackNumber) {
  const match = title.match(/^(track\s*)?([A-D])?\s*0*(\d{1,3})(\s*[\.):_\-\u2013\u2014]\s*|\s+)(.+)$/i);
  if (!match) return title;

  const hasTrackWord = Boolean(match[1]);
  const hasSideLabel = Boolean(match[2]);
  const number = Number(match[3]);
  const separator = match[4] || "";
  const rest = (match[5] || "").trim();
  if (!rest) return title;

  const expectedTrackNumber = Number(trackNumber);
  const expectedMatches = Number.isFinite(expectedTrackNumber) && Math.round(expectedTrackNumber) === number;
  const hasExplicitSeparator = /[\.):_\-\u2013\u2014]/.test(separator);
  return hasSideLabel || hasTrackWord || hasExplicitSeparator || expectedMatches ? rest : title;
}

export function downloadBlob(blob, fileName) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = fileName;
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function readFileAsDataURL(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

export function nextFrame() {
  return new Promise((resolve) => requestAnimationFrame(resolve));
}

export function uniqueId() {
  if (globalThis.crypto?.randomUUID) {
    return crypto.randomUUID();
  }
  return `id-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}
