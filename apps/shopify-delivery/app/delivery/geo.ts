import { createHash } from "node:crypto";

// Simulated geography. The development store's test orders have US test addresses that
// Shopify may or may not geocode, and Ravon's dispatch model is calibrated for Dushanbe,
// so every job gets a deterministic synthetic pickup and dropoff derived from its order
// GID. Nothing here is a real place or a real courier.

export const STORE = { lat: 38.5598, lng: 68.787 }; // central Dushanbe

// Uniform [0, 1) values from a key, reproducible across runs and processes.
export function uniforms(key: string, n: number): number[] {
  const out: number[] = [];
  let block = 0;
  while (out.length < n) {
    const h = createHash("sha256").update(`${key}#${block++}`).digest();
    for (let i = 0; i + 6 <= h.length && out.length < n; i += 6) {
      out.push(h.readUIntBE(i, 6) / 2 ** 48);
    }
  }
  return out;
}

// A point within `radiusKm` of `center`, uniform over the disc.
export function pointNear(key: string, center: { lat: number; lng: number }, radiusKm: number) {
  const [u, v] = uniforms(key, 2);
  const r = radiusKm * Math.sqrt(u);
  const theta = 2 * Math.PI * v;
  const dLat = (r * Math.cos(theta)) / 111.32;
  const dLng = (r * Math.sin(theta)) / (111.32 * Math.cos((center.lat * Math.PI) / 180));
  return { lat: center.lat + dLat, lng: center.lng + dLng };
}

export function dropoffFor(orderGid: string) {
  return pointNear(`dropoff:${orderGid}`, STORE, 4);
}

// Version-4-shaped UUID from a key, for simulated courier ids (Assign requires UUIDs).
export function uuidFrom(key: string): string {
  const h = createHash("sha256").update(key).digest("hex");
  const v = ((parseInt(h[16], 16) & 0x3) | 0x8).toString(16);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${v}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}
