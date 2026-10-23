#!/usr/bin/env node
/**
 * Validate a SillyTavern Character Card V2 JSON and emit an importable PNG.
 *
 * Usage:
 *   node .opencode/scripts/character-card.mjs <card.json> [options]
 *
 * Options:
 *   --out <dir>     Output directory (default: cards)
 *   --image <png>   Use this image as the card art instead of the generated
 *                   placeholder
 *   --name <slug>   Override the file name (default: slugified card name)
 *   --json-only     Write only the normalised .json, skip the .png
 *   --print         Print the normalised JSON to stdout
 *   -h, --help      Show this help
 *
 * The PNG metadata is written with the repository's own writer
 * (src/character-card-parser.js), so the result uses exactly the chunks
 * SillyTavern expects: base64 JSON in `chara` and `ccv3`.
 */

import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

import encode from '../../src/png/encode.js';
import { write as writeCardPng } from '../../src/character-card-parser.js';

const AVATAR_WIDTH = 512;
const AVATAR_HEIGHT = 768;
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function usage() {
    return `Usage: node .opencode/scripts/character-card.mjs <card.json> [options]

Options:
  --out <dir>     Output directory (default: cards)
  --image <png>   Use this image instead of a generated placeholder
  --name <slug>   Override the output file name
  --json-only     Skip the PNG
  --print         Print the normalised JSON to stdout
  -h, --help      Show this help`;
}

function fail(message) {
    const error = new Error(message);
    error.userFacing = true;
    throw error;
}

function parseArgs(argv) {
    const args = { input: '', out: 'cards', image: '', name: '', jsonOnly: false, print: false };

    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];

        if (arg === '-h' || arg === '--help') {
            args.help = true;
        } else if (arg === '--json-only') {
            args.jsonOnly = true;
        } else if (arg === '--print') {
            args.print = true;
        } else if (arg === '--out' || arg === '--image' || arg === '--name') {
            const value = argv[++i];
            if (!value || value.startsWith('--')) fail(`${arg} needs a value`);
            if (arg === '--out') args.out = value;
            if (arg === '--image') args.image = value;
            if (arg === '--name') args.name = value;
        } else if (arg.startsWith('-')) {
            fail(`unknown option: ${arg}\n\n${usage()}`);
        } else if (!args.input) {
            args.input = arg;
        } else {
            fail(`unexpected argument: ${arg}\n\n${usage()}`);
        }
    }

    return args;
}

function asString(value, field, { required = false } = {}) {
    if (value === undefined || value === null) value = '';
    if (typeof value !== 'string') fail(`data.${field} must be a string`);
    const trimmed = value.trim();
    if (required && !trimmed) fail(`data.${field} must not be empty`);
    return trimmed;
}

function asStringArray(value, field, { commaSplit = false } = {}) {
    if (value === undefined || value === null) return [];

    if (typeof value === 'string') {
        const parts = commaSplit ? value.split(',') : [value];
        return parts.map(part => part.trim()).filter(Boolean);
    }

    if (Array.isArray(value)) {
        return value.map(item => {
            if (typeof item !== 'string') fail(`data.${field} must contain only strings`);
            return item.trim();
        }).filter(Boolean);
    }

    fail(`data.${field} must be a string or an array of strings`);
}

function asObject(value, field) {
    if (value === undefined || value === null) return {};
    if (typeof value !== 'object' || Array.isArray(value)) fail(`data.${field} must be an object`);
    return value;
}

function normalize(input) {
    if (!input || typeof input !== 'object' || Array.isArray(input)) {
        fail('the card file must contain a JSON object');
    }

    const embedded = input.data && typeof input.data === 'object' && !Array.isArray(input.data)
        ? input.data
        : {};
    const pick = key => (embedded[key] !== undefined ? embedded[key] : input[key]);

    const data = {
        name: asString(pick('name'), 'name', { required: true }),
        description: asString(pick('description'), 'description', { required: true }),
        personality: asString(pick('personality'), 'personality'),
        scenario: asString(pick('scenario'), 'scenario'),
        first_mes: asString(pick('first_mes'), 'first_mes', { required: true }),
        mes_example: asString(pick('mes_example'), 'mes_example'),
        creator_notes: asString(pick('creator_notes') || pick('creatorcomment'), 'creator_notes'),
        system_prompt: asString(pick('system_prompt'), 'system_prompt'),
        post_history_instructions: asString(pick('post_history_instructions'), 'post_history_instructions'),
        alternate_greetings: asStringArray(pick('alternate_greetings'), 'alternate_greetings'),
        tags: asStringArray(pick('tags'), 'tags', { commaSplit: true }),
        creator: asString(pick('creator'), 'creator'),
        character_version: asString(pick('character_version'), 'character_version') || '1.0',
        extensions: asObject(pick('extensions'), 'extensions'),
    };

    if (pick('character_book') !== undefined && pick('character_book') !== null) {
        data.character_book = asObject(pick('character_book'), 'character_book');
    }

    // V1 mirrors are intentionally populated too: SillyTavern and third-party
    // frontends still read them, and the V2 spec permits them alongside `data`.
    return {
        spec: 'chara_card_v2',
        spec_version: '2.0',
        name: data.name,
        description: data.description,
        personality: data.personality,
        scenario: data.scenario,
        first_mes: data.first_mes,
        mes_example: data.mes_example,
        creatorcomment: data.creator_notes,
        avatar: 'none',
        talkativeness: 0.5,
        fav: false,
        create_date: new Date().toISOString(),
        data,
    };
}

