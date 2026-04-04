document.addEventListener('DOMContentLoaded', function() {
    var main = document.querySelector('main');
    if (main) {
        var root = typeof path_to_root !== 'undefined' ? path_to_root : '';

        var footer = document.createElement('div');
        footer.style.cssText = 'text-align:center; padding:2em 0 1em; color:#888; font-size:0.8em; border-top:1px solid rgba(128,128,128,0.3); margin-top:3em;';

        var img = document.createElement('img');
        img.src = root + 'assets/kubernetes-logo.png';
        img.alt = '';
        img.width = 20;
        img.style.cssText = 'vertical-align:middle; margin-right:6px; opacity:0.7;';
        img.onerror = function() { this.style.display = 'none'; };

        var text = document.createElement('span');
        text.style.cssText = 'vertical-align:middle;';
        text.innerHTML = '<em>Kubernetes from First Principles</em>: Why It Works the Way It Does';

        var license = document.createElement('div');
        license.style.cssText = 'margin-top:0.5em; font-size:0.9em; color:#666;';
        license.innerHTML = '© 2026 Rajat Arya · <a href="https://creativecommons.org/licenses/by-nc-sa/4.0/" style="color:#666;">CC BY-NC-SA 4.0</a> · Kubernetes® is a registered trademark of The Linux Foundation';

        footer.appendChild(img);
        footer.appendChild(text);
        footer.appendChild(license);
        main.appendChild(footer);
    }
});
