// lib/canonicalise-config.mjs
//
// Canonicalise a SillyTavern config.yaml into sorted JSON, so two documents can
// be compared for equality with `diff`.
//
// Used by the `configYamlRoundTrip` check in lib/tests.nix. It lives here rather
// than inline in that Nix string because it is full of `${…}` template literals,
// which Nix would try to interpolate out of existence.
//
// Three transformations, in order:
//
// 1. PARSE with the `yaml` package — the same one SillyTavern's lockfile pins,
//    so the check parses with exactly the parser the server will. A different
//    parser would make this a test of the wrong thing.
//
// 2. APPLY the module's documented overrides to the expectation. The module
//    deliberately differs from upstream in a handful of places (see
//    `expectedOverrides` in lib/tests.nix), and folding them into the
//    expectation is what keeps the comparison EXACT for every other key rather
//    than "exact modulo a list of exceptions I hope I remembered".
//
// 3. STRIP the secret paths. Their values are never compared — deliberately: a
//    check's output should not be able to leak a credential — and they are
//    stripped from the expectation too so their absence is not a diff.
//
// Finally every key is sorted, because upstream's file order and the module's
// alphabetical order are both arbitrary, and a naive comparison would fail on
// ordering alone.
import YAML from "yaml";
import fs from "node:fs";

const [, , input, output, overridesPath, secretsPath] = process.argv;

if (!output || !overridesPath || !secretsPath) {
  console.error(
    "usage: canonicalise-config.mjs <input.yaml> <output.json> <overrides.json> <secrets.json>",
  );
  process.exit(2);
}

const overrides = JSON.parse(fs.readFileSync(overridesPath, "utf8"));
const strippedSecrets = JSON.parse(fs.readFileSync(secretsPath, "utf8"));

/** Apply `path = value` to a nested object, creating intermediate objects. */
const setPath = (obj, path, value) => {
  const parts = path.split(".");
  let node = obj;
  for (const part of parts.slice(0, -1)) {
    if (typeof node[part] !== "object" || node[part] === null) node[part] = {};
    node = node[part];
  }
  node[parts[parts.length - 1]] = value;
  return obj;
};

/** Delete each dotted path, tolerating ones that are not present. */
const stripPaths = (obj, paths) => {
  for (const path of paths) {
    const parts = path.split(".");
    let node = obj;
    for (const part of parts.slice(0, -1)) {
      if (typeof node !== "object" || node === null || !(part in node)) {
        node = undefined;
        break;
      }
      node = node[part];
    }
    if (node && typeof node === "object") delete node[parts[parts.length - 1]];
  }
  return obj;
};

/** Recursively sort object keys; array order is meaningful and is preserved. */
const canon = (value) =>
  Array.isArray(value)
    ? value.map(canon)
    : value && typeof value === "object"
      ? Object.fromEntries(
          Object.keys(value).sort().map((k) => [k, canon(value[k])]),
        )
      : value;

const doc = YAML.parse(fs.readFileSync(input, "utf8"));

for (const [path, value] of Object.entries(overrides)) {
  setPath(doc, path, value);
}
stripPaths(doc, strippedSecrets);

fs.writeFileSync(output, JSON.stringify(canon(doc), null, 2) + "\n");