function slugify(value) {
    const slug = value
        .normalize('NFKD')
        .replace(/[\u0300-\u036f]/g, '')
        .toLowerCase()
        .replace(/[^\p{L}\p{N}]+/gu, '-')
        .replace(/^-+|-+$/g, '')
        .slice(0, 80);

    return slug || 'character';
}

function hslToRgb(h, s, l) {
    if (s === 0) {
        const v = Math.round(l * 255);
        return [v, v, v];
    }

    const hue2rgb = (p, q, t) => {
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1 / 6) return p + (q - p) * 6 * t;
        if (t < 1 / 2) return q;
        if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
        return p;
    };

    const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const p = 2 * l - q;

    return [
        Math.round(hue2rgb(p, q, h + 1 / 3) * 255),
        Math.round(hue2rgb(p, q, h) * 255),
        Math.round(hue2rgb(p, q, h - 1 / 3) * 255),
    ];
}

/** Deterministic gradient placeholder so every card has distinct art. */
function makePlaceholderPng(seedText) {
    const seed = [...seedText].reduce((acc, char) => (acc * 31 + char.codePointAt(0)) >>> 0, 7);
    const hue = seed % 360;
    const dark = hslToRgb(hue / 360, 0.5, 0.2);
    const light = hslToRgb(((hue + 35) % 360) / 360, 0.55, 0.62);

    const rowBytes = AVATAR_WIDTH * 3 + 1;
    const raw = Buffer.alloc(rowBytes * AVATAR_HEIGHT);

    for (let y = 0; y < AVATAR_HEIGHT; y++) {
        const row = y * rowBytes;
        raw[row] = 0; // filter: none

        for (let x = 0; x < AVATAR_WIDTH; x++) {
            const t = (x / AVATAR_WIDTH) * 0.6 + (y / AVATAR_HEIGHT) * 0.4;
            const offset = row + 1 + x * 3;
            raw[offset] = Math.round(dark[0] + (light[0] - dark[0]) * t);
            raw[offset + 1] = Math.round(dark[1] + (light[1] - dark[1]) * t);
            raw[offset + 2] = Math.round(dark[2] + (light[2] - dark[2]) * t);
        }
    }

    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(AVATAR_WIDTH, 0);
    ihdr.writeUInt32BE(AVATAR_HEIGHT, 4);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // colour type: truecolour
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace

    const chunks = [
        { name: 'IHDR', data: new Uint8Array(ihdr) },
        { name: 'IDAT', data: new Uint8Array(zlib.deflateSync(raw, { level: 9 })) },
        { name: 'IEND', data: new Uint8Array(0) },
    ];

    return Buffer.from(encode(chunks));
}

function readBaseImage(imagePath) {
    const image = fs.readFileSync(imagePath);
    if (image.length < 8 || !image.subarray(0, 8).equals(PNG_SIGNATURE)) {
        fail(`${imagePath} is not a PNG image`);
    }
    return image;
}

function main() {
    const args = parseArgs(process.argv.slice(2));

    if (args.help) {
        console.log(usage());
        return;
    }

    if (!args.input) {
        fail(`missing card JSON path\n\n${usage()}`);
    }

    const inputPath = path.resolve(args.input);
    if (!fs.existsSync(inputPath)) fail(`no such file: ${args.input}`);

    let parsed;
    try {
        parsed = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
    } catch (error) {
        fail(`could not parse ${args.input}: ${error.message}`);
    }

    const card = normalize(parsed);
    const serialized = JSON.stringify(card, null, 2);
    const outDir = path.resolve(args.out);
    const slug = args.name ? slugify(args.name) : slugify(card.data.name);

    // Refuse a path-traversal slug even though slugify strips separators.
    if (slug.includes('/') || slug.includes('\\')) fail(`invalid slug: ${slug}`);

    fs.mkdirSync(outDir, { recursive: true });

    const jsonPath = path.join(outDir, `${slug}.json`);
    fs.writeFileSync(jsonPath, `${serialized}\n`);

    let pngPath = '';
    if (!args.jsonOnly) {
        const base = args.image
            ? readBaseImage(path.resolve(args.image))
            : makePlaceholderPng(card.data.name);

        const png = writeCardPng(base, JSON.stringify(card));
        pngPath = path.join(outDir, `${slug}.png`);
        fs.writeFileSync(pngPath, png);
    }

    if (args.print) {
        console.log(serialized);
        console.error('');
    }

    const relative = file => path.relative(process.cwd(), file) || file;
    const tags = card.data.tags.length ? card.data.tags.join(', ') : '(none)';

    console.log(`✓ ${relative(jsonPath)}`);
    if (pngPath) {
        console.log(`✓ ${relative(pngPath)}  (${AVATAR_WIDTH}×${AVATAR_HEIGHT}, chara + ccv3)`);
    }
    console.log(`  name: ${card.data.name}`);
    console.log(`  tags: ${tags}`);
    console.log(`  import: SillyTavern → Character Management → Import`);
    if (pngPath) {
        console.log(`  nix:    files.byUser."<handle>"."characters/${slug}.png".path = ./${relative(pngPath)};`);
    } else {
        console.log('  nix:    (json-only — run without --json-only to produce the importable PNG)');
    }
}

try {
    main();
} catch (error) {
    if (error.userFacing) {
        console.error(`error: ${error.message}`);
    } else {
        console.error(error);
    }
    process.exitCode = 1;
}
