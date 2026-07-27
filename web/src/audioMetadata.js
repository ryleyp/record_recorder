export function createId3Tag(metadata) {
  const frames = [];
  appendTextFrame(frames, "TIT2", metadata.title);
  appendTextFrame(frames, "TPE1", metadata.artist || metadata.albumArtist);
  appendTextFrame(frames, "TALB", metadata.albumTitle);
  appendTextFrame(frames, "TPE2", metadata.albumArtist || metadata.artist);
  appendTextFrame(frames, "TYER", metadata.year);
  appendTextFrame(frames, "TDRC", metadata.year);
  appendTextFrame(frames, "TCON", metadata.genre);
  appendTextFrame(frames, "TRCK", formatNumberPair(metadata.trackNumber, metadata.trackTotal));
  appendTextFrame(frames, "TPOS", formatNumberPair(metadata.discNumber, metadata.discTotal));

  const artwork = metadata.artwork || {};
  const artworkBytes = bytesFrom(artwork.bytes);
  if (artworkBytes?.length) {
    frames.push(createApicFrame(artworkBytes, artwork.type));
  }

  if (!frames.length) return new Uint8Array(0);

  const padding = 256;
  const frameBytes = concatBytes(frames);
  const tag = new Uint8Array(10 + frameBytes.length + padding);
  tag[0] = 0x49;
  tag[1] = 0x44;
  tag[2] = 0x33;
  tag[3] = 0x03;
  tag[4] = 0x00;
  tag[5] = 0x00;
  tag.set(synchsafe(frameBytes.length + padding), 6);
  tag.set(frameBytes, 10);
  return tag;
}

export function formatNumberPair(number, total) {
  const parsedNumber = Number(number);
  if (!Number.isFinite(parsedNumber) || parsedNumber <= 0) return "";
  const parsedTotal = Number(total);
  return Number.isFinite(parsedTotal) && parsedTotal > 0
    ? `${Math.round(parsedNumber)}/${Math.round(parsedTotal)}`
    : `${Math.round(parsedNumber)}`;
}

export function cleanText(value) {
  return String(value ?? "").trim();
}

export function bytesFrom(value) {
  if (!value) return null;
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  return null;
}

export function concatBytes(parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  return bytes;
}

function appendTextFrame(frames, id, value) {
  const text = cleanText(value);
  if (!text) return;
  const payload = concatBytes([
    new Uint8Array([0x01, 0xff, 0xfe]),
    utf16LittleEndianBytes(text)
  ]);
  frames.push(createId3Frame(id, payload));
}

function createApicFrame(artworkBytes, type) {
  const mime = cleanArtworkMimeType(type);
  const mimeBytes = asciiBytes(mime);
  const payload = concatBytes([
    new Uint8Array([0x00]),
    mimeBytes,
    new Uint8Array([0x00, 0x03, 0x00]),
    artworkBytes
  ]);
  return createId3Frame("APIC", payload);
}

function createId3Frame(id, payload) {
  const frame = new Uint8Array(10 + payload.length);
  const view = new DataView(frame.buffer);
  writeString(view, 0, id);
  view.setUint32(4, payload.length, false);
  view.setUint16(8, 0, false);
  frame.set(payload, 10);
  return frame;
}

function utf16LittleEndianBytes(text) {
  const bytes = new Uint8Array(text.length * 2);
  const view = new DataView(bytes.buffer);
  for (let index = 0; index < text.length; index += 1) {
    view.setUint16(index * 2, text.charCodeAt(index), true);
  }
  return bytes;
}

function cleanArtworkMimeType(type) {
  const mime = cleanText(type).toLowerCase();
  if (mime === "image/png" || mime === "image/jpeg" || mime === "image/webp") {
    return mime;
  }
  return "image/jpeg";
}

function asciiBytes(text) {
  const bytes = new Uint8Array(text.length);
  for (let index = 0; index < text.length; index += 1) {
    bytes[index] = text.charCodeAt(index) & 0xff;
  }
  return bytes;
}

function synchsafe(value) {
  return new Uint8Array([
    (value >> 21) & 0x7f,
    (value >> 14) & 0x7f,
    (value >> 7) & 0x7f,
    value & 0x7f
  ]);
}

function writeString(view, offset, text) {
  for (let index = 0; index < text.length; index += 1) {
    view.setUint8(offset + index, text.charCodeAt(index));
  }
}
