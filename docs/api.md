# API Reference

<div class="api-bar">
  REST API OpenAPI 3 specification &mdash; raw: <a href="/docs/openapi3.json">JSON</a> &middot; <a href="/docs/openapi3.yaml">YAML</a>
</div>
<div id="api-redoc" style="height: calc(100vh - 100px);"></div>

<script src="https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js"></script>
<script>
(function () {
  var el = document.getElementById('api-redoc');
  if (el && window.Redoc && window.Redoc.init) {
    window.Redoc.init('/docs/openapi3.json', {
      theme: {
        colors: { primary: { main: '#2563eb' } },
        typography: { fontFamily: 'Inter, system-ui, sans-serif', fontSize: '14px' },
        sidebar: { width: '260px' }
      },
      hideDownloadButton: false,
      expandResponses: '200',
      pathInMiddlePanel: true,
      scrollYOffset: 0,
      nativeScrollbars: true
    }, el);
  }
})();
</script>