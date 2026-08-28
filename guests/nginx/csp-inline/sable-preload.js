
      (function () {
        var base = '/';
        var lng = (localStorage.getItem('i18nextLng') || navigator.language || 'en').split('-')[0];
        var configPromise = fetch(base + 'config.json').then(function (r) {
          if (!r.ok) return undefined;
          return r.json();
        });
        var localePromise = fetch(base + 'public/locales/' + lng + '.json');
        window.__SABLE_PRELOAD = {
          config: configPromise,
          locale: { lng: lng, promise: localePromise },
        };
        configPromise.catch(function () {});
        localePromise.catch(function () {});
      })();
    