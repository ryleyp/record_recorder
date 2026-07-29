const CACHE_NAME = "vinyl-album-recorder-v8";
const ASSETS = [
  "./",
  "./index.html",
  "./styles.css",
  "./manifest.webmanifest",
  "./icons/icon.svg",
  "./src/app.js",
  "./src/aiff.js",
  "./src/audioMetadata.js",
  "./src/audioCleanup.js",
  "./src/detection.js",
  "./src/gapListener.js",
  "./src/quality.js",
  "./src/recorder.js",
  "./src/silenceCrop.js",
  "./src/utils.js",
  "./src/wav.js",
  "./src/zip.js"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  event.respondWith(
    fetch(event.request).then((response) => {
      const copy = response.clone();
      caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
      return response;
    }).catch(() => caches.match(event.request))
  );
});
