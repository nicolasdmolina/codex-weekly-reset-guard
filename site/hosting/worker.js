const pages = 'https://nicolasdmolina.github.io/codex-weekly-reset-guard';

export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.protocol === 'http:') {
      url.protocol = 'https:';
      return Response.redirect(url, 301);
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    return fetch(pages + url.pathname, { method: request.method, redirect: 'manual' });
  },
};
