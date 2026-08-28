if (!Promise.withResolvers) {
        Promise.withResolvers = function () {
          var resolve, reject;
          var promise = new Promise(function (a, b) {
            resolve = a;
            reject = b;
          });
          return { promise: promise, resolve: resolve, reject: reject };
        };
      }