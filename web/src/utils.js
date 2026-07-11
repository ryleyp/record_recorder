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
