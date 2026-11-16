// Counts page views and download clicks. No cookies, no stored ID: every event gets a throwaway random id.
(function () {
  var key = 'phc_kGBs2Ae5MnJH3yZgDVbXenZY6ZP2SFCjs4iNSVsnkq3p';
  if (/^(localhost|127\.0\.0\.1)$/.test(location.hostname) || navigator.doNotTrack === '1') return;
  function send(event, props) {
    var ref = '';
    try { ref = document.referrer ? new URL(document.referrer).hostname : ''; } catch (e) {}
    var body = { api_key: key, event: event, distinct_id: 'anon-' + Math.random().toString(36).slice(2) + Date.now().toString(36),
      properties: Object.assign({ app: 'brain-input', page: location.pathname, referrer_host: ref, $process_person_profile: false, $geoip_disable: true }, props || {}) };
    try { fetch('https://us.i.posthog.com/i/v0/e/', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), keepalive: true }); } catch (e) {}
  }
  send('site_viewed');
  document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('a[data-track]');
    if (a) send(a.getAttribute('data-track'), { where: a.getAttribute('data-where') || '' });
  });
})();
