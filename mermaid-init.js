// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

(() => {
    const darkThemes = ['ayu', 'navy', 'coal'];
    const lightThemes = ['light', 'rust'];

    const classList = document.getElementsByTagName('html')[0].classList;

    let lastThemeWasLight = true;
    for (const cssClass of classList) {
        if (darkThemes.includes(cssClass)) {
            lastThemeWasLight = false;
            break;
        }
    }

    // Kubernetes color palette
    const k8sThemeVariables = lastThemeWasLight ? {
        // Light mode — K8s blue on light backgrounds
        primaryColor: '#326CE5',
        primaryTextColor: '#ffffff',
        primaryBorderColor: '#1a4eb8',
        lineColor: '#326CE5',
        secondaryColor: '#e8f0fe',
        secondaryTextColor: '#1a3a6b',
        tertiaryColor: '#f0f4fc',
        tertiaryTextColor: '#1a3a6b',
        noteBkgColor: '#e8f0fe',
        noteTextColor: '#1a3a6b',
        noteBorderColor: '#326CE5',
        // Gantt chart colors
        taskBkgColor: '#326CE5',
        taskTextColor: '#ffffff',
        taskTextDarkColor: '#1a3a6b',
        doneTaskBkgColor: '#8ab4f8',
        doneTaskBorderColor: '#326CE5',
        activeTaskBkgColor: '#326CE5',
        activeTaskBorderColor: '#1a4eb8',
        critBkgColor: '#e8453c',
        sectionBkgColor: '#f0f4fc',
        altSectionBkgColor: '#e8f0fe',
        gridColor: '#ccd9f0'
    } : {
        // Dark mode — K8s blue on dark backgrounds
        darkMode: true,
        background: '#1a2035',
        primaryColor: '#326CE5',
        primaryTextColor: '#e0e8f5',
        primaryBorderColor: '#5a8ef0',
        lineColor: '#5a8ef0',
        secondaryColor: '#1e3a6e',
        secondaryTextColor: '#c0d0e8',
        tertiaryColor: '#141e33',
        tertiaryTextColor: '#a0b8d8',
        noteBkgColor: '#1e3a6e',
        noteTextColor: '#e0e8f5',
        noteBorderColor: '#5a8ef0',
        // Gantt chart colors
        taskBkgColor: '#326CE5',
        taskTextColor: '#e0e8f5',
        taskTextDarkColor: '#e0e8f5',
        doneTaskBkgColor: '#1e3a6e',
        doneTaskBorderColor: '#5a8ef0',
        activeTaskBkgColor: '#326CE5',
        activeTaskBorderColor: '#5a8ef0',
        critBkgColor: '#e8453c',
        sectionBkgColor: '#141e33',
        altSectionBkgColor: '#1a2744',
        gridColor: '#2a3a5a'
    };

    mermaid.initialize({
        startOnLoad: true,
        theme: 'base',
        themeVariables: k8sThemeVariables
    });

    // Simplest way to make mermaid re-render the diagrams in the new theme is via refreshing the page

    for (const darkTheme of darkThemes) {
        document.getElementById(darkTheme).addEventListener('click', () => {
            if (lastThemeWasLight) {
                window.location.reload();
            }
        });
    }

    for (const lightTheme of lightThemes) {
        document.getElementById(lightTheme).addEventListener('click', () => {
            if (!lastThemeWasLight) {
                window.location.reload();
            }
        });
    }
})();
