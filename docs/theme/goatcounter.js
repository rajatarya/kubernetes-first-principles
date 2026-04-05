// GoatCounter analytics — privacy-friendly, no cookies, GDPR-compliant
// Dashboard: https://k8s-first-principles.goatcounter.com
(function() {
    // Don't track local development
    if (window.location.host === 'localhost' || window.location.host === '127.0.0.1') return;

    var script = document.createElement('script');
    script.async = true;
    script.dataset.goatcounter = 'https://k8s-first-principles.goatcounter.com/count';
    script.src = '//gc.zgo.at/count.js';
    document.head.appendChild(script);
})();
