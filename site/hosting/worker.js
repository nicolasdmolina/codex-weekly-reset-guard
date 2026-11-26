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
    const response = await fetch(pages + url.pathname + url.search, {
      method: request.method,
      redirect: 'manual',
    });
    if (response.headers.has('Location')) {
      return new Response('Second Wind is temporarily unavailable.', {
        status: 502,
        headers: { 'Cache-Control': 'no-store' },
      });
    }
    return response;
  },
};
