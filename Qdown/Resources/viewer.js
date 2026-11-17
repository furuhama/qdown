/*
 * Qdown renderer. Runs inside the WKWebView with only the qdown:// scheme
 * available; no network APIs are used.
 */
(function () {
  'use strict';

  var content = document.getElementById('content');
  var baseElement = document.getElementById('qdown-base');
  if (!content || !baseElement) { return; }

  var errors = [];
  var state = {
    token: 0,
    rendered: false,
    markdownLength: 0,
    headings: [],
    find: {
      query: '',
      count: 0,
      current: 0,
      mode: 'none',
      ranges: [],
      marks: [],
      useFallback: false
    }
  };

  var MERMAID_THEME = {
    darkMode: false,
    background: '#F0F0F7',
    fontFamily: '-apple-system, "Hiragino Kaku Gothic ProN", "Hiragino Sans", "Noto Sans JP", sans-serif',
    fontSize: '15px',
    primaryColor: '#EDEDF5',
    primaryTextColor: '#333333',
    primaryBorderColor: '#705697',
    secondaryColor: '#EDEDF5',
    secondaryTextColor: '#333333',
    secondaryBorderColor: '#7A3E9D',
    tertiaryColor: '#F0F0F7',
    tertiaryTextColor: '#333333',
    tertiaryBorderColor: '#C4B7D7',
    lineColor: '#705697',
    textColor: '#333333',
    mainBkg: '#EDEDF5',
    nodeBorder: '#705697',
    nodeTextColor: '#333333',
    clusterBkg: '#EDEDF5',
    clusterBorder: '#C4B7D7',
    titleColor: '#705697',
    edgeLabelBackground: '#F0F0F7',
    arrowheadColor: '#705697',
    actorBkg: '#EDEDF5',
    actorBorder: '#705697',
    actorTextColor: '#333333',
    actorLineColor: '#705697',
    signalColor: '#705697',
    signalTextColor: '#333333',
    labelBoxBkgColor: '#EDEDF5',
    labelBoxBorderColor: '#705697',
    labelTextColor: '#333333',
    loopTextColor: '#333333',
    activationBkgColor: '#EDEDF5',
    activationBorderColor: '#705697',
    sequenceNumberColor: '#F0F0F7',
    noteBkgColor: '#EDEDF5',
    noteBorderColor: '#7A3E9D',
    noteTextColor: '#333333',
    sectionBkgColor: '#EDEDF5',
    sectionBkgColor2: '#F0F0F7',
    altSectionBkgColor: '#EDEDF5',
    taskBkgColor: '#705697',
    taskTextColor: '#FFFFFF',
    taskTextOutsideColor: '#333333',
    taskBorderColor: '#705697',
    activeTaskBkgColor: '#7A3E9D',
    activeTaskBorderColor: '#7A3E9D',
    gridColor: '#C4B7D7',
    classText: '#333333',
    labelColor: '#333333',
    attributeBackgroundColorOdd: '#EDEDF5',
    attributeBackgroundColorEven: '#F0F0F7',
    pie1: '#705697',
    pie2: '#7A3E9D',
    pie3: '#C4B7D7',
    pie4: '#9769DC',
    pie5: '#4B69C6',
    pie6: '#448C27',
    pieTitleTextColor: '#705697',
    pieSectionTextColor: '#333333',
    pieLegendTextColor: '#333333',
    pieStrokeColor: '#F0F0F7',
    pieOuterStrokeColor: '#705697',
    git0: '#705697',
    git1: '#7A3E9D',
    git2: '#C4B7D7',
    git3: '#9769DC',
    gitBranchLabel0: '#FFFFFF',
    gitBranchLabel1: '#FFFFFF',
    gitBranchLabel2: '#333333',
    gitBranchLabel3: '#FFFFFF',
    gitInv0: '#EDEDF5',
    gitInv1: '#EDEDF5'
  };

  function message(type, extra) {
    try {
      var body = { type: type };
      if (extra) {
        Object.keys(extra).forEach(function (key) {
          body[key] = extra[key];
        });
      }
      if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.qdown) {
        window.webkit.messageHandlers.qdown.postMessage(body);
      }
    } catch (error) {
      errors.push('bridge: ' + String(error));
    }
  }

  function textOf(error) {
    if (!error) { return 'unknown error'; }
    if (typeof error === 'string') { return error; }
    return error.message ? error.message : String(error);
  }

  window.addEventListener('error', function (event) {
    var detail = 'window: ' + String(event.message || event.type) + ' @ ' + String(event.filename || '') + ':' + String(event.lineno || 0);
    errors.push(detail);
    message('log', { message: detail });
  });
  window.addEventListener('unhandledrejection', function (event) {
    var detail = 'promise: ' + textOf(event.reason);
    errors.push(detail);
    message('log', { message: detail });
  });

  var originalConsoleError = console.error;
  console.error = function () {
    var parts = Array.prototype.slice.call(arguments).map(function (value) {
      return typeof value === 'string' ? value : textOf(value);
    });
    errors.push('console: ' + parts.join(' '));
    if (originalConsoleError) {
      originalConsoleError.apply(console, arguments);
    }
  };

  // ---------------------------------------------------------------------------
  // Mermaid configuration
  // ---------------------------------------------------------------------------

  if (window.mermaid && typeof window.mermaid.initialize === 'function') {
    try {
      window.mermaid.initialize({
        startOnLoad: false,
        theme: 'base',
        securityLevel: 'strict',
        themeVariables: MERMAID_THEME,
        flowchart: { useMaxWidth: true, htmlLabels: true, curve: 'basis' },
        sequence: { useMaxWidth: true, wrap: true, mirrorActors: false },
        gantt: { useMaxWidth: true },
        class: { useMaxWidth: true },
        state: { useMaxWidth: true },
        er: { useMaxWidth: true },
        pie: { useMaxWidth: true },
        gitGraph: { useMaxWidth: true }
      });
    } catch (error) {
      errors.push('mermaid init: ' + textOf(error));
    }
  } else {
    errors.push('mermaid is not loaded');
  }

  if (window.marked && typeof window.marked.setOptions === 'function') {
    window.marked.setOptions({ gfm: true, breaks: false });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function isLocalImageSource(source) {
    var value = String(source || '').trim();
    if (!value) { return false; }
    if (/^\/\//.test(value)) { return false; }
    if (/^[a-z][a-z0-9+.-]*:/i.test(value)) { return false; }
    return true;
  }

  function textNodes(root) {
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        if (!node.nodeValue || !node.nodeValue.length) {
          return NodeFilter.FILTER_REJECT;
        }
        var parent = node.parentElement;
        if (!parent) { return NodeFilter.FILTER_REJECT; }
        if (parent.closest('script, style, noscript, template')) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    }, false);

    var nodes = [];
    while (walker.nextNode()) {
      nodes.push(walker.currentNode);
    }
    return nodes;
  }

  // ---------------------------------------------------------------------------
  // Sanitising the rendered Markdown
  // ---------------------------------------------------------------------------

  function sanitize() {
    var forbidden = content.querySelectorAll('script, iframe, object, embed, form, link, meta, base, style, textarea, select, button');
    Array.prototype.forEach.call(forbidden, function (element) {
      element.remove();
    });

    Array.prototype.forEach.call(content.querySelectorAll('*'), function (element) {
      Array.prototype.slice.call(element.attributes).forEach(function (attribute) {
        var name = attribute.name.toLowerCase();
        var value = attribute.value || '';
        if (name.indexOf('on') === 0) {
          element.removeAttribute(attribute.name);
          return;
        }
        if (name === 'style') {
          element.removeAttribute(attribute.name);
          return;
        }
        if ((name === 'href' || name === 'src' || name === 'xlink:href') &&
            /^\s*(javascript|vbscript|data)\s*:/i.test(value)) {
          element.removeAttribute(attribute.name);
        }
      });
    });

    Array.prototype.forEach.call(content.querySelectorAll('img'), function (image) {
      var source = image.getAttribute('src') || '';
      image.removeAttribute('srcset');
      if (!isLocalImageSource(source)) {
        image.removeAttribute('src');
        image.classList.add('blocked-image');
        var alt = image.getAttribute('alt') || '';
        image.setAttribute('alt', (alt ? alt + ' — ' : '') + '外部画像は読み込まれません');
      } else {
        image.setAttribute('loading', 'lazy');
      }
    });
  }

  function addTaskListClasses() {
    Array.prototype.forEach.call(content.querySelectorAll('li > input[type="checkbox"]'), function (checkbox) {
      var item = checkbox.parentElement;
      if (!item) { return; }
      item.classList.add('task-list-item');
      var list = item.parentElement;
      if (list && (list.tagName === 'UL' || list.tagName === 'OL')) {
        list.classList.add('contains-task-list');
      }
    });
  }

  function assignHeadingIDs() {
    state.headings = [];
    Array.prototype.forEach.call(content.querySelectorAll('h1, h2, h3, h4, h5, h6'), function (heading, index) {
      var id = 'qdown-heading-' + index;
      heading.id = id;
      state.headings.push({
        id: id,
        level: parseInt(heading.tagName.substring(1), 10),
        text: (heading.textContent || '').replace(/\s+/g, ' ').trim()
      });
    });
  }

  function highlightCode() {
    if (!window.hljs || typeof window.hljs.highlightElement !== 'function') {
      errors.push('highlight.js is not loaded');
      return;
    }
    Array.prototype.forEach.call(content.querySelectorAll('pre > code'), function (code) {
      if (code.classList.contains('language-mermaid')) { return; }
      try {
        window.hljs.highlightElement(code);
      } catch (error) {
        errors.push('highlight: ' + textOf(error));
      }
    });
  }

  async function renderMermaidDiagrams(token) {
    var codes = Array.prototype.slice.call(content.querySelectorAll('pre > code.language-mermaid'));
    for (var index = 0; index < codes.length; index += 1) {
      if (token !== state.token) { return; }

      var code = codes[index];
      var source = code.textContent || '';
      var pre = code.parentElement;
      if (!pre || !pre.parentNode) { continue; }

      var host = document.createElement('div');
      host.className = 'mermaid';
      pre.parentNode.replaceChild(host, pre);

      if (!window.mermaid || typeof window.mermaid.render !== 'function') {
        host.classList.add('mermaid-error');
        host.textContent = 'Mermaid is not available.';
        continue;
      }

      var id = 'qdown-mermaid-' + token + '-' + index;
      try {
        var result = await window.mermaid.render(id, source);
        if (token !== state.token) { return; }
        host.innerHTML = result.svg;
        var svg = host.querySelector('svg');
        if (svg) {
          svg.removeAttribute('height');
          svg.style.maxWidth = '100%';
          svg.style.height = 'auto';
          if (!svg.getAttribute('preserveAspectRatio')) {
            svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
          }
          if (!svg.getAttribute('role')) {
            svg.setAttribute('role', 'img');
          }
        }
        if (typeof result.bindFunctions === 'function') {
          result.bindFunctions(host);
        }
      } catch (error) {
        errors.push('mermaid: ' + textOf(error));
        host.classList.add('mermaid-error');
        host.textContent = 'Mermaid: ' + textOf(error);
      } finally {
        var leftover = document.getElementById('d' + id);
        if (leftover && leftover.parentNode) {
          leftover.parentNode.removeChild(leftover);
        }
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Find
  // ---------------------------------------------------------------------------

  function supportsHighlightAPI() {
    return !state.find.useFallback &&
      typeof CSS !== 'undefined' &&
      !!CSS.highlights &&
      typeof Highlight === 'function';
  }

  function clearMarks() {
    var marks = state.find.marks || [];
    var parents = [];
    marks.forEach(function (mark) {
      var parent = mark.parentNode;
      if (!parent) { return; }
      while (mark.firstChild) {
        parent.insertBefore(mark.firstChild, mark);
      }
      parent.removeChild(mark);
      if (parents.indexOf(parent) === -1) { parents.push(parent); }
    });
    parents.forEach(function (parent) {
      parent.normalize();
    });
    state.find.marks = [];
  }

  function clearFind() {
    if (typeof CSS !== 'undefined' && CSS.highlights) {
      CSS.highlights.delete('qdown-find');
      CSS.highlights.delete('qdown-find-current');
    }
    clearMarks();
    state.find.query = '';
    state.find.count = 0;
    state.find.current = 0;
    state.find.mode = 'none';
    state.find.ranges = [];
  }

  function collectRanges(query) {
    var ranges = [];
    var needle = query.toLocaleLowerCase();
    textNodes(content).forEach(function (node) {
      var haystack = node.nodeValue.toLocaleLowerCase();
      var from = 0;
      while (true) {
        var at = haystack.indexOf(needle, from);
        if (at === -1) { break; }
        var range = document.createRange();
        range.setStart(node, at);
        range.setEnd(node, at + query.length);
        ranges.push(range);
        from = at + Math.max(1, needle.length);
      }
    });
    return ranges;
  }

  function wrapMarks(query) {
    var needle = query.toLocaleLowerCase();
    var marks = [];

    textNodes(content).forEach(function (node) {
      var haystack = node.nodeValue.toLocaleLowerCase();
      var positions = [];
      var from = 0;
      while (true) {
        var at = haystack.indexOf(needle, from);
        if (at === -1) { break; }
        positions.push(at);
        from = at + Math.max(1, needle.length);
      }

      for (var index = positions.length - 1; index >= 0; index -= 1) {
        var at = positions[index];
        try {
          var range = document.createRange();
          range.setStart(node, at);
          range.setEnd(node, at + query.length);
          var mark = document.createElement('mark');
          mark.className = 'qdown-find';
          range.surroundContents(mark);
          marks.push(mark);
        } catch (error) {
          errors.push('find mark: ' + textOf(error));
        }
      }
    });

    marks.sort(function (left, right) {
      if (left === right) { return 0; }
      return (left.compareDocumentPosition(right) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1;
    });
    return marks;
  }

  function scrollRangeIntoView(range) {
    try {
      var rect = range.getBoundingClientRect();
      if (rect && (rect.height || rect.width)) {
        var top = window.scrollY + rect.top - Math.max(80, (window.innerHeight - rect.height) / 2);
        window.scrollTo(0, Math.max(0, top));
        return;
      }
      var parent = range.startContainer.parentElement;
      if (parent) {
        parent.scrollIntoView({ block: 'center' });
      }
    } catch (error) {
      errors.push('find scroll: ' + textOf(error));
    }
  }

  function setCurrentRange(range) {
    if (!supportsHighlightAPI()) { return; }
    try {
      CSS.highlights.delete('qdown-find-current');
      var current = new Highlight();
      current.add(range);
      CSS.highlights.set('qdown-find-current', current);
    } catch (error) {
      errors.push('highlight current: ' + textOf(error));
    }
    scrollRangeIntoView(range);
  }

  function setCurrentMark(mark) {
    Array.prototype.forEach.call(content.querySelectorAll('mark.qdown-find'), function (element) {
      element.classList.remove('qdown-find-current');
    });
    if (!mark) { return; }
    mark.classList.add('qdown-find-current');
    mark.scrollIntoView({ block: 'center' });
  }

  function findState() {
    return {
      count: state.find.count,
      current: state.find.current,
      query: state.find.query,
      mode: state.find.mode
    };
  }

  function find(query) {
    clearFind();
    state.find.query = String(query || '');
    if (!state.find.query) {
      return findState();
    }

    var usedHighlightAPI = false;
    if (supportsHighlightAPI()) {
      try {
        state.find.ranges = collectRanges(state.find.query);
        var highlight = new Highlight();
        state.find.ranges.forEach(function (range) {
          highlight.add(range);
        });
        CSS.highlights.set('qdown-find', highlight);
        state.find.mode = 'css-highlight';
        state.find.count = state.find.ranges.length;
        usedHighlightAPI = true;
      } catch (error) {
        errors.push('highlight: ' + textOf(error));
        CSS.highlights.delete('qdown-find');
        state.find.ranges = [];
      }
    }

    if (!usedHighlightAPI) {
      state.find.mode = 'mark';
      state.find.marks = wrapMarks(state.find.query);
      state.find.count = state.find.marks.length;
    }

    if (state.find.count > 0) {
      state.find.current = 1;
      if (state.find.mode === 'css-highlight') {
        setCurrentRange(state.find.ranges[0]);
      } else {
        setCurrentMark(state.find.marks[0]);
      }
    }

    return findState();
  }

  function findNext(forward) {
    if (!state.find.query || state.find.count === 0) {
      return findState();
    }
    var count = state.find.count;
    var delta = forward ? 1 : -1;
    state.find.current = ((state.find.current - 1 + delta + count) % count) + 1;

    if (state.find.mode === 'css-highlight') {
      setCurrentRange(state.find.ranges[state.find.current - 1]);
    } else {
      setCurrentMark(state.find.marks[state.find.current - 1]);
    }
    return findState();
  }

  // ---------------------------------------------------------------------------
  // Rendering
  // ---------------------------------------------------------------------------

  async function render(markdown, baseHref) {
    var token = state.token + 1;
    state.token = token;
    state.rendered = false;
    state.markdownLength = String(markdown || '').length;
    clearFind();

    if (baseHref) {
      baseElement.setAttribute('href', baseHref);
    }

    var html;
    try {
      if (!window.marked || typeof window.marked.parse !== 'function') {
        throw new Error('marked is not available');
      }
      html = window.marked.parse(String(markdown || ''));
    } catch (error) {
      errors.push('marked: ' + textOf(error));
      html = '<pre class="qdown-render-error">' +
        escapeHtml('Markdown could not be rendered: ' + textOf(error)) + '</pre>';
    }

    content.innerHTML = html;
    sanitize();
    addTaskListClasses();
    assignHeadingIDs();
    message('headings', { headings: state.headings });

    highlightCode();
    await renderMermaidDiagrams(token);
    if (token !== state.token) {
      return { cancelled: true };
    }

    state.rendered = true;
    var stats = debugStats();
    message('renderDone', { stats: stats });
    return stats;
  }

  function scrollToHeading(id) {
    var element = document.getElementById(id);
    if (!element) { return false; }
    var top = window.scrollY + element.getBoundingClientRect().top - 18;
    window.scrollTo(0, Math.max(0, top));
    return true;
  }

  function colorOf(selector, property) {
    var element = content.querySelector(selector);
    if (!element) { return null; }
    return getComputedStyle(element)[property];
  }

  function debugStats() {
    var svg = content.querySelector('.mermaid svg');
    var nodeShape = svg ? svg.querySelector('.node rect, .node polygon, .node circle, .node ellipse, .node path') : null;
    var nodeLabel = svg ? svg.querySelector('.nodeLabel, .node text, text') : null;
    var edge = svg ? svg.querySelector('.edgePath path, path.flowchart-link, .messageLine0, .messageLine1') : null;
    var svgRect = svg ? svg.getBoundingClientRect() : null;
    var resources = [];
    if (window.performance && typeof window.performance.getEntriesByType === 'function') {
      resources = window.performance.getEntriesByType('resource').map(function (entry) {
        return entry.name;
      });
    }

    var imageSources = Array.prototype.map.call(content.querySelectorAll('img'), function (image) {
      return image.getAttribute('src') || '';
    });
    var linkHrefs = Array.prototype.map.call(content.querySelectorAll('a[href]'), function (link) {
      return link.getAttribute('href') || '';
    });

    return {
      rendered: state.rendered,
      markdownLength: state.markdownLength,
      htmlLength: content.innerHTML.length,
      headingCount: state.headings.length,
      headings: state.headings.map(function (heading) {
        return heading.level + ':' + heading.text;
      }),
      headingIds: state.headings.map(function (heading) { return heading.id; }),
      tableCount: content.querySelectorAll('table').length,
      taskCheckboxCount: content.querySelectorAll('input[type="checkbox"]').length,
      checkedCheckboxCount: content.querySelectorAll('input[type="checkbox"]:checked').length,
      codeBlockCount: content.querySelectorAll('pre > code').length,
      highlightedBlockCount: content.querySelectorAll('pre > code.hljs').length,
      tokenCount: content.querySelectorAll('.hljs-keyword, .hljs-string, .hljs-number, .hljs-title, .hljs-built_in').length,
      blockquoteCount: content.querySelectorAll('blockquote').length,
      listCount: content.querySelectorAll('ul, ol').length,
      hrCount: content.querySelectorAll('hr').length,
      imageCount: content.querySelectorAll('img').length,
      imageLoadedCount: Array.prototype.filter.call(content.querySelectorAll('img'), function (image) {
        return image.complete && image.naturalWidth > 0;
      }).length,
      imageNaturalWidths: Array.prototype.map.call(content.querySelectorAll('img'), function (image) {
        return image.naturalWidth;
      }),
      blockedImageCount: content.querySelectorAll('img.blocked-image').length,
      nonLocalImageCount: imageSources.filter(function (source) {
        return source && !isLocalImageSource(source);
      }).length,
      imageSources: imageSources,
      mermaidBlockCount: content.querySelectorAll('.mermaid').length,
      mermaidSvgCount: content.querySelectorAll('.mermaid svg').length,
      mermaidErrorCount: content.querySelectorAll('.mermaid-error').length,
      linkCount: content.querySelectorAll('a[href]').length,
      externalLinkCount: linkHrefs.filter(function (href) {
        return /^https?:/i.test(href);
      }).length,
      theme: {
        bodyBackground: getComputedStyle(document.body).backgroundColor,
        bodyColor: getComputedStyle(document.body).color,
        bodyFont: getComputedStyle(document.body).fontFamily,
        h1Color: colorOf('h1', 'color'),
        h1Border: colorOf('h1', 'borderBottomColor'),
        h2Color: colorOf('h2', 'color'),
        linkColor: colorOf('a[href]', 'color'),
        inlineCodeColor: colorOf('p code, li code, td code, blockquote code', 'color'),
        inlineCodeBackground: colorOf('p code, li code, td code, blockquote code', 'backgroundColor'),
        codeBlockBackground: colorOf('pre', 'backgroundColor'),
        blockquoteBackground: colorOf('blockquote', 'backgroundColor'),
        blockquoteBorder: colorOf('blockquote', 'borderLeftColor'),
        tableHeaderBackground: colorOf('th', 'backgroundColor'),
        tableHeaderColor: colorOf('th', 'color'),
        taskCheckboxAccent: colorOf('input[type="checkbox"]', 'accentColor')
      },
      mermaidTheme: {
        nodeFill: nodeShape ? getComputedStyle(nodeShape).fill : null,
        nodeStroke: nodeShape ? getComputedStyle(nodeShape).stroke : null,
        labelFill: nodeLabel ? getComputedStyle(nodeLabel).fill : null,
        edgeStroke: edge ? getComputedStyle(edge).stroke : null,
        svgBackground: svg ? getComputedStyle(svg).backgroundColor : null,
        width: svgRect ? svgRect.width : 0,
        viewBox: svg ? svg.getAttribute('viewBox') : null
      },
      layout: {
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight,
        documentScrollWidth: document.documentElement.scrollWidth,
        bodyScrollWidth: document.body.scrollWidth,
        contentWidth: content.clientWidth,
        overflowX: document.documentElement.scrollWidth > window.innerWidth + 1,
        mermaidWidth: svgRect ? svgRect.width : 0,
        mermaidOverflow: svgRect ? svgRect.width > content.clientWidth + 1 : false,
        bodyScrollY: window.scrollY
      },
      find: findState(),
      markCount: content.querySelectorAll('mark.qdown-find').length,
      cssHighlightNames: (function () {
        var names = [];
        try {
          if (typeof CSS !== 'undefined' && CSS.highlights && typeof CSS.highlights.forEach === 'function') {
            CSS.highlights.forEach(function (value, key) { names.push(key); });
          }
        } catch (error) { /* diagnostics only */ }
        return names;
      })(),
      resources: resources,
      externalResources: resources.filter(function (name) {
        return !/^qdown:\/\//i.test(name);
      }),
      scriptLoaded: {
        marked: !!window.marked,
        highlight: !!window.hljs,
        mermaid: !!window.mermaid
      },
      errors: errors.slice()
    };
  }

  // ---------------------------------------------------------------------------
  // Interaction
  // ---------------------------------------------------------------------------

  content.addEventListener('click', function (event) {
    var target = event.target;
    var link = target && target.closest ? target.closest('a') : null;
    if (!link) { return; }
    var href = link.getAttribute('href');
    if (!href) { return; }
    event.preventDefault();

    if (href.charAt(0) === '#') {
      var id = href.slice(1);
      try { id = decodeURIComponent(id); } catch (error) { /* keep raw id */ }
      scrollToHeading(id);
      return;
    }
    if (/^\s*(javascript|vbscript|data)\s*:/i.test(href)) {
      return;
    }
    message('openLink', { href: href });
  });

  content.addEventListener('auxclick', function (event) {
    var target = event.target;
    var link = target && target.closest ? target.closest('a') : null;
    if (!link) { return; }
    event.preventDefault();
    var href = link.getAttribute('href');
    if (href && !/^\s*(javascript|vbscript|data)\s*:/i.test(href)) {
      message('openLink', { href: href });
    }
  });

  window.addEventListener('dragover', function (event) {
    if (event.dataTransfer && Array.prototype.indexOf.call(event.dataTransfer.types, 'Files') !== -1) {
      event.preventDefault();
    }
  });

  window.addEventListener('drop', function (event) {
    if (event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files.length > 0) {
      event.preventDefault();
    }
  });

  // ---------------------------------------------------------------------------
  // Public bridge
  // ---------------------------------------------------------------------------

  window.qdown = {
    version: '1.0',
    render: render,
    find: find,
    findNext: findNext,
    clearFind: clearFind,
    setFindFallback: function (enabled) {
      state.find.useFallback = !!enabled;
      clearFind();
    },
    scrollToHeading: scrollToHeading,
    debugStats: debugStats
  };

  message('ready');
})();
