/**
 * Chub Search proxy.
 *
 * Chub's search endpoint (https://ro.chub.ai/search) sits behind Cloudflare and
 * only answers when the request carries `Origin: https://chub.ai` plus the
 * usual browser fetch headers. A browser page served from SillyTavern cannot
 * set Origin (fetch forbids it), so the UI extension asks this plugin, which
 * repeats the request server-side with the headers Cloudflare requires.
 *
 * The route is same-origin with the extension, so no CORS work is needed.
 */

const CHUB_SEARCH_URL = 'https://ro.chub.ai/search';

// Cloudflare rejects a minimal request (Origin + UA alone returns 403); the
// full browser header set below is what makes ro.chub.ai answer 200.
const CHUB_HEADERS = {
    'Accept': 'application/json',
    'Accept-Language': 'en-US,en;q=0.9',
    'Origin': 'https://chub.ai',
    'Referer': 'https://chub.ai/',
    'Sec-Fetch-Dest': 'empty',
    'Sec-Fetch-Mode': 'cors',
    'Sec-Fetch-Site': 'cross-site',
    'Sec-Ch-Ua': '"Chromium";v="126", "Not.A/Brand";v="24"',
    'Sec-Ch-Ua-Mobile': '?0',
    'Sec-Ch-Ua-Platform': '"Linux"',
    'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
};

// Only forward the parameters the extension's search UI produces; everything
// else is fixed here.
const ALLOWED_PARAMS = new Set([
    'search',
    'first',
    'page',
    'sort',
    'asc',
    'include_forks',
    'nsfw',
    'require_images',
    'require_custom_prompt',
    'tags',
    'exclude_tags',
]);

export const info = {
    id: 'chub-search',
    name: 'Chub Search Proxy',
    description: 'Proxies character search requests to Chub with the headers Cloudflare requires.',
};

/**
 * @param {import('express').Express} app
 */
export async function init(app) {
    app.get('/api/plugins/chub-search/search', async (request, response) => {
        try {
            const params = new URLSearchParams();
            params.set('namespace', 'characters');
            params.set('chub', 'true');
            params.set('bypass', 'true');

            for (const [key, value] of Object.entries(request.query)) {
                if (!ALLOWED_PARAMS.has(key)) {
                    continue;
                }
                if (Array.isArray(value)) {
                    value.forEach(v => params.append(key, String(v)));
                } else if (value !== undefined) {
                    params.set(key, String(value));
                }
            }

            const result = await fetch(`${CHUB_SEARCH_URL}?${params.toString()}`, { headers: CHUB_HEADERS });
            const body = await result.text();
            response
                .status(result.status)
                .type(result.headers.get('content-type') || 'application/json')
                .send(body);
        } catch (error) {
            console.error('[chub-search] proxy failed:', error);
            response.status(502).json({ error: 'Chub search proxy failed' });
        }
    });
}
