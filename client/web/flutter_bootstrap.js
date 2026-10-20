{{flutter_js}}
{{flutter_build_config}}

// Custom bootstrap: reports boot stages to window.budgetLoader (inline in index.html).
(function () {
  var L = window.budgetLoader || { stage: function () {}, progress: function () {}, done: function () {}, error: function () {} };
  L.done('bootstrap');
  var build = (_flutter.buildConfig.builds || []).find(function (b) { return b && b.compileTarget === 'dart2js'; });
  var mainPath = (build && build.mainJsPath) || 'main.dart.js';

  // Download main.dart.js ourselves to show byte progress, then hand the loader a blob URL
  // (no second download; server sends no-cache so a refetch would not hit the cache).
  function fetchMain() {
    L.stage('main');
    if (!build || !window.fetch || !window.ReadableStream) { L.progress('main', null); return Promise.resolve(); }
    var url = new URL(mainPath, document.baseURI).toString();
    return fetch(url).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status + ' for ' + mainPath);
      // Content-Length is the wire size: with a (pre)compressed response it
      // is smaller than the bytes the reader yields, so only trust it when
      // the body is not encoded.
      var enc = (r.headers.get('Content-Encoding') || '').toLowerCase();
      var total = (!enc || enc === 'identity') ? (+r.headers.get('Content-Length') || 0) : 0;
      if (!r.body || !r.body.getReader) return r.blob();
      if (!total) L.progress('main', null);
      var reader = r.body.getReader(), chunks = [], got = 0;
      function pump() {
        return reader.read().then(function (x) {
          if (x.done) return new Blob(chunks, { type: 'text/javascript' });
          chunks.push(x.value); got += x.value.length;
          var mb = (got / 1048576).toFixed(1) + (total ? ' / ' + (total / 1048576).toFixed(1) : '') + ' MB';
          L.progress('main', total ? got / total : null, 'App code ' + mb);
          return pump();
        });
      }
      return pump();
    }).then(function (blob) {
      build.mainJsPath = URL.createObjectURL(blob);
      L.done('main');
      L.stage('engine');
    });
  }

  fetchMain().catch(function (e) {
    // Fall back to the normal script-tag load (indeterminate).
    console.warn('[loader] main.dart.js prefetch failed, falling back:', e);
    L.progress('main', null);
  }).then(function () {
    return _flutter.loader.load({
      onEntrypointLoaded: async function (engineInitializer) {
        try {
          L.done('main');
          L.stage('engine');
          L.indeterminate && L.indeterminate('engine');
          var appRunner = await engineInitializer.initializeEngine();
          L.done('engine');
          L.stage('init', 'Starting app');
          await appRunner.runApp();
        } catch (e) {
          L.error('Engine failed to start: ' + (e && e.message || e));
        }
      },
    });
  }).catch(function (e) {
    L.error('Could not load the app: ' + (e && e.message || e));
  });
})();
